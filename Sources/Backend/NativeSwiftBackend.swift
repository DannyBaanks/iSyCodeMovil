import Foundation
import SwiftUI

/// Everything one conversation needs to run on its own: its loop, its folder and its
/// tools. Several can run at the same time; switching conversations no longer cancels
/// the one that was working.
@MainActor
private final class ConversationRuntime {
    let sessionID: String
    let loop: AgentLoop
    let executor: NativeCapabilityToolExecutor
    let workspace: IOSWorkspace
    /// The backend's `loopGeneration` this loop was built for (model, provider, tools).
    let generation: Int
    var runningTask: Task<Void, Never>?
    var liveAnswerID: String?
    var mayHaveLeftApp = false
    /// True while this conversation holds the on-device model (see `LocalModelTurnGate`).
    var holdsLocalModel = false

    var isRunning: Bool { runningTask != nil }

    init(sessionID: String, loop: AgentLoop, executor: NativeCapabilityToolExecutor, workspace: IOSWorkspace, generation: Int) {
        self.sessionID = sessionID
        self.loop = loop
        self.executor = executor
        self.workspace = workspace
        self.generation = generation
    }
}

@MainActor
public final class NativeSwiftBackend: WorkbenchBackend {
    public var mode: BackendMode { .native }

    /// The default shared folder: listed as the project, and the folder every
    /// conversation uses when the person picked one in Files (`workspaceBookmark`).
    private var workspace: IOSWorkspace?
    var persistence: IOSPersistence?
    /// One runtime per conversation opened in this launch, keyed by conversation id.
    private var runtimes: [String: ConversationRuntime] = [:]
    /// Bumped when the model, provider or tool target changes. An idle runtime built for
    /// an older generation is rebuilt before its next turn; a running one finishes first.
    private var loopGeneration = 0
    private var gusPermissionMode = false
    private let localModelGate = LocalModelTurnGate()
    private var modelProvider: (any ModelProvider)?
    private var activeModelName: String?
    private var providerID = "scripted"
    private var providerDisplay = "Scripted Demo"
    private var providerModelIDs = ["scripted-1"]
    public private(set) var isDualSmolActive = false
    public var usesLiveModel: Bool { providerID != "scripted" }
    public var activeProviderID: String { providerID }
    public var currentModelName: String? { activeModelName }
    /// Executor over the shared `workspace`: used by conversations when the person picked
    /// a folder, and for phone-project actions before any conversation is open.
    private var toolExecutor: NativeCapabilityToolExecutor?
    /// When set, the agent's tools run in a Docker sandbox on the user's computer
    /// instead of the iPhone workspace. The model and the conversation stay here.
    private var sandboxExecutor: SandboxToolExecutor?
    private var sandboxProjectName: String?
    private var sandboxProjectPath: String?
    private var permissionWaiters: [String: (sessionID: String, continuation: CheckedContinuation<PermissionResponse.Decision, Never>)] = [:]
    /// The question each waiting conversation asked, re-sent when the person opens it:
    /// a conversation running in the background would otherwise wait forever.
    private var pendingPermissionEvents: [String: WorkbenchEvent] = [:]
    public var flowMode = false
    /// Acuse de recibo del turno del buzón [GUS] (una sola vez): lo pone
    /// deliverMailboxTask y lo resuelve el Task de sendPrompt al terminar el turno.
    /// Nil en turnos normales del usuario.
    private var mailboxTurnCompletion: ((Bool) -> Void)?
    private var connectionStatusStorage = "native runtime"
    private var currentSessionIDStorage: String?
    private var eventContinuation: AsyncStream<WorkbenchEvent>.Continuation?
    public let eventStream: AsyncStream<WorkbenchEvent>
    private let workspaceBookmark: Data?
    private let forceOfflineDemo: Bool
    private let modelDownloadManager: GUSModelDownloadManager
    
    public init(workspaceBookmark: Data? = nil, forceOfflineDemo: Bool = false,
                modelDownloadManager: GUSModelDownloadManager = .shared) {
        self.workspaceBookmark = workspaceBookmark
        self.forceOfflineDemo = forceOfflineDemo
        self.modelDownloadManager = modelDownloadManager
        var cont: AsyncStream<WorkbenchEvent>.Continuation?
        self.eventStream = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }
    
    public var connectionStatus: String {
        get async { connectionStatusStorage }
    }
    
    public var currentSessionID: String? {
        get async { currentSessionIDStorage }
    }
    
    public func connectRemote(pairing: BackendPairing) async throws {
        throw WorkbenchError.unsupportedFeature("Native backend doesn't support remote connection")
    }
    
    public func disconnect() async {
        await releaseActiveModel()
        failPendingPermissions()
        runtimes.removeAll()
        activeModelName = nil
        toolExecutor = nil
        sandboxExecutor = nil
        workspace = nil
        persistence = nil
        currentSessionIDStorage = nil
        connectionStatusStorage = ""
        eventContinuation?.yield(.disconnected("Native runtime stopped"))
        eventContinuation?.finish()
    }
    
    public func useNativeRuntime() async throws {
        guard workspace == nil else { return }
        
        do {
            let ws: IOSWorkspace
            if let workspaceBookmark {
                ws = try IOSWorkspace(securityScopedBookmark: workspaceBookmark)
            } else {
                ws = try IOSWorkspace()
            }
            let ps = try IOSPersistence()
            self.workspace = ws
            self.persistence = ps
            
            let exec = NativeCapabilityToolExecutor(workspace: ws, persistence: ps)
            self.toolExecutor = exec
            try await reloadSandboxModel()
            eventContinuation?.yield(.connected)
        } catch {
            connectionStatusStorage = "error: \(error.localizedDescription)"
            throw error
        }
    }

    /// Points the agent's tools at a sandbox on the computer. The running loop is
    /// dropped so the next prompt is built with the sandbox tools and prompt.
    public func attachSandbox(_ executor: SandboxToolExecutor, projectName: String, projectPath: String) {
        failPendingPermissions()
        cancelAllRuns()
        sandboxExecutor = executor
        sandboxProjectName = projectName
        sandboxProjectPath = projectPath
        invalidateLoops()
    }

    /// Back to the iPhone workspace tools.
    public func detachSandbox() {
        guard sandboxExecutor != nil else { return }
        failPendingPermissions()
        cancelAllRuns()
        sandboxExecutor = nil
        sandboxProjectName = nil
        sandboxProjectPath = nil
        invalidateLoops()
    }

    public var isUsingSandbox: Bool { sandboxExecutor != nil }

    // MARK: - Conversation runtimes

    private var currentRuntime: ConversationRuntime? {
        currentSessionIDStorage.flatMap { runtimes[$0] }
    }

    /// Tools of the conversation on screen (its own folder), or the shared ones before
    /// any conversation is open.
    private var currentExecutor: NativeCapabilityToolExecutor? {
        currentRuntime?.executor ?? toolExecutor
    }

    private var currentWorkspace: IOSWorkspace? {
        currentRuntime?.workspace ?? workspace
    }

    /// Ids of the conversations with a turn in progress.
    public var runningSessionIDs: Set<String> {
        Set(runtimes.values.filter(\.isRunning).map(\.sessionID))
    }

    /// Loops are rebuilt lazily, so a turn in progress is never cut by a rebuild.
    private func invalidateLoops() {
        loopGeneration += 1
    }

    private func cancelAllRuns() {
        for runtime in runtimes.values {
            runtime.runningTask?.cancel()
        }
    }

    /// Forgets idle runtimes whose folder was just deleted, so their next turn recreates it.
    public func forgetIdleRuntimes(folderNames: Set<String>) {
        for (id, runtime) in runtimes where !runtime.isRunning && folderNames.contains(ConversationSandboxes.folderName(for: id)) {
            runtimes[id] = nil
        }
    }

    // MARK: - Disposable clones on the iPhone

    /// Downloads a public GitHub repository into the conversation's folder and makes it the active project.
    public func cloneRepository(_ repository: String) async throws -> RepositoryCloner.Report {
        guard let exec = currentExecutor else { throw WorkbenchError.notConnected }
        return try await exec.cloneRepository(repository)
    }

    public func activePhoneProject() async -> String? {
        await currentExecutor?.activeProject()
    }

    public func canUndoPhoneProjectChange() async -> Bool {
        await currentExecutor?.canUndoLastChange() ?? false
    }

    public func undoPhoneProjectChange() async throws -> String {
        guard let exec = currentExecutor else { throw WorkbenchError.notConnected }
        return try await exec.undoLastChange()
    }

    public func closeActivePhoneProject() async {
        await currentExecutor?.closeActiveProject()
    }

    /// Loads the selected provider when its key exists, then falls back to any
    /// configured supported provider. No key keeps the offline demo available.
    public func reloadSandboxModel() async throws {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        await releaseActiveModel()
        if forceOfflineDemo {
            installOfflineDemo()
            return
        }
        let configuration = try await ps.loadConfiguration()
        let preference = configuration?.defaultModelProvider ?? "nvidia"
        gusPermissionMode = preference == "gus-local"
        await toolExecutor?.setGUSPermissionMode(gusPermissionMode)
        for runtime in runtimes.values {
            await runtime.executor.setGUSPermissionMode(gusPermissionMode)
        }
        if preference == "gus-local" {
            await modelDownloadManager.refresh()
            guard let manifest = modelDownloadManager.selectedManifest,
                  let modelURL = modelDownloadManager.selectedModelURL else {
                throw ModelProviderError.notConfigured("Descarga y selecciona un modelo GUS verificado desde la pantalla sandbox.")
            }

            if GUSDualModelExperimentSettings.isEnabled {
                let qwenManifest = GUSModelManifest.qwen25Q4KM
                let smolManifest = GUSModelManifest.smolLM2Q4KM
                guard let qwenURL = modelDownloadManager.modelURL(id: qwenManifest.id),
                      let smolURL = modelDownloadManager.modelURL(id: smolManifest.id) else {
                    try await installSingleLocalModel(manifest: manifest, modelURL: modelURL)
                    connectionStatusStorage += " · Smol unavailable; single-model fallback"
                    eventContinuation?.yield(.auxiliaryModelStatus(.unavailable))
                    return
                }

                let qwen = GUSLocalModelProvider(modelURL: qwenURL, manifest: qwenManifest)
                let smol = GUSAuxiliaryModelRunner(modelURL: smolURL)
                do {
                    try await qwen.load(contextTokens: 2048)
                    try await smol.load()
                    let coordinator = GUSDualModelCoordinator(qwen: qwen, smol: smol) { [weak self] status in
                        await self?.sendWorkbenchEvent(.auxiliaryModelStatus(status))
                    }
                    modelProvider = coordinator
                    activeModelName = coordinator.availableModels.first
                    providerID = coordinator.id
                    providerDisplay = coordinator.name
                    providerModelIDs = coordinator.availableModels
                    isDualSmolActive = true
                    invalidateLoops()
                    connectionStatusStorage = "sandbox · GUS local · Dual-Smol experimental · Qwen2.5-0.5B + SmolLM2-360M · 2K · sin conexión de proveedor"
                    eventContinuation?.yield(.auxiliaryModelStatus(.active))
                    return
                } catch {
                    await smol.unload()
                    await qwen.unload()
                    try await installSingleLocalModel(manifest: manifest, modelURL: modelURL)
                    connectionStatusStorage += " · Smol unavailable; single-model fallback"
                    eventContinuation?.yield(.auxiliaryModelStatus(.unavailable))
                    return
                }
            }

            let provider = GUSLocalModelProvider(modelURL: modelURL, manifest: manifest)
            try await provider.load(contextTokens: 2048)
            modelProvider = provider
            activeModelName = provider.availableModels.first
            providerID = provider.id
            providerDisplay = provider.name
            providerModelIDs = provider.availableModels
            isDualSmolActive = false
            invalidateLoops()
            connectionStatusStorage = "sandbox · GUS local · \(manifest.modelName) · 2K · sin conexión de proveedor"
            return
        }
        var order = [preference]
        let fallbackOrder = SandboxModelProvider.all.map(\.id).filter { !order.contains($0) }
        order.append(contentsOf: fallbackOrder)
        for providerID in order {
            guard let provider = SandboxModelProvider.provider(id: providerID) else { continue }
            if provider.id == "chatgpt-oauth" {
                guard ChatGPTOAuthStore.hasStoredTokens() else { continue }
                do {
                    try await installChatGPTCodexProvider(savedModelName: providerID == preference ? configuration?.defaultModelName : nil)
                } catch ModelProviderError.authenticationFailed where providerID != preference {
                    continue
                }
                if providerID != preference, let wanted = SandboxModelProvider.provider(id: preference) {
                    connectionStatusStorage += " · \(wanted.name) no disponible (sin clave); usando \(provider.name)"
                }
                return
            }
            guard let key = try await ps.loadAPIKey(provider: provider.id), !key.isEmpty else { continue }
            do {
                try await installRemoteProvider(id: provider.id, display: provider.name, key: key,
                    baseURL: provider.baseURL, preferred: provider.preferredModels, fallback: provider.fallbackModel,
                    curatedOnly: provider.curatedOnly,
                    savedModelName: providerID == preference ? configuration?.defaultModelName : nil)
            } catch ModelProviderError.authenticationFailed where providerID != preference {
                continue
            }
            // Never switch providers silently: the user picked another one.
            if providerID != preference, let wanted = SandboxModelProvider.provider(id: preference) {
                connectionStatusStorage += " · \(wanted.name) no disponible (sin clave); usando \(provider.name)"
            }
            return
        }
        installOfflineDemo()
    }


    /// Stops every conversation's turn (they all use this model) before unloading it.
    private func releaseActiveModel() async {
        let activeTasks = runtimes.values.compactMap(\.runningTask)
        cancelAllRuns()
        failPendingPermissions()
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.cancel()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.cancel()
        }
        for task in activeTasks {
            await task.value
        }
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.unload()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.unload()
        }
        isDualSmolActive = false
        invalidateLoops()
        modelProvider = nil
        activeModelName = nil
    }

    /// The on-device model has one context: its turns go through `localModelGate`.
    private var usesOnDeviceModel: Bool {
        modelProvider is GUSLocalModelProvider || modelProvider is GUSDualModelCoordinator
    }

    private func installOfflineDemo() {
        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        modelProvider = provider
        activeModelName = provider.availableModels.first
        providerID = "scripted"
        providerDisplay = "Scripted Demo"
        providerModelIDs = provider.availableModels
        isDualSmolActive = false
        invalidateLoops()
        connectionStatusStorage = "sandbox · offline demo. No API key or network required."
    }

    private func installRemoteProvider(
        id: String,
        display: String,
        key: String,
        baseURL: String,
        preferred: [String],
        fallback: String,
        curatedOnly: Bool = false,
        savedModelName: String? = nil
    ) async throws {
        let remote = RemoteModelProvider(
            id: id,
            name: display,
            // Every API provider can carry images; whether a model sees them is its own
            // call (a refusal is retried with notes). Evaluating here, without the model,
            // marked NVIDIA as image-less even with Nemotron VL selected.
            supportsImages: true
        )
        try await remote.configure(ModelConfiguration(apiKey: key, baseURL: baseURL))
        let listed = await remote.availableModels
        let models = SandboxModelCatalog.orderedModelIDs(available: listed, preferred: preferred, fallback: fallback, curatedOnly: curatedOnly)
        modelProvider = remote
        if let savedModelName, models.contains(savedModelName) {
            activeModelName = savedModelName
        } else {
            activeModelName = models.contains(fallback) ? fallback : models[0]
        }
        providerID = id
        providerDisplay = display
        providerModelIDs = models
        isDualSmolActive = false
        invalidateLoops()
        connectionStatusStorage = "sandbox · \(activeModelName ?? fallback)"
    }

    private func installChatGPTCodexProvider(savedModelName: String?) async throws {
        let codex = ChatGPTCodexProvider()
        try await codex.configure(ModelConfiguration())
        let models = await codex.availableModels
        modelProvider = codex
        if let savedModelName, models.contains(savedModelName) {
            activeModelName = savedModelName
        } else {
            activeModelName = models.first
        }
        providerID = codex.id
        providerDisplay = codex.name
        providerModelIDs = models
        isDualSmolActive = false
        invalidateLoops()
        connectionStatusStorage = "sandbox · \(activeModelName ?? "ChatGPT OAuth")"
    }

    /// Makes `sessionID` the conversation on screen and returns its runtime, building it
    /// on first use or when the model/tools changed while it was idle. Opening another
    /// conversation no longer cancels the one that is working: each keeps its own loop.
    @discardableResult
    private func installLoop(sessionID: String) async -> ConversationRuntime? {
        // El vigilante del buzón [GUS] arranca con la sesión (idempotente: si ya
        // está corriendo, no hace nada). Sin sesión no hay dónde ejecutar.
        await maybeStartMailboxWatcher()
        currentSessionIDStorage = sessionID
        defer { resendPendingPermission(for: sessionID) }

        let existing = runtimes[sessionID]
        if let existing, existing.generation == loopGeneration || existing.isRunning {
            return existing
        }
        guard let ps = persistence, let provider = modelProvider else { return nil }

        // Own folder per conversation; the folder the person picked in Files is shared.
        // A rebuilt runtime keeps its folder and executor (active project, undo history).
        let ws: IOSWorkspace
        let exec: NativeCapabilityToolExecutor
        if let existing {
            ws = existing.workspace
            exec = existing.executor
        } else if workspaceBookmark == nil {
            do {
                ws = try IOSWorkspace(rootName: ConversationSandboxes.folderName(for: sessionID))
            } catch {
                eventContinuation?.yield(.sessionError("No pude crear la carpeta de esta conversación: \(error.localizedDescription)"))
                return nil
            }
            exec = NativeCapabilityToolExecutor(
                workspace: ws,
                persistence: ps,
                activeProjectKey: ConversationSandboxes.activeProjectKey(for: sessionID)
            )
        } else {
            guard let shared = workspace, let sharedExecutor = toolExecutor else { return nil }
            ws = shared
            exec = sharedExecutor
        }

        await exec.setGUSPermissionMode(gusPermissionMode)
        let activeContract = AgentContractStore.shared.activeAgentForSession
        await exec.setActiveContract(activeContract)
        await exec.configureSharedMemory(localOnly: provider.capabilities.localOnly, conversationID: sessionID)
        // With a sandbox linked the agent also gets the iPhone's companion tools (Google, notifications, Shortcuts):
        // before, it used only the sandbox's and could not read the person's mail.
        let activeExecutor: any ToolExecutor
        if let sandboxExecutor {
            activeExecutor = CompositeToolExecutor(primary: sandboxExecutor, secondary: exec)
        } else {
            activeExecutor = exec
        }
        let loop = AgentLoop(context: AgentContext(
            conversationId: sessionID,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            modelName: activeModelName,
            toolExecutor: activeExecutor,
            systemPrompt: systemPromptText(contract: activeContract),
            maxTurns: 12,
            permissionHandler: { [weak self] request in
                guard let self else {
                    return PermissionResponse(requestId: request.id, decision: .deny)
                }
                // Flow NEVER bypasses tools that require fresh per-operation confirmation (Section 12).
                if await self.flowMode && !request.requiresApprovalEveryTime {
                    return PermissionResponse(requestId: request.id, decision: .allowOnce)
                }
                let decision = await self.waitForPermission(request, sessionID: sessionID)
                return PermissionResponse(requestId: request.id, decision: decision)
            }
        ))
        await loop.setEventHandler { [weak self] event in
            await self?.handleAgentEvent(event, sessionID: sessionID)
        }
        let runtime = ConversationRuntime(sessionID: sessionID, loop: loop, executor: exec, workspace: ws, generation: loopGeneration)
        runtimes[sessionID] = runtime
        return runtime
    }

    private func waitForPermission(_ request: PermissionRequest, sessionID: String) async -> PermissionResponse.Decision {
        let event = WorkbenchEvent.permissionAsked(
            requestID: request.id,
            sessionID: sessionID,
            tool: request.toolName,
            command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            explanation: request.reason
        )
        pendingPermissionEvents[sessionID] = event
        eventContinuation?.yield(event)
        return await withCheckedContinuation { continuation in
            permissionWaiters[request.id] = (sessionID, continuation)
        }
    }

    /// The store shows a permission only for the conversation on screen; re-ask when the
    /// person opens a conversation that has been waiting in the background.
    private func resendPendingPermission(for sessionID: String) {
        guard let event = pendingPermissionEvents[sessionID] else { return }
        eventContinuation?.yield(event)
    }

    /// Denies the waiting permissions of one conversation, or of all when `sessionID` is nil.
    private func failPendingPermissions(for sessionID: String? = nil) {
        let matching = permissionWaiters.filter { sessionID == nil || $0.value.sessionID == sessionID }
        for (requestID, waiter) in matching {
            permissionWaiters[requestID] = nil
            pendingPermissionEvents[waiter.sessionID] = nil
            waiter.continuation.resume(returning: .deny)
        }
    }
    
    private func systemPromptText(contract: AgentContract? = nil) -> String {
        let base: String
        if let sandboxExecutor {
            base = sandboxExecutor.systemPrompt + "\n" + CompositeToolExecutor.layersNote
        } else {
            base = GUSMobileRole.mobile.systemPrompt + "\n\n" +
                "También cuentas con `python_eval` (pocketpy 2.2.0 sin acceso a OS/red) para procesar CSV, JSON, cálculos exactos y validaciones en memoria, " +
                "y con `isymcp_status` / `isymcp_tasks` / `isymcp_respond_task` si el usuario emparejó su PC por ISyMCP (Tailscale :8797)."
        }
        guard let contract else { return base }
        return contract.effectiveSystemPrompt() + "\n\n" + base
    }

    public func revokeSequenceApproval() async {
        await currentRuntime?.loop.revokeSequenceApproval()
    }

    public func listProjects() async throws -> [Project] {
        guard let ws = currentWorkspace else { throw WorkbenchError.notConnected }
        let project = Project(
            id: "native:\(ws.rootURL.lastPathComponent)",
            name: sandboxProjectName.map { "\($0) · sandbox" } ?? "iOS Sandbox",
            path: sandboxProjectPath ?? ws.rootURL.path,
            avatarColor: .blue,
            sessionCount: 0
        )
        return [project]
    }
    
    public func listSessions(projectID: String) async throws -> [Session] {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        let convs = try await ps.listConversations()
        return convs.map { c in
            Session(
                id: c.id,
                projectId: projectID,
                title: c.title,
                lastEventSummary: c.lastMessagePreview ?? "Sin mensajes",
                timestamp: c.updatedAt,
                agentMode: .build,
                isRunning: false
            )
        }
    }
    
    public func createSession(projectID: String, title: String) async throws -> Session {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        let conv = Conversation(title: title.isEmpty ? "Nueva conversación" : title)
        try await ps.saveConversation(conv)
        await installLoop(sessionID: conv.id)
        eventContinuation?.yield(.sessionsChanged)
        return Session(id: conv.id, projectId: projectID, title: conv.title, lastEventSummary: "Conversación nueva", timestamp: conv.updatedAt, agentMode: .build, isRunning: false)
    }
    
    public func renameSession(sessionID: String, title: String) async throws {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        if var conv = try await ps.loadConversation(id: sessionID) {
            conv.title = title
            try await ps.saveConversation(conv)
            eventContinuation?.yield(.sessionsChanged)
        }
    }
    
    public func deleteSession(sessionID: String) async throws {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        try await ps.deleteConversation(id: sessionID)
        // Its folder stays on disk until "Limpiar" in Ajustes: deleting a chat should
        // not silently delete files the agent made.
        if let runtime = runtimes[sessionID] {
            await stopRun(runtime)
        }
        runtimes[sessionID] = nil
        if currentSessionIDStorage == sessionID {
            currentSessionIDStorage = nil
        }
        eventContinuation?.yield(.sessionsChanged)
    }
    
    public func selectSession(_ sessionID: String) async throws {
        guard persistence != nil else { throw WorkbenchError.notConnected }
        await installLoop(sessionID: sessionID)
    }
    
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        try await sendPrompt(text, multimodalParts: [], agent: agent, model: model)
    }

    public func sendPrompt(
        _ text: String,
        multimodalParts: [ModelMessage.ContentPart],
        agent: String?,
        model: ModelInfo?
    ) async throws {
        guard let sessionID = currentSessionIDStorage else { throw WorkbenchError.noSession }
        if let requested = model?.apiModelId, providerModelIDs.contains(requested), requested != activeModelName {
            activeModelName = requested
            invalidateLoops()
        }
        guard let runtime = await installLoop(sessionID: sessionID) else {
            throw WorkbenchError.unsupportedFeature("Agent runtime not initialized")
        }
        guard !runtime.isRunning else {
            throw WorkbenchError.unsupportedFeature("Esta conversación todavía está trabajando. Espera a que termine o detenla.")
        }
        let loop = runtime.loop

        await PermissionNotifier.shared.prepare()
        if let ps = persistence, var conv = try? await ps.loadConversation(id: sessionID) {
            let trimmedTitle = conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.isEmpty || trimmedTitle == "Nueva conversación" {
                let candidate = await ConversationTitleService.generateTitle(from: text)
                if !candidate.isEmpty {
                    conv.title = candidate
                    try? await ps.saveConversation(conv)
                    eventContinuation?.yield(.sessionsChanged)
                }
            }
        }
        runtime.mayHaveLeftApp = false
        // A mailbox turn's acknowledgement belongs to this turn only.
        let mailboxCompletion = mailboxTurnCompletion
        mailboxTurnCompletion = nil
        let onDeviceModel = usesOnDeviceModel
        let gate = localModelGate
        BackgroundRunKeeper.shared.begin()
        eventContinuation?.yield(.sessionRunState(sessionID: sessionID, state: .running))
        runtime.runningTask = Task { [weak self, runtime] in
            var holdsModel = false
            if onDeviceModel {
                // The on-device model serves one conversation at a time: wait in line.
                if await gate.isBusy {
                    self?.eventContinuation?.yield(.sessionRunState(sessionID: sessionID, state: .queued))
                }
                holdsModel = await gate.acquire()
                runtime.holdsLocalModel = holdsModel
                if holdsModel {
                    self?.eventContinuation?.yield(.sessionRunState(sessionID: sessionID, state: .running))
                }
            }
            if !onDeviceModel || holdsModel {
                do {
                    try Task.checkCancellation()
                    _ = try await loop.run(userInput: text, multimodalParts: multimodalParts)
                    await self?.returnToAppIfNeeded(runtime)
                    mailboxCompletion?(true)
                } catch is CancellationError {
                    // Stopped: the mailbox task stays "en curso" and is retried later.
                } catch {
                    mailboxCompletion?(false)
                    if self?.currentSessionIDStorage == sessionID {
                        self?.eventContinuation?.yield(.sessionError(error.localizedDescription))
                    }
                }
            }
            if holdsModel {
                runtime.holdsLocalModel = false
                await gate.release()
            }
            runtime.runningTask = nil
            BackgroundRunKeeper.shared.end()
            self?.eventContinuation?.yield(.sessionRunState(sessionID: sessionID, state: .idle))
            self?.eventContinuation?.yield(.sessionsChanged)
        }
    }

    /// Stops the conversation on screen only; the others keep working.
    public func abort() async throws {
        guard let runtime = currentRuntime else { return }
        await stopRun(runtime)
        eventContinuation?.yield(.sessionError("Stopped"))
    }

    private func stopRun(_ runtime: ConversationRuntime) async {
        failPendingPermissions(for: runtime.sessionID)
        runtime.runningTask?.cancel()
        // Interrupt the on-device generation only when this conversation is the one using it.
        guard runtime.holdsLocalModel else { return }
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.cancel()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.cancel()
        }
    }

    private func installSingleLocalModel(manifest: GUSModelManifest, modelURL: URL) async throws {
        let provider = GUSLocalModelProvider(modelURL: modelURL, manifest: manifest)
        try await provider.load(contextTokens: 2048)
        modelProvider = provider
        activeModelName = provider.availableModels.first
        providerID = provider.id
        providerDisplay = provider.name
        providerModelIDs = provider.availableModels
        isDualSmolActive = false
        invalidateLoops()
        connectionStatusStorage = "sandbox · GUS local · \(manifest.modelName) · 2K · sin conexión de proveedor"
    }
    
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        guard let waiter = permissionWaiters.removeValue(forKey: requestID) else { return }
        pendingPermissionEvents[waiter.sessionID] = nil
        waiter.continuation.resume(returning: decision)
    }

    // MARK: - Buzón [GUS] (loop GUS ↔ Muse, Fase 3)

    /// Arranca el vigilante del buzón [GUS] si el usuario lo activó en Ajustes.
    /// Idempotente: si ya está corriendo, no hace nada.
    public func maybeStartMailboxWatcher() async {
        guard GUSMailboxWatcher.isEnabled else { return }
        await GUSMailboxWatcher.shared.startPolling { [weak self] task, body in
            guard let self else { return }
            await self.deliverMailboxTask(task, body: body)
        }
    }

    public func stopMailboxWatcher() async {
        await GUSMailboxWatcher.shared.stopPolling()
    }

    /// Entrega una tarea pendiente del buzón [GUS] como un turno del agente.
    /// Marca `en curso` al tomarla y `hecho` solo si el turno terminó bien; si falla
    /// o no se puede entregar, queda `en curso` y el vigilante la reintenta cuando se
    /// vuelve obsoleta (el buzón es la fuente de verdad). No entrega si ya hay un
    /// turno en marcha o no hay sesión abierta: la tarea sigue pendiente en el buzón.
    private func deliverMailboxTask(_ task: GUSMailboxWatcher.MailboxTask, body: String) async {
        guard currentSessionIDStorage != nil, currentRuntime?.isRunning != true else { return }
        do {
            try await GUSMailboxWatcher.shared.mark(
                taskID: task.id, state: .enCurso, recipient: task.recipient,
                note: "GUS tomó la tarea \(task.id)."
            )
        } catch {
            GUSFlightRecorder.shared.record("gus.mailbox.mark_error", ["task": task.id, "error": error.localizedDescription])
            return
        }
        mailboxTurnCompletion = { [weak self] success in
            guard let self, success else { return }
            Task {
                try? await GUSMailboxWatcher.shared.mark(
                    taskID: task.id, state: .hecho, recipient: task.recipient,
                    note: "Hecho: turno completado."
                )
            }
        }
        let text = "[Buzón GUS · tarea \(task.id)]\n\(body)"
        do {
            try await sendPrompt(text, agent: nil, model: nil)
        } catch {
            mailboxTurnCompletion = nil
            GUSFlightRecorder.shared.record("gus.mailbox.deliver_error", ["task": task.id, "error": error.localizedDescription])
        }
    }
    
    public func loadHistory(sessionID: String) async throws -> [TimelineEvent] {
        guard let ps = persistence else { return [] }
        guard let conv = try await ps.loadConversation(id: sessionID) else { return [] }
        var events: [TimelineEvent] = []
        for message in conv.messages {
            switch message.role {
            case .user:
                events.append(TimelineEvent.userPrompt(message.content, agentMode: .build))
            case .assistant:
                events.append(TimelineEvent.assistantText(message.content, agentMode: .build))
                for call in message.toolCalls ?? [] {
                    events.append(TimelineEvent.toolCall(id: call.id, name: call.name, arguments: call.arguments, state: .success, agentMode: .build))
                }
                for result in message.toolResults ?? [] {
                    events.append(TimelineEvent.toolResult(
                        name: "tool",
                        output: result.output,
                        duration: 0,
                        state: result.error == nil ? .success : .failed,
                        agentMode: .build
                    ))
                }
            case .system:
                events.append(TimelineEvent.system(message.content))
            default:
                break
            }
        }
        return events
    }
    
    public func startEventStream() async throws {
        // AgentLoop events are already pushed via event handler
    }
    
    public func stopEventStream() async {
        failPendingPermissions()
        cancelAllRuns()
    }

    /// Files of the conversation on screen (its own folder).
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] {
        if let sandboxExecutor { return try await sandboxExecutor.listFiles(path: path) }
        guard let ws = currentWorkspace else { throw WorkbenchError.notConnected }
        let items = try await ws.listDirectory(at: path)
        return items.map { item in
            WorkbenchFileNode(
                id: UUID().uuidString,
                name: item.name,
                path: item.path,
                isDirectory: item.isDirectory,
                size: item.size,
                modifiedAt: item.modificationDate
            )
        }
    }
    
    public func fileContent(path: String) async throws -> WorkbenchFileContent {
        if let sandboxExecutor { return try await sandboxExecutor.fileContent(path: path) }
        guard let ws = currentWorkspace else { throw WorkbenchError.notConnected }
        let data = try await ws.readFile(at: path)
        return WorkbenchFileContent(path: path, content: String(data: data, encoding: .utf8) ?? "", mimeType: nil, encoding: "utf-8")
    }
    
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] {
        throw WorkbenchError.unsupportedFeature("Diff requires remote OpenCode server")
    }
    
    public func runShell(command: String, agent: String?) async throws -> ShellResult {
        if let sandboxExecutor {
            let output = try await sandboxExecutor.shell(command)
            return ShellResult(sessionID: currentSessionIDStorage ?? "", messageID: "", parts: [
                RemotePart(id: UUID().uuidString, messageID: nil, kind: .text, text: output, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil)
            ])
        }
        throw WorkbenchError.unsupportedFeature("Shell requires remote OpenCode server")
    }
    
    public func availableProviders() async throws -> ProviderListResult {
        let models: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: providerModelIDs.map { ($0, [String: Any]()) })
        var allProviders = [ProviderInfo(id: providerID, name: providerDisplay, models: models)]
        var connected = [providerID]
        if providerID != "chatgpt-oauth", ChatGPTOAuthStore.hasStoredTokens() {
            let codex = ChatGPTCodexProvider()
            var discovered = ChatGPTOAuthStore.storedModelIDs()
            if discovered.isEmpty {
                try? await codex.configure(ModelConfiguration())
                discovered = await codex.availableModels
            }
            if !discovered.isEmpty {
                let codexModels: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: discovered.map { ($0, [String: Any]()) })
                allProviders.append(ProviderInfo(id: codex.id, name: codex.name, models: codexModels))
                connected.append(codex.id)
            }
        }
        return ProviderListResult(
            all: allProviders,
            connected: connected,
            defaultProvider: providerID
        )
    }
    
    public func config() async throws -> ConfigInfo {
        return ConfigInfo(agents: ["build": [:], "plan": [:], "explore": [:], "review": [:], "custom": [:]], provider: nil)
    }
    
    public func availableCommands() async throws -> [CommandInfo] {
        return []
    }
    
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {
        eventContinuation?.yield(event)
    }
    
    private static func toolMayLeaveApp(_ name: String) -> Bool {
        name == "iphone_launch_app" || name == "iphone_press_button" || name == "iphone_open_url" || name == "shortcuts.run"
    }

    private func returnToAppIfNeeded(_ runtime: ConversationRuntime) async {
        guard runtime.mayHaveLeftApp else { return }
        runtime.mayHaveLeftApp = false
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        let executor: (any ToolExecutor)? = sandboxExecutor ?? runtime.executor
        if let executor,
           executor.availableTools.contains(where: { $0.name == "iphone_launch_app" }) {
            _ = await executor.execute(
                ToolInvocation(id: "return-\(UUID().uuidString)", name: "iphone_launch_app", arguments: ["app": bundleID]),
                approval: .allowOnce
            )
        } else {
            try? await WdaClient().launchApp(bundleID: bundleID)
        }
    }

    /// Live parts reach the screen only for the conversation on it. A conversation working
    /// in the background still saves every message (AgentLoop persists as it goes), so
    /// opening it later shows its history; switching mid-answer picks up the stream.
    private func handleAgentEvent(_ event: AgentLoopEvent, sessionID: String) async {
        guard let runtime = runtimes[sessionID] else { return }
        let onScreen = currentSessionIDStorage == sessionID
        func yieldOnScreen(_ workbenchEvent: WorkbenchEvent) {
            if onScreen { eventContinuation?.yield(workbenchEvent) }
        }
        switch event {
        case .turnStarted:
            runtime.liveAnswerID = nil

        case .modelDelta(let delta):
            let partID = runtime.liveAnswerID ?? "sandbox-\(UUID().uuidString)"
            runtime.liveAnswerID = partID
            yieldOnScreen(.partDelta(partID: partID, delta: delta))

        case .modelResponse(let response):
            if runtime.liveAnswerID == nil, !response.content.isEmpty {
                yieldOnScreen(.partUpdated(partID: UUID().uuidString, kind: "assistantText", text: response.content, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            } else if let id = runtime.liveAnswerID, !response.content.isEmpty {
                yieldOnScreen(.partUpdated(partID: id, kind: "assistantText", text: response.content, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            }
            runtime.liveAnswerID = nil
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    if Self.toolMayLeaveApp(call.name) {
                        runtime.mayHaveLeftApp = true
                    }
                    yieldOnScreen(.partUpdated(partID: call.id, kind: "tool", text: nil, tool: call.name, callID: call.id, status: "running", input: call.arguments, output: nil, error: nil))
                }
            }

        case .toolResult(let result):
            let state: String
            switch result.error {
            case nil: state = "completed"
            default: state = "error"
            }
            yieldOnScreen(.partUpdated(
                partID: result.toolCallId,
                kind: "tool",
                text: nil,
                tool: nil,
                callID: result.toolCallId,
                status: state,
                input: [:],
                output: result.output,
                error: result.error
            ))
            
        case .error(let error):
            yieldOnScreen(.sessionError(error.localizedDescription))

        case .sequenceScopeChanged(let scope):
            yieldOnScreen(.sequenceScopeChanged(scope))

        case .finished:
            // The store matches the id itself, so the conversation that finished is the
            // one marked idle even when another is on screen.
            eventContinuation?.yield(.sessionIdle(sessionID: sessionID))
            
        default:
            break
        }
    }
}

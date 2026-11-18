import Foundation
import SwiftUI

@MainActor
public final class NativeSwiftBackend: WorkbenchBackend {
    public var mode: BackendMode { .native }
    
    private var workspace: IOSWorkspace?
    var persistence: IOSPersistence?
    private var agentLoop: AgentLoop?
    private var modelProvider: (any ModelProvider)?
    private var activeModelName: String?
    private var providerID = "scripted"
    private var providerDisplay = "Scripted Demo"
    private var providerModelIDs = ["scripted-1"]
    public private(set) var isDualSmolActive = false
    public var usesLiveModel: Bool { providerID != "scripted" }
    public var activeProviderID: String { providerID }
    public var currentModelName: String? { activeModelName }
    private var liveAnswerID: String?
    private var toolExecutor: NativeCapabilityToolExecutor?
    /// When set, the agent's tools run in a Docker sandbox on the user's computer
    /// instead of the iPhone workspace. The model and the conversation stay here.
    private var sandboxExecutor: SandboxToolExecutor?
    private var sandboxProjectName: String?
    private var sandboxProjectPath: String?
    private var boundSessionID: String?
    private var runningTask: Task<Void, Never>?
    private var permissionWaiters: [String: CheckedContinuation<PermissionResponse.Decision, Never>] = [:]
    public var flowMode = false
    /// Acuse de recibo del turno del buzón [GUS] (una sola vez): lo pone
    /// deliverMailboxTask y lo resuelve el Task de sendPrompt al terminar el turno.
    /// Nil en turnos normales del usuario.
    private var mailboxTurnCompletion: ((Bool) -> Void)?
    private var mayHaveLeftAppInTurn = false
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
        boundSessionID = nil
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
        runningTask?.cancel()
        runningTask = nil
        sandboxExecutor = executor
        sandboxProjectName = projectName
        sandboxProjectPath = projectPath
        agentLoop = nil
        boundSessionID = nil
    }

    /// Back to the iPhone workspace tools.
    public func detachSandbox() {
        guard sandboxExecutor != nil else { return }
        failPendingPermissions()
        runningTask?.cancel()
        runningTask = nil
        sandboxExecutor = nil
        sandboxProjectName = nil
        sandboxProjectPath = nil
        agentLoop = nil
        boundSessionID = nil
    }

    public var isUsingSandbox: Bool { sandboxExecutor != nil }

    // MARK: - Disposable clones on the iPhone

    /// Downloads a public GitHub repository into the workspace and makes it the active project.
    public func cloneRepository(_ repository: String) async throws -> RepositoryCloner.Report {
        guard let exec = toolExecutor else { throw WorkbenchError.notConnected }
        return try await exec.cloneRepository(repository)
    }

    public func activePhoneProject() async -> String? {
        await toolExecutor?.activeProject()
    }

    public func canUndoPhoneProjectChange() async -> Bool {
        await toolExecutor?.canUndoLastChange() ?? false
    }

    public func undoPhoneProjectChange() async throws -> String {
        guard let exec = toolExecutor else { throw WorkbenchError.notConnected }
        return try await exec.undoLastChange()
    }

    public func closeActivePhoneProject() async {
        await toolExecutor?.closeActiveProject()
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
        await toolExecutor?.setGUSPermissionMode(preference == "gus-local")
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
                    agentLoop = nil
                    boundSessionID = nil
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
            agentLoop = nil
            boundSessionID = nil
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


    private func releaseActiveModel() async {
        runningTask?.cancel()
        let activeTask = runningTask
        runningTask = nil
        failPendingPermissions()
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.cancel()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.cancel()
        }
        await activeTask?.value
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.unload()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.unload()
        }
        isDualSmolActive = false
        agentLoop = nil
        modelProvider = nil
        activeModelName = nil
        boundSessionID = nil
    }

    private func installOfflineDemo() {
        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        modelProvider = provider
        activeModelName = provider.availableModels.first
        providerID = "scripted"
        providerDisplay = "Scripted Demo"
        providerModelIDs = provider.availableModels
        isDualSmolActive = false
        agentLoop = nil
        boundSessionID = nil
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
        let remote = RemoteModelProvider(id: id, name: display)
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
        agentLoop = nil
        boundSessionID = nil
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
        agentLoop = nil
        boundSessionID = nil
        connectionStatusStorage = "sandbox · \(activeModelName ?? "ChatGPT OAuth")"
    }

    /// The loop persists under the session the UI opened. A backend-wide id
    /// made `session.idle` miss the open session, so the composer never left Stop.
    private func installLoop(sessionID: String) async {
        // El vigilante del buzón [GUS] arranca con la sesión (idempotente: si ya
        // está corriendo, no hace nada). Sin sesión no hay dónde ejecutar.
        await maybeStartMailboxWatcher()
        guard let ws = workspace, let ps = persistence, let provider = modelProvider, let exec = toolExecutor else { return }
        await exec.configureSharedMemory(localOnly: provider.capabilities.localOnly, conversationID: sessionID)
        let modelName = activeModelName
        if boundSessionID == sessionID, agentLoop != nil {
            currentSessionIDStorage = sessionID
            return
        }
        failPendingPermissions()
        runningTask?.cancel()
        runningTask = nil
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
            modelName: modelName,
            toolExecutor: activeExecutor,
            systemPrompt: systemPromptText(),
            maxTurns: 12,
            permissionHandler: { [weak self] request in
                guard let self else {
                    return PermissionResponse(requestId: request.id, decision: .deny)
                }
                if await self.flowMode {
                    return PermissionResponse(requestId: request.id, decision: .allowOnce)
                }
                let decision = await self.waitForPermission(request)
                return PermissionResponse(requestId: request.id, decision: decision)
            }
        ))
        await loop.setEventHandler { [weak self] event in
            await self?.handleAgentEvent(event)
        }
        agentLoop = loop
        boundSessionID = sessionID
        currentSessionIDStorage = sessionID
    }

    private func waitForPermission(_ request: PermissionRequest) async -> PermissionResponse.Decision {
        guard let sessionID = currentSessionIDStorage else { return .deny }
        eventContinuation?.yield(.permissionAsked(
            requestID: request.id,
            sessionID: sessionID,
            tool: request.toolName,
            command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            explanation: request.reason
        ))
        return await withCheckedContinuation { continuation in
            permissionWaiters[request.id] = continuation
        }
    }

    private func failPendingPermissions() {
        let waiters = permissionWaiters
        permissionWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: .deny)
        }
    }
    
    private func systemPromptText() -> String {
        guard let sandboxExecutor else { return GUSMobileRole.mobile.systemPrompt }
        return sandboxExecutor.systemPrompt + "\n" + CompositeToolExecutor.layersNote
    }
    
    public func listProjects() async throws -> [Project] {
        guard let ws = workspace else { throw WorkbenchError.notConnected }
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
        if currentSessionIDStorage == sessionID {
            failPendingPermissions()
            runningTask?.cancel()
            runningTask = nil
            agentLoop = nil
            boundSessionID = nil
            currentSessionIDStorage = nil
        }
        eventContinuation?.yield(.sessionsChanged)
    }
    
    public func selectSession(_ sessionID: String) async throws {
        guard persistence != nil else { throw WorkbenchError.notConnected }
        await installLoop(sessionID: sessionID)
    }
    
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        guard let sessionID = currentSessionIDStorage else { throw WorkbenchError.noSession }
        if let requested = model?.apiModelId, providerModelIDs.contains(requested), requested != activeModelName {
            activeModelName = requested
            agentLoop = nil
            boundSessionID = nil
        }
        await installLoop(sessionID: sessionID)
        guard let loop = agentLoop else {
            throw WorkbenchError.unsupportedFeature("Agent runtime not initialized")
        }
        
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
        let sessionAtStart = sessionID
        mayHaveLeftAppInTurn = false
        BackgroundRunKeeper.shared.begin()
        runningTask = Task { [weak self] in
            defer {
                BackgroundRunKeeper.shared.end()
                self?.eventContinuation?.yield(.sessionsChanged)
            }
            guard let self else { return }
            do {
                _ = try await loop.run(userInput: text)
                await self.returnToAppIfNeeded()
                self.completeMailboxTurn(success: true)
            } catch is CancellationError {
                return
            } catch {
                self.completeMailboxTurn(success: false)
                guard self.currentSessionIDStorage == sessionAtStart else { return }
                self.eventContinuation?.yield(.sessionError(error.localizedDescription))
            }
        }
    }
    
    public func abort() async throws {
        failPendingPermissions()
        runningTask?.cancel()
        runningTask = nil
        if let dualProvider = modelProvider as? GUSDualModelCoordinator {
            await dualProvider.cancel()
        } else if let localProvider = modelProvider as? GUSLocalModelProvider {
            await localProvider.cancel()
        }
        eventContinuation?.yield(.sessionError("Stopped"))
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
        agentLoop = nil
        boundSessionID = nil
        connectionStatusStorage = "sandbox · GUS local · \(manifest.modelName) · 2K · sin conexión de proveedor"
    }
    
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        guard let waiter = permissionWaiters.removeValue(forKey: requestID) else { return }
        waiter.resume(returning: decision)
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

    /// Resuelve el acuse de recibo del turno del buzón (una sola vez). Nil en turnos normales.
    private func completeMailboxTurn(success: Bool) {
        guard let completion = mailboxTurnCompletion else { return }
        mailboxTurnCompletion = nil
        completion(success)
    }

    /// Entrega una tarea pendiente del buzón [GUS] como un turno del agente.
    /// Marca `en curso` al tomarla y `hecho` solo si el turno terminó bien; si falla
    /// o no se puede entregar, queda `en curso` y el vigilante la reintenta cuando se
    /// vuelve obsoleta (el buzón es la fuente de verdad). No entrega si ya hay un
    /// turno en marcha o no hay sesión abierta: la tarea sigue pendiente en el buzón.
    private func deliverMailboxTask(_ task: GUSMailboxWatcher.MailboxTask, body: String) async {
        guard runningTask == nil, currentSessionIDStorage != nil else { return }
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
        runningTask?.cancel()
        runningTask = nil
    }
    
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] {
        if let sandboxExecutor { return try await sandboxExecutor.listFiles(path: path) }
        guard let ws = workspace else { throw WorkbenchError.notConnected }
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
        guard let ws = workspace else { throw WorkbenchError.notConnected }
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

    private func returnToAppIfNeeded() async {
        guard mayHaveLeftAppInTurn else { return }
        mayHaveLeftAppInTurn = false
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        let executor: (any ToolExecutor)? = sandboxExecutor ?? toolExecutor
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

    private func handleAgentEvent(_ event: AgentLoopEvent) async {
        switch event {
        case .turnStarted:
            liveAnswerID = nil

        case .modelDelta(let delta):
            if liveAnswerID == nil {
                liveAnswerID = "sandbox-\(UUID().uuidString)"
            }
            eventContinuation?.yield(.partDelta(partID: liveAnswerID!, delta: delta))

        case .modelResponse(let response):
            if liveAnswerID == nil, !response.content.isEmpty {
                eventContinuation?.yield(.partUpdated(partID: UUID().uuidString, kind: "assistantText", text: response.content, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            } else if let id = liveAnswerID, !response.content.isEmpty {
                eventContinuation?.yield(.partUpdated(partID: id, kind: "assistantText", text: response.content, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            }
            liveAnswerID = nil
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    if Self.toolMayLeaveApp(call.name) {
                        mayHaveLeftAppInTurn = true
                    }
                    eventContinuation?.yield(.partUpdated(partID: call.id, kind: "tool", text: nil, tool: call.name, callID: call.id, status: "running", input: call.arguments, output: nil, error: nil))
                }
            }
            
        case .toolResult(let result):
            let state: String
            switch result.error {
            case nil: state = "completed"
            default: state = "error"
            }
            eventContinuation?.yield(.partUpdated(
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
            eventContinuation?.yield(.sessionError(error.localizedDescription))
            
        case .finished:
            if let sessionID = currentSessionIDStorage {
                eventContinuation?.yield(.sessionIdle(sessionID: sessionID))
            }
            
        default:
            break
        }
    }
}

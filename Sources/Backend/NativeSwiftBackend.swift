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
    private var liveAnswerID: String?
    private var toolExecutor: NativeCapabilityToolExecutor?
    private var boundSessionID: String?
    private var runningTask: Task<Void, Never>?
    private var permissionWaiters: [String: CheckedContinuation<PermissionResponse.Decision, Never>] = [:]
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
            guard let provider = SandboxModelProvider.provider(id: providerID),
                  let key = try await ps.loadAPIKey(provider: provider.id), !key.isEmpty else { continue }
            do {
                try await installRemoteProvider(id: provider.id, display: provider.name, key: key,
                    baseURL: provider.baseURL, preferred: provider.preferredModels, fallback: provider.fallbackModel)
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
        fallback: String
    ) async throws {
        let remote = RemoteModelProvider(id: id, name: display)
        try await remote.configure(ModelConfiguration(apiKey: key, baseURL: baseURL))
        let listed = await remote.availableModels
        let models = SandboxModelCatalog.orderedModelIDs(available: listed, preferred: preferred, fallback: fallback)
        modelProvider = remote
        activeModelName = models.contains(fallback) ? fallback : models[0]
        providerID = id
        providerDisplay = display
        providerModelIDs = models
        isDualSmolActive = false
        agentLoop = nil
        boundSessionID = nil
        connectionStatusStorage = "sandbox · \(activeModelName ?? fallback)"
    }

    /// The loop persists under the session the UI opened. A backend-wide id
    /// made `session.idle` miss the open session, so the composer never left Stop.
    private func installLoop(sessionID: String) async {
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
        let loop = AgentLoop(context: AgentContext(
            conversationId: sessionID,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            modelName: modelName,
            toolExecutor: exec,
            systemPrompt: systemPromptText(),
            maxTurns: 12,
            permissionHandler: { [weak self] request in
                guard let self else {
                    return PermissionResponse(requestId: request.id, decision: .deny)
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
        GUSMobileRole.mobile.systemPrompt
    }
    
    public func listProjects() async throws -> [Project] {
        guard let ws = workspace else { throw WorkbenchError.notConnected }
        let project = Project(
            id: "native:\(ws.rootURL.lastPathComponent)",
            name: "iOS Sandbox",
            path: ws.rootURL.path,
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
                lastEventSummary: c.lastMessagePreview ?? "No messages",
                timestamp: c.updatedAt,
                agentMode: .build,
                isRunning: false
            )
        }
    }
    
    public func createSession(projectID: String, title: String) async throws -> Session {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        let conv = Conversation(title: title.isEmpty ? "New Session" : title)
        try await ps.saveConversation(conv)
        await installLoop(sessionID: conv.id)
        eventContinuation?.yield(.sessionsChanged)
        return Session(id: conv.id, projectId: projectID, title: conv.title, lastEventSummary: "New session", timestamp: conv.updatedAt, agentMode: .build, isRunning: false)
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
        
        let sessionAtStart = sessionID
        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await loop.run(userInput: text)
            } catch is CancellationError {
                return
            } catch {
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
        guard let ws = workspace else { throw WorkbenchError.notConnected }
        let data = try await ws.readFile(at: path)
        return WorkbenchFileContent(path: path, content: String(data: data, encoding: .utf8) ?? "", mimeType: nil, encoding: "utf-8")
    }
    
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] {
        throw WorkbenchError.unsupportedFeature("Diff requires remote OpenCode server")
    }
    
    public func runShell(command: String, agent: String?) async throws -> ShellResult {
        throw WorkbenchError.unsupportedFeature("Shell requires remote OpenCode server")
    }
    
    public func availableProviders() async throws -> ProviderListResult {
        let models: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: providerModelIDs.map { ($0, [String: Any]()) })
        return ProviderListResult(
            all: [ProviderInfo(id: providerID, name: providerDisplay, models: models)],
            connected: [providerID],
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

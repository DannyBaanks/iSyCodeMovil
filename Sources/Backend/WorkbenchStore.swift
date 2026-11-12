import Foundation
import SwiftUI

/// Estado de salud de la conexion al backend (remoto SSE/HTTP o runtime local).
public enum ConnectionHealth: String, Sendable {
    case connected
    case connecting
    case disconnected
}

@MainActor
public final class WorkbenchStore: ObservableObject {
    @Published public var sessionState = ActiveSessionState()
    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var backendMode: BackendMode = .unconfigured
    @Published public private(set) var connectionStatus: String = ""
    @Published public private(set) var isConnecting: Bool = false
    @Published public private(set) var connectionHealth: ConnectionHealth = .disconnected
    /// False when the on-phone sandbox is the canned notes.txt script.
    @Published public private(set) var sandboxUsesLiveModel = false
    @Published public private(set) var gusDualSmolActive = false
    @Published public private(set) var sandboxFolderName: String? = UserDefaults.standard.string(forKey: "sandbox.authorizedFolderName")
    @Published public var sandboxFolderError: String?
    @Published public var sandboxSetupError: String?
    /// The Docker sandbox on the user's computer that the agent's tools run in, if linked.
    @Published public private(set) var sandboxLink: SandboxLinkState?
    @Published public private(set) var sandboxLinkBusy = false
    @Published public var sandboxLinkError: String?
    /// Repository cloned on this iPhone that the on-device tools are scoped to, if any.
    @Published public private(set) var phoneProject: String?
    @Published public private(set) var phoneProjectCanUndo = false
    @Published public private(set) var phoneProjectBusy = false
    @Published public var phoneProjectMessage: String?
    @Published public var availableModels: [ModelInfo] = []
    @Published public var availableAgents: [String] = []
    @Published public var availableCommands: [CommandInfo] = []
    @Published public var fileTree: [WorkbenchFileNode] = []
    @Published public private(set) var filesPath: String = ""
    @Published public var diffFiles: [SessionDiffFile] = []
    @Published public var shellHistory: [(command: String, result: ShellResult?)] = []

    /// Codex and Grok adapters deliberately do not implement rename/delete.
    public var supportsSessionManagement: Bool {
        backendMode != .remote || (activeRemoteBackendType != .codex && activeRemoteBackendType != .grok)
    }
    
    private var currentProjectID: String?
    private var currentSessionID: String?
    var currentBackend: (any WorkbenchBackend)?
    private var pairingStore = PairingStore()
    private var codexPairingStore = CodexPairingStore()
    private var grokPairingStore = GrokPairingStore()
    private var sandboxPairingStore = SandboxPairingStore()
    private var sandboxClient: SandboxHostClient?
    private var activeRemotePairing: BackendPairing?
    private var activeRemoteBackendType: RemoteBackendType?
    private var backendEventTask: Task<Void, Never>?
    private var isProcessingRemote = false
    /// part id → "assistant" | "reasoning" | "user". Deltas have no type of their own.
    private var streamPartKinds: [String: String] = [:]
    
    public init() {}

    #if targetEnvironment(simulator)
    /// Deterministic, non-personal UI data for screenshots captured by CI.
    /// Production builds and normal Simulator launches never enter this path.
    public func prepareReadmeScreenshot(_ scene: String) {
        guard ["projects", "chat"].contains(scene) else { return }
        let project = Project(
            id: "readme-project",
            name: "mi-web-app · ejemplo",
            path: "Ejemplo / mi-web-app",
            avatarColor: IysThemePreferences.active.accent,
            sessionCount: 3
        )
        let examples = [
            Session(id: "readme-session-1", projectId: project.id, title: "Crear tarjeta de producto",
                    lastEventSummary: "Componente SwiftUI y archivo nuevo", agentMode: .build),
            Session(id: "readme-session-2", projectId: project.id, title: "Revisar cambios",
                    lastEventSummary: "Comparar y aprobar edición", agentMode: .build),
            Session(id: "readme-session-3", projectId: project.id, title: "Explorar el proyecto",
                    lastEventSummary: "Archivos y estructura", agentMode: .build)
        ]
        projects = [project]
        sessions = examples
        backendMode = .native
        gusDualSmolActive = false
        connectionHealth = .connected
        connectionStatus = "Vista de ejemplo para README"
        sandboxUsesLiveModel = true
        sessionState.currentProject = scene == "projects" ? nil : project
        sessionState.currentSession = scene == "chat" ? examples[0] : nil
        sessionState.selectedModel = ModelInfo(name: "Demo visual", provider: "iSyCode", isLocal: true, route: "native")
        sessionState.activeSurface = .chat
        sessionState.clearTimeline()
        if scene == "chat" {
            sessionState.timelineEvents = [
                .userPrompt("Crea una tarjeta de producto en SwiftUI y guarda el archivo.", agentMode: .build),
                .assistantText("Preparé el componente y dejé el archivo listo para revisar.", agentMode: .build),
                .toolCall(name: "write_file", arguments: ["path": "ProductCard.swift"], state: .success, agentMode: .build),
                .codeBlock(language: "swift", content: "struct ProductCard: View {\n    var body: some View {\n        Text(\"Nuevo producto\")\n    }\n}", fileName: "ProductCard.swift", agentMode: .build),
                .assistantText("Puedes abrir Archivos para ver el resultado.", agentMode: .build)
            ]
        }
    }
    #endif
    
    public func connectRemote(_ rawPairingLink: String) async {
        // A sandbox link is not a remote agent: the agent stays on this iPhone and only
        // its tools move to the computer.
        if SandboxPairing.isPairingLink(rawPairingLink) {
            await connectSandboxHost(rawPairingLink)
            return
        }
        do {
            let (backendType, pairing) = try WorkbenchBackendFactory.parsePairingURL(rawPairingLink)
            await connectRemote(pairing: pairing, backendType: backendType)
        } catch {
            isConnecting = false
            connectionHealth = .disconnected
            backendMode = .unconfigured
            connectionStatus = "error: \(error.localizedDescription)"
        }
    }

    private func connectRemote(
        pairing: BackendPairing,
        backendType: RemoteBackendType,
        preservingSessionID: String? = nil
    ) async {
        guard !isConnecting else { return }
        backendEventTask?.cancel()
        backendEventTask = nil
        await currentBackend?.stopEventStream()
        await currentBackend?.disconnect()
        isConnecting = true
        connectionHealth = .connecting
        connectionStatus = "Conectando…"
        activeRemotePairing = pairing
        activeRemoteBackendType = backendType

        do {
            let backend = try WorkbenchBackendFactory.makeBackend(from: pairing)
            currentBackend = backend
            backendMode = .remote
            gusDualSmolActive = false
            try await backend.connectRemote(pairing: pairing)

            let host: String
            let port: Int
            let directory: String
            switch pairing {
            case .openCode(let value):
                host = value.host
                port = value.port
                directory = value.directory
            case .codex(let value):
                host = value.host
                port = value.port
                directory = value.directory
            case .grok(let value):
                host = value.host
                port = value.port
                directory = value.directory
            case .remote(let value):
                host = value.host
                port = value.port
                directory = value.directory
            }

            let project = Project(
                id: "\(backendType.rawValue):\(host):\(port)",
                name: "\(backendType.displayName) @ \(host)",
                path: directory.isEmpty ? "remote" : directory,
                avatarColor: .white,
                sessionCount: 0
            )
            projects = [project]
            currentProjectID = project.id
            sessionState.currentProject = project

            sessionState.clearTimeline()
            sessions = try await backend.listSessions(projectID: project.id)
            let sessionToRestore = preservingSessionID.flatMap { id in sessions.first(where: { $0.id == id }) } ?? sessions.first
            if let sessionToRestore {
                await selectSession(sessionToRestore)
            }

            sessionState.selectedModel = ModelInfo(
                name: "\(backendType.displayName) server default",
                provider: backendType.displayName,
                providerIcon: "terminal",
                isLocal: false,
                route: backendType.rawValue
            )

            connectionStatus = await backend.connectionStatus
            isConnecting = false
            connectionHealth = .connected
            addSystemEvent("\(backendType.displayName) connected")

            switch pairing {
            case .openCode(let value):
                try await pairingStore.save(value)
            case .codex(let value):
                try await codexPairingStore.save(value)
            case .grok(let value):
                try await grokPairingStore.save(value)
            case .remote(let value) where value.type == .opencode || value.type == .openisy:
                try await pairingStore.save(OpenCodePairing(
                    scheme: value.scheme,
                    host: value.host,
                    port: value.port,
                    username: value.username,
                    password: value.password,
                    directory: value.directory
                ))
            case .remote:
                break
            }

            await loadModelsAndAgents()
            await subscribeToBackendEvents(backend)
        } catch {
            isConnecting = false
            connectionHealth = .disconnected
            connectionStatus = "error: \(error.localizedDescription)"
            if preservingSessionID == nil {
                backendMode = .unconfigured
            }
        }
    }

    public func disconnect() async {
        backendEventTask?.cancel()
        backendEventTask = nil
        await currentBackend?.disconnect()
        currentBackend = nil
        activeRemotePairing = nil
        activeRemoteBackendType = nil
        backendMode = .unconfigured
        gusDualSmolActive = false
        connectionStatus = ""
        isConnecting = false
        connectionHealth = .disconnected
        projects = []
        sessions = []
        availableModels = []
        availableAgents = []
        availableCommands = []
        fileTree = []
        diffFiles = []
        shellHistory = []
        sessionState.currentProject = nil
        sessionState.currentSession = nil
        sessionState.clearTimeline()
        currentProjectID = nil
        currentSessionID = nil
        sandboxUsesLiveModel = false
        // The sandbox itself is left on the computer: it expires on its own clock, and
        // destroying work nobody collected is never done implicitly.
        sandboxClient = nil
        sandboxLink = nil
        sandboxLinkError = nil
    }

    @discardableResult
    public func startSandbox(xaiKey: String?) async -> Bool {
        await startSandbox(providerID: "xai", apiKey: xaiKey)
    }

    @discardableResult
    public func startSandbox(providerID: String, apiKey: String?) async -> Bool {
        sandboxSetupError = nil
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let provider = SandboxModelProvider.provider(id: providerID) else {
            sandboxSetupError = "No reconozco el proveedor seleccionado. Vuelve a elegirlo."
            return false
        }
        if provider.id == "gus-local", !trimmed.isEmpty {
            sandboxSetupError = "GUS local no acepta API keys. Elige un proveedor remoto si quieres usar una clave."
            return false
        }

        do {
            let persistence = try IOSPersistence()
            if !trimmed.isEmpty {
                try await persistence.saveAPIKey(provider: provider.id, key: trimmed)
            }
            var configuration = try await persistence.loadConfiguration() ?? Configuration()
            configuration.defaultModelProvider = provider.id
            try await persistence.saveConfiguration(configuration)
        } catch {
            sandboxSetupError = "No pude guardar la clave o la configuración: \(error.localizedDescription)"
            return false
        }

        await useNativeRuntime()
        guard backendMode == .native, connectionHealth == .connected else {
            sandboxSetupError = connectionStatus.isEmpty
                ? "No pude iniciar el sandbox. Inténtalo de nuevo."
                : connectionStatus
            return false
        }
        sandboxSetupError = nil
        return true
    }
    
    public func useNativeRuntime() async {
        await startNativeRuntime(forceOfflineDemo: false)
    }

    /// Starts the scripted demo in iSyCode's private app workspace. This path
    /// intentionally ignores a previously selected Files folder and provider keys.
    public func useNativeDemoRuntime() async {
        await startNativeRuntime(forceOfflineDemo: true)
    }

    private func startNativeRuntime(forceOfflineDemo: Bool) async {
        do {
            await currentBackend?.stopEventStream()
            await currentBackend?.disconnect()
            currentBackend = nil
            let bookmarkText: String?
            if forceOfflineDemo {
                bookmarkText = nil
            } else {
                bookmarkText = try await KeychainHelper.shared.load(key: "sandbox.authorizedFolderBookmark")
            }
            var bookmark = bookmarkText.flatMap { Data(base64Encoded: $0) }
            var expiredFolderGrant = bookmarkText != nil && bookmark == nil
            if let savedBookmark = bookmark {
                do {
                    _ = try IOSWorkspace(securityScopedBookmark: savedBookmark)
                } catch {
                    bookmark = nil
                    expiredFolderGrant = true
                }
            }
            let backend = WorkbenchBackendFactory.makeNativeBackend(
                workspaceBookmark: bookmark,
                forceOfflineDemo: forceOfflineDemo
            )
            try await backend.useNativeRuntime()
            currentBackend = backend
            backendMode = .native
            gusDualSmolActive = (backend as? NativeSwiftBackend)?.isDualSmolActive ?? false

            if expiredFolderGrant {
                try? await KeychainHelper.shared.delete(key: "sandbox.authorizedFolderBookmark")
                UserDefaults.standard.removeObject(forKey: "sandbox.authorizedFolderName")
                sandboxFolderName = nil
                sandboxFolderError = "iOS ya no permite abrir la carpeta anterior. El sandbox usa su espacio privado; puedes elegir la carpeta otra vez en Ajustes."
            }
            
            projects = try await backend.listProjects()
            if let project = projects.first {
                currentProjectID = project.id
                sessionState.currentProject = project
                sessions = try await backend.listSessions(projectID: project.id)
            }
            
            connectionStatus = await backend.connectionStatus
            if expiredFolderGrant {
                connectionStatus += " · carpeta de Archivos revocada; usando espacio privado"
            }
            connectionHealth = .connected
            sandboxSetupError = nil
            sandboxUsesLiveModel = backend.usesLiveModel
            sessionState.clearTimeline()
            if let first = sessions.first {
                await selectSession(first)
            }
            if sessionState.timelineEvents.isEmpty {
                addSystemEvent(connectionStatus)
            }
            
            await loadModelsAndAgents()
            if backendMode == .native, let model = availableModels.first {
                sessionState.selectedModel = model
            }
            await subscribeToBackendEvents(backend)
            
        } catch {
            backendMode = .unconfigured
            connectionHealth = .disconnected
            gusDualSmolActive = false
            connectionStatus = "error: \(error.localizedDescription)"
        }
    }

    /// Persists only the security-scoped bookmark returned after the user picks a folder.
    /// Models never provide or widen this root; Files remains the permission authority.
    public func authorizeSandboxFolder(_ url: URL) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.permissionDenied("iOS no concedió acceso a esta carpeta. Vuelve a elegirla desde Archivos.")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.invalidPath("Selecciona una carpeta, no un archivo.")
        }
        let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await KeychainHelper.shared.save(key: "sandbox.authorizedFolderBookmark", value: bookmark.base64EncodedString())
        UserDefaults.standard.set(url.lastPathComponent, forKey: "sandbox.authorizedFolderName")
        sandboxFolderName = url.lastPathComponent
        if backendMode == .native {
            await useNativeRuntime()
            guard connectionHealth == .connected, sandboxFolderName != nil else {
                throw WorkspaceError.permissionDenied(sandboxFolderError ?? connectionStatus)
            }
        }
    }

    public func revokeSandboxFolderAccess() async throws {
        try await KeychainHelper.shared.delete(key: "sandbox.authorizedFolderBookmark")
        UserDefaults.standard.removeObject(forKey: "sandbox.authorizedFolderName")
        sandboxFolderName = nil
        if backendMode == .native {
            await useNativeRuntime()
            guard connectionHealth == .connected else {
                throw WorkspaceError.permissionDenied(connectionStatus)
            }
        }
    }

    public func clearSandboxFolderError() {
        sandboxFolderError = nil
    }
    
    public func reconnectStoredPairing() async {
        if let pairing = activeRemotePairing, let backendType = activeRemoteBackendType {
            await connectRemote(pairing: pairing, backendType: backendType, preservingSessionID: currentSessionID)
            return
        }
        if let codex = try? await codexPairingStore.load() {
            await connectRemote(pairing: .codex(codex), backendType: .codex)
            return
        }
        if let grok = try? await grokPairingStore.load() {
            await connectRemote(pairing: .grok(grok), backendType: .grok)
            return
        }
        if let stored = try? await pairingStore.load() {
            let pairing = OpenCodePairing(
                host: stored.host,
                port: stored.port,
                username: stored.username,
                password: stored.password,
                directory: stored.directory
            )
            await connectRemote(pairing: .openCode(pairing), backendType: .opencode)
        }
    }

    /// Re-establish the remote stream after iOS has suspended the app, then
    /// reload the selected thread so messages produced while away are restored.
    public func resumeRemoteSessionAfterBackground() async {
        guard backendMode == .remote,
              let pairing = activeRemotePairing,
              let backendType = activeRemoteBackendType else { return }
        await connectRemote(pairing: pairing, backendType: backendType, preservingSessionID: currentSessionID)
    }
    
    public func reconnect() async {
        switch backendMode {
        case .remote:
            await reconnectStoredPairing()
        case .native:
            await useNativeRuntime()
        case .unconfigured:
            break
        }
    }
    
    public func forgetPairing() async {
        try? await pairingStore.clear()
        do {
            try await codexPairingStore.clear()
        } catch {
            addErrorEvent("Could not remove Codex pairing secret: \(error.localizedDescription)")
        }
        do {
            try await grokPairingStore.clear()
        } catch {
            addErrorEvent("Could not remove Grok pairing secret: \(error.localizedDescription)")
        }
    }
    
    public func hasStoredPairing() async -> Bool {
        let hasOpenCodePairing = await pairingStore.hasStoredPairing()
        let hasCodexPairing = await codexPairingStore.hasStoredPairing()
        let hasGrokPairing = await grokPairingStore.hasStoredPairing()
        return hasOpenCodePairing || hasCodexPairing || hasGrokPairing
    }
    
    public func selectProject(_ project: Project) async {
        guard backendMode != .unconfigured else { return }
        currentProjectID = project.id
        sessionState.currentProject = project
        
        if let backend = currentBackend {
            do {
                sessions = try await backend.listSessions(projectID: project.id)
                if let first = sessions.first {
                    await selectSession(first)
                } else {
                    sessionState.currentSession = nil
                    currentSessionID = nil
                    sessionState.clearTimeline()
                }
            } catch {
                addErrorEvent("Failed to load sessions: \(error.localizedDescription)")
            }
        }
    }
    
    public func selectSession(_ session: Session) async {
        guard backendMode != .unconfigured else { return }
        sessionState.currentSession = session
        currentSessionID = session.id
        streamPartKinds.removeAll()
        sessionState.clearTimeline()
        
        if let backend = currentBackend {
            do {
                try await backend.selectSession(session.id)
                let events = try await backend.loadHistory(sessionID: session.id)
                var mergedEvents = events
                for streamedEvent in sessionState.timelineEvents {
                    if let index = mergedEvents.firstIndex(where: { $0.id == streamedEvent.id }) {
                        if streamedEvent.kind == .assistantText,
                           let liveText = streamedEvent.assistantText,
                           !liveText.isEmpty {
                            mergedEvents[index].assistantText = liveText
                        }
                    } else {
                        mergedEvents.append(streamedEvent)
                    }
                }
                sessionState.timelineEvents = mergedEvents
            } catch {
                addErrorEvent("Failed to load session: \(error.localizedDescription)")
            }
        }
    }
    
    public func createNewSession(in project: Project, title: String) async -> Session? {
        guard let backend = currentBackend else { return nil }
        do {
            let session = try await backend.createSession(projectID: project.id, title: title.isEmpty ? "Nueva sesión" : title)
            sessions.append(session)
            sessionState.currentSession = session
            currentSessionID = session.id
            sessionState.clearTimeline()
            try? await backend.selectSession(session.id)
            return session
        } catch {
            addErrorEvent("Failed to create session: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func renameSession(_ session: Session, title: String) async {
        guard let backend = currentBackend else { return }
        do {
            try await backend.renameSession(sessionID: session.id, title: title)
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = Session(id: session.id, projectId: session.projectId, title: title, lastEventSummary: session.lastEventSummary, timestamp: session.timestamp, agentMode: session.agentMode, isRunning: session.isRunning)
            }
            if sessionState.currentSession?.id == session.id {
                sessionState.currentSession = sessions.first { $0.id == session.id }
            }
        } catch {
            addErrorEvent("Failed to rename session: \(error.localizedDescription)")
        }
    }
    
    public func deleteSession(_ session: Session) async {
        guard let backend = currentBackend else { return }
        do {
            try await backend.deleteSession(sessionID: session.id)
            sessions.removeAll { $0.id == session.id }
            if sessionState.currentSession?.id == session.id {
                sessionState.currentSession = sessions.first
                currentSessionID = sessions.first?.id
            }
        } catch {
            addErrorEvent("Failed to delete session: \(error.localizedDescription)")
        }
    }
    
    public func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionState.isProcessing else { return }
        
        let attachments = sessionState.composerAttachments
        let userEvent = TimelineEvent.userPrompt(
            trimmed,
            attachments: attachments,
            agentMode: sessionState.agentMode
        )
        sessionState.addEvent(userEvent)
        sessionState.composerAttachments.removeAll()
        
        guard let backend = currentBackend else {
            addErrorEvent("No backend available")
            return
        }
        
        if backendMode == .remote {
            isProcessingRemote = true
        }
        sessionState.isProcessing = true
        
        let agent = sessionState.agentMode.rawValue.lowercased()
        let model = sessionState.selectedModel
        
        Task { [weak self] in
            guard let self else { return }
            do {
                let promptText = attachments.isEmpty
                    ? trimmed
                    : trimmed + "\n" + attachments.map { attachment in
                        if let path = attachment.path, !path.isEmpty {
                            return "@\(path)"
                        }
                        return "@\(attachment.name)"
                    }.joined(separator: " ")
                try await backend.sendPrompt(promptText, agent: agent, model: model)
            } catch is CancellationError {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    self.isProcessingRemote = false
                    self.addSystemEvent("Stopped")
                }
            } catch {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    self.isProcessingRemote = false
                    self.addErrorEvent("Prompt failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func cancelCurrentRun() {
        guard sessionState.isProcessing else { return }
        
        if backendMode == .remote {
            isProcessingRemote = false
            let sessionID = currentSessionID
            let backend = currentBackend
            Task { [weak self] in
                if let sessionID, let backend {
                    try? await backend.abort()
                }
                await MainActor.run { [weak self] in
                    self?.sessionState.isProcessing = false
                    self?.addSystemEvent("Stopped")
                }
            }
            return
        }
        
        Task { [weak self] in
            try? await self?.currentBackend?.abort()
            await MainActor.run { [weak self] in
                self?.sessionState.isProcessing = false
                self?.addSystemEvent("Stopped")
            }
        }
    }
    
    public func respondToPermission(requestId: String, decision: PermissionResponse.Decision) {
        guard let backend = currentBackend else {
            addErrorEvent("No backend available for permission")
            return
        }
        
        Task { [weak self] in
            do {
                try await backend.replyPermission(requestID: requestId, decision: decision)
                await MainActor.run { [weak self] in
                    if self?.sessionState.pendingPermission?.permissionRequestId == requestId {
                        self?.sessionState.pendingPermission = nil
                    }
                    self?.addSystemEvent("Permission \(decision.rawValue)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.addErrorEvent("Permission reply failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func setModel(_ model: ModelInfo) {
        sessionState.selectedModel = model
        addSystemEvent("Model: \(model.name)")
    }
    
    public func setAgentMode(_ mode: AgentMode) {
        sessionState.agentMode = mode
        addSystemEvent("Agent mode: \(mode.rawValue)")
    }
    
    public func loadFiles(path: String = "") async {
        guard let backend = currentBackend else { return }
        do {
            fileTree = try await backend.listFiles(path: path)
            filesPath = path
        } catch {
            addErrorEvent("Failed to load files: \(error.localizedDescription)")
        }
    }
    
    public func loadFileContent(path: String) async -> WorkbenchFileContent? {
        guard let backend = currentBackend else { return nil }
        do {
            return try await backend.fileContent(path: path)
        } catch {
            addErrorEvent("Failed to load file: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func loadDiff(sessionID: String) async {
        guard let backend = currentBackend else { return }
        do {
            diffFiles = try await backend.sessionDiff(sessionID: sessionID)
        } catch {
            if backendMode != .native {
                addErrorEvent("Failed to load diff: \(error.localizedDescription)")
            }
        }
    }
    
    public func runShellCommand(_ command: String, agent: String?) async {
        guard let backend = currentBackend else { return }
        do {
            let result = try await backend.runShell(command: command, agent: agent)
            shellHistory.append((command, result))
            for text in result.textParts {
                addSystemEvent(text)
            }
            if let error = result.error {
                addErrorEvent("Shell error: \(error)")
            }
        } catch {
            shellHistory.append((command, ShellResult(
                sessionID: currentSessionID ?? "",
                messageID: "",
                parts: [RemotePart(
                    id: UUID().uuidString,
                    messageID: nil,
                    kind: .tool,
                    text: nil,
                    tool: nil,
                    callID: nil,
                    status: "error",
                    input: [:],
                    output: nil,
                    error: error.localizedDescription
                )]
            )))
        }
    }
    
    public func loadModelsAndAgents() async {
        guard let backend = currentBackend else { return }
        do {
            let providers = try await backend.availableProviders()
            var models: [ModelInfo] = []
            for provider in providers.all {
                if let providerModels = provider.models {
                    for (modelID, _) in providerModels {
                        models.append(ModelInfo(
                            name: providerModels[modelID]?["displayName"] as? String ?? "\(provider.name) / \(modelID)",
                            provider: provider.name,
                            providerIcon: "cpu",
                            isLocal: false,
                            apiModelId: modelID,
                            route: provider.id
                        ))
                    }
                }
            }
            if models.isEmpty {
                if backend is CodexRemoteBackend {
                    models.append(ModelInfo(name: "Codex server default", provider: "Codex", providerIcon: "terminal", isLocal: false, route: "codex"))
                } else if backend is GrokRemoteBackend {
                    models.append(ModelInfo(name: "Grok en tu computadora", provider: "Grok", providerIcon: "terminal", isLocal: false, route: "grok"))
                } else {
                    models.append(ModelInfo(name: "OpenCode server default", provider: "OpenCode", providerIcon: "terminal", isLocal: false, route: "opencode-server"))
                }
            }
            availableModels = models

            if backend is CodexRemoteBackend || backend is GrokRemoteBackend {
                availableAgents = []
                availableCommands = []
                return
            }
            
            let cfg = try await backend.config()
            if let agents = cfg.agents {
                availableAgents = Array(agents.keys).sorted()
            } else {
                availableAgents = ["build", "plan", "explore", "review", "custom"]
            }
            
            let cmds = try await backend.availableCommands()
            availableCommands = cmds
            
        } catch {
            if backend is CodexRemoteBackend {
                let defaultModel = ModelInfo(
                    name: "Codex server default",
                    provider: "Codex",
                    providerIcon: "terminal",
                    isLocal: false,
                    route: "codex"
                )
                availableModels = [defaultModel]
                if sessionState.selectedModel == nil {
                    sessionState.selectedModel = defaultModel
                }
            } else if backend is GrokRemoteBackend {
                let defaultModel = ModelInfo(
                    name: "Grok en tu computadora",
                    provider: "Grok",
                    providerIcon: "terminal",
                    isLocal: false,
                    route: "grok"
                )
                availableModels = [defaultModel]
                if sessionState.selectedModel == nil {
                    sessionState.selectedModel = defaultModel
                }
            }
            addErrorEvent("Failed to load models/agents: \(error.localizedDescription)")
        }
    }
    
    private func subscribeToBackendEvents(_ backend: any WorkbenchBackend) async {
        backendEventTask?.cancel()
        backendEventTask = Task { [weak self] in
            for await event in backend.eventStream {
                guard !Task.isCancelled else { break }
                await self?.handleBackendEvent(event)
            }
        }
    }
    
    private func handleBackendEvent(_ event: WorkbenchEvent) async {
        switch event {
        case .connected:
            sessionState.isProcessing = false
            isProcessingRemote = false
            connectionHealth = .connected
            addSystemEvent("Connected")
            
        case .disconnected(let reason):
            sessionState.isProcessing = false
            isProcessingRemote = false
            connectionHealth = .disconnected
            if let reason { addSystemEvent("Disconnected: \(reason)") }
            
        case .partUpdated(let partID, let kind, let text, let tool, let callID, let status, let input, let output, let error):
            handlePartUpdate(partID: partID, kind: kind, text: text, tool: tool, callID: callID, status: status, input: input, output: output, error: error)

        case .partDelta(let partID, let delta):
            appendAssistantDelta(partID: partID, delta: delta)
            
        case .permissionAsked(let requestID, let sessionID, let tool, let command, let explanation):
            if sessionID == currentSessionID {
                sessionState.pendingPermission = TimelineEvent.permission(
                    requestId: requestID,
                    tool: tool,
                    command: command,
                    explanation: explanation,
                    scope: tool.hasPrefix("Codex") ? "Codex · para esta sesión" : (backendMode == .remote ? "remote workspace" : "sandbox"),
                    agentMode: sessionState.agentMode
                )
            }
            
        case .sessionIdle(let sessionID):
            if sessionID == currentSessionID {
                sessionState.isProcessing = false
                isProcessingRemote = false
                addSuccessEvent("Done")
            }
            
        case .sessionError(let message):
            sessionState.isProcessing = false
            isProcessingRemote = false
            addErrorEvent(message)
            
        case .sessionsChanged:
            if let projectID = currentProjectID, let backend = currentBackend {
                sessions = (try? await backend.listSessions(projectID: projectID)) ?? []
            }
            
        case .agentModeChanged(let mode):
            sessionState.agentMode = mode
            
        case .modelChanged(let model):
            if let model { sessionState.selectedModel = model }

        case .auxiliaryModelStatus(let status):
            addSystemEvent(status.rawValue)
            
        case .filesChanged:
            await loadFiles()
            
        default:
            break
        }
    }
    
    private func handlePartUpdate(partID: String, kind: String, text: String?, tool: String?, callID: String?, status: String?, input: [String: String], output: String?, error: String?) {
        let eventID = callID ?? partID
        
        if kind == "assistantText" || kind == "text" {
            streamPartKinds[eventID] = "assistant"
            let body = text ?? ""
            if body.isEmpty {
                upsertAssistantText(id: eventID, text: "")
                return
            }
            if kind == "text", isEchoOfLatestUserPrompt(body) {
                removeTimelineEvent(id: eventID)
                return
            }
            upsertAssistantText(id: eventID, text: body)
        } else if kind == "tool" {
            let state: ToolCallState
            switch status {
            case "completed": state = .success
            case "error": state = .failed
            default: state = .running
            }
            if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == eventID }) {
                sessionState.updateToolCall(id: eventID, state: state, output: output ?? error, duration: nil)
            } else {
                let toolName = tool ?? "tool"
                let event = TimelineEvent.toolCall(id: eventID, name: toolName, arguments: input, state: state, agentMode: sessionState.agentMode)
                sessionState.addEvent(event)
                if let output = output ?? error {
                    sessionState.updateToolCall(id: eventID, state: state, output: output, duration: nil)
                }
            }
        } else if kind == "reasoning" {
            streamPartKinds[eventID] = "reasoning"
            upsertThinking(id: eventID)
        } else if kind == "userPrompt", let text = text, !text.isEmpty {
            streamPartKinds[eventID] = "user"
            if isEchoOfLatestUserPrompt(text) {
                removeTimelineEvent(id: eventID)
                return
            }
            upsertUserPrompt(id: eventID, text: text)
        } else if kind == "system", let text = text {
            upsertSystem(id: eventID, text: text)
        }
    }
    
    private func isEchoOfLatestUserPrompt(_ text: String) -> Bool {
        guard let prompt = sessionState.timelineEvents.last(where: { $0.kind == .userPrompt })?.promptText else {
            return false
        }
        return prompt == text || prompt.hasPrefix(text)
    }
    
    private func removeTimelineEvent(id: String) {
        sessionState.timelineEvents.removeAll { $0.id == id }
    }
    
    private func appendAssistantDelta(partID: String, delta: String) {
        switch streamPartKinds[partID] {
        case "reasoning", "user":
            return
        default:
            break
        }
        if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == partID }) {
            guard sessionState.timelineEvents[index].kind == .assistantText else { return }
            let current = sessionState.timelineEvents[index].assistantText ?? ""
            sessionState.timelineEvents[index].assistantText = current + delta
            return
        }
        streamPartKinds[partID] = "assistant"
        upsertAssistantText(id: partID, text: delta)
    }
    
    private func upsertAssistantText(id: String, text: String) {
        if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == id }) {
            sessionState.timelineEvents[index].assistantText = text
            return
        }
        var event = TimelineEvent(id: id, kind: .assistantText, agentMode: sessionState.agentMode)
        event.assistantText = text
        sessionState.addEvent(event)
    }
    
    private func upsertUserPrompt(id: String, text: String) {
        if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == id }) {
            sessionState.timelineEvents[index].promptText = text
            return
        }
        var event = TimelineEvent(id: id, kind: .userPrompt, agentMode: sessionState.agentMode)
        event.promptText = text
        sessionState.addEvent(event)
    }
    
    private func upsertThinking(id: String) {
        if sessionState.timelineEvents.contains(where: { $0.id == id }) { return }
        var event = TimelineEvent(id: id, kind: .thinking, agentMode: sessionState.agentMode)
        event.statusLabel = "Thinking"
        sessionState.addEvent(event)
    }
    
    private func upsertSystem(id: String, text: String) {
        if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == id }) {
            sessionState.timelineEvents[index].assistantText = text
            return
        }
        var event = TimelineEvent(id: id, kind: .system)
        event.assistantText = text
        sessionState.addEvent(event)
    }
    
    private func addSystemEvent(_ text: String) {
        let event = TimelineEvent.system(text)
        sessionState.addEvent(event)
    }
    
    private func addErrorEvent(_ text: String) {
        sessionState.addEvent(TimelineEvent.system("Error: \(text)"))
    }
    
    private func addSuccessEvent(_ text: String) {
        sessionState.addEvent(TimelineEvent.system(text))
    }
    
    public func addAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.append(attachment)
    }
    
    public func removeAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.removeAll { $0.id == attachment.id }
    }
    
    public func saveAPIKeys(xai: String, openAI: String) async {
        await saveAPIKeys(values: ["xai": xai, "openai": openAI], selectedProviderID: "xai")
    }

    public func saveAPIKeys(values: [String: String], selectedProviderID: String) async {
        guard let backend = currentBackend as? NativeSwiftBackend else {
            addErrorEvent("Start the sandbox before saving a key.")
            return
        }
        do {
            guard let persistence = backend.persistence,
                  SandboxModelProvider.provider(id: selectedProviderID) != nil else {
                throw ModelProviderError.invalidRequest("Unknown sandbox provider")
            }
            for (providerID, value) in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { try await persistence.saveAPIKey(provider: providerID, key: trimmed) }
            }
            var configuration = try await persistence.loadConfiguration() ?? Configuration()
            configuration.defaultModelProvider = selectedProviderID
            try await persistence.saveConfiguration(configuration)
            try await backend.reloadSandboxModel()
            connectionStatus = await backend.connectionStatus
            sandboxUsesLiveModel = backend.usesLiveModel
            await loadModelsAndAgents()
            if let model = availableModels.first {
                sessionState.selectedModel = model
            }
            addSystemEvent(connectionStatus)
        } catch {
            addErrorEvent("Could not save the API key: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func setDualSmolEnabled(_ enabled: Bool) async -> Bool {
        let manager = GUSModelDownloadManager.shared
        if enabled {
            await manager.refresh()
            guard manager.modelURL(id: GUSModelManifest.qwen25Q4KM.id) != nil,
                  manager.modelURL(id: GUSModelManifest.smolLM2Q4KM.id) != nil else {
                addErrorEvent("Descarga y verifica Qwen2.5-0.5B y SmolLM2-360M antes de activar Dual-Smol.")
                return false
            }
        }

        let previous = GUSDualModelExperimentSettings.isEnabled
        GUSDualModelExperimentSettings.setEnabled(enabled)
        guard let backend = currentBackend as? NativeSwiftBackend else {
            gusDualSmolActive = false
            return true
        }

        do {
            try await backend.reloadSandboxModel()
            if enabled && !backend.isDualSmolActive {
                GUSDualModelExperimentSettings.setEnabled(false)
                try? await backend.reloadSandboxModel()
                gusDualSmolActive = backend.isDualSmolActive
                connectionStatus = await backend.connectionStatus
                addErrorEvent("No se pudo cargar la pareja Dual-Smol. GUS continúa con el modelo seleccionado.")
                return false
            }
            gusDualSmolActive = backend.isDualSmolActive
            connectionStatus = await backend.connectionStatus
            sandboxUsesLiveModel = backend.usesLiveModel
            await loadModelsAndAgents()
            if let model = availableModels.first { sessionState.selectedModel = model }
            if !enabled { addSystemEvent(GUSDualModelStatus.disabled.rawValue) }
            return true
        } catch {
            GUSDualModelExperimentSettings.setEnabled(previous)
            try? await backend.reloadSandboxModel()
            gusDualSmolActive = backend.isDualSmolActive
            connectionStatus = await backend.connectionStatus
            sandboxUsesLiveModel = backend.usesLiveModel
            addErrorEvent("No pude aplicar Dual-Smol: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Docker sandbox on the user's computer

extension WorkbenchStore {
    /// Links the on-phone agent to a sandbox on the computer.
    ///
    /// The sandbox is prepared first, so a bad link or a stopped Docker leaves the app on
    /// the connection screen with the reason instead of inside a half-working session.
    public func connectSandboxHost(_ rawPairingLink: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionHealth = .connecting
        connectionStatus = "Preparando el sandbox en tu computadora…"
        sandboxLinkError = nil
        do {
            let pairing = try SandboxPairing.parse(rawPairingLink)
            let client = SandboxHostClient(pairing: pairing)
            let info = try await client.bridgeInfo()
            let prepared = try await prepareSandbox(client: client, info: info)
            try await sandboxPairingStore.save(pairing)

            isConnecting = false
            await startNativeRuntime(forceOfflineDemo: false)
            guard backendMode == .native, connectionHealth == .connected,
                  let backend = currentBackend as? NativeSwiftBackend else { return }

            backend.attachSandbox(
                SandboxToolExecutor(client: client, sandboxID: prepared.status.id, info: info),
                projectName: info.projectName,
                projectPath: pairing.directory
            )
            sandboxClient = client
            sandboxLink = SandboxLinkState(
                projectName: info.projectName,
                directory: pairing.directory,
                repo: info.repo,
                defaultBranch: info.defaultBranch,
                hasGitHubAccount: info.hasGitHubAccount,
                sandboxID: prepared.status.id,
                phase: prepared.status.phase,
                remainingMs: prepared.status.remainingMs,
                explanation: prepared.status.explanation,
                excludedFiles: prepared.excluded,
                lastPullRequest: nil
            )
            await refreshProjectsAfterSandboxChange(backend)
            fileTree = []
            connectionStatus = "Sandbox en tu computadora · \(info.projectName)"
            addSystemEvent(prepared.reused
                ? "Sandbox retomado en tu computadora: \(info.projectName). Las herramientas del agente se ejecutan allí."
                : "Sandbox nuevo en tu computadora con una copia de \(info.projectName). Sin red, sin acceso a tu disco y sin credenciales.")
            if !prepared.excluded.isEmpty {
                addSystemEvent("Se quedaron en tu computadora \(prepared.excluded.count) archivos que parecen secretos.")
            }
            if !sandboxUsesLiveModel {
                addSystemEvent("Falta un modelo: elige un proveedor en Ajustes para que el agente pueda trabajar en el sandbox.")
            }
        } catch {
            isConnecting = false
            sandboxClient = nil
            sandboxLink = nil
            if backendMode != .native {
                connectionHealth = .disconnected
                backendMode = .unconfigured
            }
            connectionStatus = "error: \(error.localizedDescription)"
        }
    }

    private func prepareSandbox(client: SandboxHostClient, info: SandboxBridgeInfo) async throws -> (status: SandboxStatus, reused: Bool, excluded: [String]) {
        // A sandbox that is still alive holds work in progress: pick it up instead of
        // starting over with a fresh copy of the folder.
        if let existing = try await client.listSandboxes().first(where: { $0.isUsable }) {
            try await client.touch(id: existing.id)
            let status = try await client.status(id: existing.id)
            return (status: status, reused: true, excluded: [])
        }
        let id = try await client.createSandbox(ttlMinutes: 120, repo: info.repo)
        let report = try await client.sendProjectFolder(id: id)
        let status = try await client.status(id: id)
        return (status: status, reused: false, excluded: report.excluded)
    }

    private func refreshProjectsAfterSandboxChange(_ backend: NativeSwiftBackend) async {
        guard let refreshed = try? await backend.listProjects() else { return }
        projects = refreshed
        if let project = refreshed.first {
            sessionState.currentProject = project
        }
    }

    public func refreshSandboxStatus() async {
        guard let client = sandboxClient, var link = sandboxLink else { return }
        do {
            let status = try await client.status(id: link.sandboxID)
            link.phase = status.phase
            link.remainingMs = status.remainingMs
            link.explanation = status.explanation
            sandboxLink = link
        } catch {
            sandboxLinkError = error.localizedDescription
        }
    }

    /// Asks the computer to push the sandbox's work to a `movilclaw/<task>` branch and
    /// open a pull request. Called from an explicit button, so the tap is the approval.
    @discardableResult
    public func openSandboxPullRequest(title: String, body: String) async -> SandboxPullRequest? {
        guard let client = sandboxClient, var link = sandboxLink, !sandboxLinkBusy else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        sandboxLinkBusy = true
        sandboxLinkError = nil
        defer { sandboxLinkBusy = false }
        do {
            let pullRequest = try await client.openPullRequest(
                id: link.sandboxID,
                task: trimmedTitle,
                title: trimmedTitle,
                body: body,
                baseBranch: link.defaultBranch
            )
            link.lastPullRequest = pullRequest
            sandboxLink = link
            addSystemEvent("Pull request abierto: \(pullRequest.url)")
            return pullRequest
        } catch {
            sandboxLinkError = error.localizedDescription
            return nil
        }
    }

    /// Downloads the sandbox's working tree to a temporary `.tar.gz` for the share sheet.
    public func exportSandboxWork() async -> URL? {
        guard let client = sandboxClient, let link = sandboxLink, !sandboxLinkBusy else { return nil }
        sandboxLinkBusy = true
        sandboxLinkError = nil
        defer { sandboxLinkBusy = false }
        do {
            let archive = try await client.downloadWork(id: link.sandboxID)
            let safeName = link.projectName.replacingOccurrences(of: "/", with: "-")
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-sandbox.tar.gz")
            try archive.write(to: target, options: .atomic)
            return target
        } catch {
            sandboxLinkError = error.localizedDescription
            return nil
        }
    }

    /// Destroys the current sandbox and starts a new one from the folder as it is now.
    public func restartSandbox() async {
        guard let client = sandboxClient, let link = sandboxLink, !sandboxLinkBusy,
              let backend = currentBackend as? NativeSwiftBackend else { return }
        sandboxLinkBusy = true
        sandboxLinkError = nil
        defer { sandboxLinkBusy = false }
        do {
            try await client.destroy(id: link.sandboxID)
            let info = try await client.bridgeInfo()
            let prepared = try await prepareSandbox(client: client, info: info)
            backend.attachSandbox(
                SandboxToolExecutor(client: client, sandboxID: prepared.status.id, info: info),
                projectName: info.projectName,
                projectPath: link.directory
            )
            sandboxLink = SandboxLinkState(
                projectName: info.projectName,
                directory: link.directory,
                repo: info.repo,
                defaultBranch: info.defaultBranch,
                hasGitHubAccount: info.hasGitHubAccount,
                sandboxID: prepared.status.id,
                phase: prepared.status.phase,
                remainingMs: prepared.status.remainingMs,
                explanation: prepared.status.explanation,
                excludedFiles: prepared.excluded,
                lastPullRequest: nil
            )
            fileTree = []
            addSystemEvent("Sandbox reiniciado con una copia nueva de \(info.projectName).")
        } catch {
            sandboxLinkError = error.localizedDescription
        }
    }

    /// Stops using the sandbox and goes back to the iPhone workspace tools. The sandbox
    /// stays on the computer until it expires or the link is stopped there.
    public func unlinkSandbox() async {
        guard sandboxLink != nil else { return }
        if let backend = currentBackend as? NativeSwiftBackend {
            backend.detachSandbox()
            await refreshProjectsAfterSandboxChange(backend)
        }
        try? await sandboxPairingStore.clear()
        sandboxClient = nil
        sandboxLink = nil
        sandboxLinkError = nil
        fileTree = []
        connectionStatus = await currentBackend?.connectionStatus ?? ""
        addSystemEvent("Sandbox desvinculado. El agente vuelve a trabajar con los archivos de este iPhone.")
    }

    /// The open conversation as Markdown, for the share sheet.
    public func conversationMarkdown() -> String {
        ConversationExport.markdown(
            title: sessionState.currentSession?.title ?? "Conversación",
            project: sessionState.currentProject?.name,
            events: sessionState.timelineEvents
        )
    }
}

// MARK: - Disposable clones on the iPhone

extension WorkbenchStore {
    public func refreshPhoneProject() async {
        guard let backend = currentBackend as? NativeSwiftBackend else {
            phoneProject = nil
            phoneProjectCanUndo = false
            return
        }
        phoneProject = await backend.activePhoneProject()
        phoneProjectCanUndo = await backend.canUndoPhoneProjectChange()
    }

    /// Clones a public GitHub repository into the iPhone workspace without git.
    @discardableResult
    public func clonePhoneRepository(_ repository: String) async -> Bool {
        guard let backend = currentBackend as? NativeSwiftBackend, !phoneProjectBusy else { return false }
        phoneProjectBusy = true
        phoneProjectMessage = nil
        defer { phoneProjectBusy = false }
        do {
            let report = try await backend.cloneRepository(repository)
            phoneProjectMessage = "Clonado \(report.repository): \(report.files) archivos en \(report.directory)."
            addSystemEvent("Repositorio \(report.repository) clonado en este iPhone (\(report.files) archivos). Es una copia desechable.")
            fileTree = []
            await refreshPhoneProject()
            return true
        } catch {
            phoneProjectMessage = error.localizedDescription
            return false
        }
    }

    public func undoPhoneProjectChange() async {
        guard let backend = currentBackend as? NativeSwiftBackend, !phoneProjectBusy else { return }
        phoneProjectBusy = true
        defer { phoneProjectBusy = false }
        do {
            phoneProjectMessage = try await backend.undoPhoneProjectChange()
        } catch {
            phoneProjectMessage = error.localizedDescription
        }
        await refreshPhoneProject()
    }

    /// Stops scoping the tools to the clone. Its files stay in the workspace.
    public func closePhoneProject() async {
        guard let backend = currentBackend as? NativeSwiftBackend else { return }
        await backend.closeActivePhoneProject()
        phoneProjectMessage = nil
        await refreshPhoneProject()
    }
}

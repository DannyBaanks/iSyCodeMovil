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
    /// Conversations with a turn in progress (or waiting for the on-device model). Several
    /// can run at once; `sessionState.isProcessing` mirrors only the one on screen.
    @Published public private(set) var runningSessionIDs: Set<String> = []
    @Published public private(set) var backendMode: BackendMode = .unconfigured
    @Published public private(set) var connectionStatus: String = ""
    /// Enlace recibido o pegado, a la espera de que la persona confirme el equipo.
    @Published public var offeredPairingLink: String?
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
    /// Who drives the iPhone for the agent: nil = automatic, `.computer` = through the computer's
    /// bridge, `.thisPhone` = WebDriverAgent on this phone (127.0.0.1:8100). Persisted.
    @Published public private(set) var iphoneControlPreference: IphoneControlMode? =
        UserDefaults.standard.string(forKey: WorkbenchStore.iphoneControlPreferenceKey).flatMap(IphoneControlMode.init(rawValue:))
    /// The mode actually in use after resolving the preference against what is reachable; nil = no control.
    @Published public private(set) var iphoneControlActive: IphoneControlMode?
    nonisolated static let iphoneControlPreferenceKey = "iphone.controlPreference"
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
    @Published public private(set) var configuredProviderID: String?
    @Published public private(set) var configuredModelName: String?
    @Published public private(set) var hasSavedSelectedProviderKey = false
    @Published public private(set) var hasInstalledLocalModel = false
    @Published public private(set) var lastVerifiedAt: Date?
    @Published public private(set) var isRestoringRuntime = false
    @Published public private(set) var lastRuntimeError: String?
    @Published public private(set) var isRefreshingSessions = false
    @Published public private(set) var activeSequenceScope: SequenceApprovalScope?
    @Published public var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: RuntimeIntentDefaults.onboardingCompletedKey) {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: RuntimeIntentDefaults.onboardingCompletedKey)
            // Ask for notifications at a calm moment (leaving the welcome screen), not on the
            // first send: that system alert landed mid-turn and twice left WebDriverAgent stuck.
            if hasCompletedOnboarding, !oldValue {
                Task { await PermissionNotifier.shared.prepare() }
            }
        }
    }
    @Published public private(set) var lastSessionTitle: String? = UserDefaults.standard.string(forKey: RuntimeIntentDefaults.lastSessionTitleKey)
    @Published public private(set) var lastProjectName: String? = UserDefaults.standard.string(forKey: RuntimeIntentDefaults.lastProjectNameKey)

    public var runtimeSnapshot: RuntimeSelectionSnapshot {
        RuntimeSelectionEvaluator.evaluate(
            backendMode: backendMode,
            connectionHealth: connectionHealth,
            connectionStatus: connectionStatus,
            configuredProviderID: configuredProviderID,
            configuredModelName: configuredModelName,
            selectedModel: sessionState.selectedModel,
            hasSavedAPIKey: hasSavedSelectedProviderKey,
            hasInstalledLocalModel: hasInstalledLocalModel,
            sandboxUsesLiveModel: sandboxUsesLiveModel,
            isChecking: isRestoringRuntime || isConnecting,
            lastError: lastRuntimeError ?? sandboxSetupError,
            lastVerifiedAt: lastVerifiedAt
        )
    }

    public var activeRemoteProviderDisplayName: String? {
        activeRemoteBackendType?.displayName
    }

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
            lastVerifiedAt = Date()
            lastRuntimeError = nil
            hasCompletedOnboarding = true
            UserDefaults.standard.set("remote", forKey: RuntimeIntentDefaults.lastRuntimeModeKey)
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
        iphoneControlActive = nil
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
            let err = connectionStatus.isEmpty
                ? "No pude iniciar el sandbox. Inténtalo de nuevo."
                : connectionStatus
            sandboxSetupError = err
            lastRuntimeError = err
            await refreshRuntimeIntent()
            return false
        }
        sandboxSetupError = nil
        lastRuntimeError = nil
        lastVerifiedAt = Date()
        hasCompletedOnboarding = true
        UserDefaults.standard.set("native", forKey: RuntimeIntentDefaults.lastRuntimeModeKey)
        await refreshRuntimeIntent()
        return true
    }
    
    public func useNativeRuntime() async {
        await startNativeRuntime(forceOfflineDemo: false)
    }

    /// Starts the scripted demo in iSyCode's private app workspace. This path
    /// intentionally ignores a previously selected Files folder and provider keys.
    public func useNativeDemoRuntime() async {
        hasCompletedOnboarding = true
        UserDefaults.standard.set("demo", forKey: RuntimeIntentDefaults.lastRuntimeModeKey)
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
            let savedProjectID = UserDefaults.standard.string(forKey: RuntimeIntentDefaults.lastProjectIDKey)
            if let project = projects.first(where: { $0.id == savedProjectID }) ?? projects.first {
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
            lastRuntimeError = nil
            lastVerifiedAt = Date()
            hasCompletedOnboarding = true
            sandboxUsesLiveModel = backend.usesLiveModel
            sessionState.clearTimeline()
            let savedSessionID = UserDefaults.standard.string(forKey: RuntimeIntentDefaults.lastSessionIDKey)
            if let targetSession = sessions.first(where: { $0.id == savedSessionID }) ?? sessions.first {
                await selectSession(targetSession)
            }
            if sessionState.timelineEvents.isEmpty {
                addSystemEvent(connectionStatus)
            }
            
            await loadModelsAndAgents()
            if backendMode == .native {
                let preferredModelID = (backend as? NativeSwiftBackend)?.currentModelName
                if let preferredModelID,
                   let match = availableModels.first(where: { $0.apiModelId == preferredModelID || $0.name == preferredModelID }) {
                    sessionState.selectedModel = match
                } else if let model = availableModels.first {
                    sessionState.selectedModel = model
                }
            }
            await refreshRuntimeIntent()
            await subscribeToBackendEvents(backend)
            
        } catch {
            backendMode = .unconfigured
            connectionHealth = .disconnected
            gusDualSmolActive = false
            lastRuntimeError = error.localizedDescription
            connectionStatus = "error: \(error.localizedDescription)"
            await refreshRuntimeIntent()
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
            addErrorEvent("No pude borrar el token de Codex: \(error.localizedDescription)")
        }
        do {
            try await grokPairingStore.clear()
        } catch {
            addErrorEvent("No pude borrar el token de Grok: \(error.localizedDescription)")
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
        lastProjectName = project.name
        UserDefaults.standard.set(project.id, forKey: RuntimeIntentDefaults.lastProjectIDKey)
        UserDefaults.standard.set(project.name, forKey: RuntimeIntentDefaults.lastProjectNameKey)
        
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
                addErrorEvent("No pude cargar las conversaciones: \(error.localizedDescription)")
            }
        }
    }
    
    public func selectSession(_ session: Session) async {
        guard backendMode != .unconfigured else { return }
        sessionState.currentSession = session
        currentSessionID = session.id
        lastSessionTitle = session.title
        UserDefaults.standard.set(session.id, forKey: RuntimeIntentDefaults.lastSessionIDKey)
        UserDefaults.standard.set(session.title, forKey: RuntimeIntentDefaults.lastSessionTitleKey)
        if let project = sessionState.currentProject {
            lastProjectName = project.name
            UserDefaults.standard.set(project.id, forKey: RuntimeIntentDefaults.lastProjectIDKey)
            UserDefaults.standard.set(project.name, forKey: RuntimeIntentDefaults.lastProjectNameKey)
        }
        streamPartKinds.removeAll()
        sessionState.clearTimeline()
        // Another conversation may still be working: the composer shows Stop only when
        // the one being opened is busy, and the previous one's question stays with it
        // (the backend asks again when that conversation is reopened).
        sessionState.isProcessing = runningSessionIDs.contains(session.id)
        if backendMode == .native {
            sessionState.pendingPermission = nil
        }

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
                addErrorEvent("No pude abrir la conversación: \(error.localizedDescription)")
            }
        }
    }
    
    public func createNewSession(in project: Project, title: String) async -> Session? {
        guard let backend = currentBackend else { return nil }
        do {
            let session = try await backend.createSession(projectID: project.id, title: title.isEmpty ? "Nueva conversación" : title)
            sessions.append(session)
            sessionState.currentSession = session
            currentSessionID = session.id
            lastSessionTitle = session.title
            lastProjectName = project.name
            UserDefaults.standard.set(session.id, forKey: RuntimeIntentDefaults.lastSessionIDKey)
            UserDefaults.standard.set(session.title, forKey: RuntimeIntentDefaults.lastSessionTitleKey)
            UserDefaults.standard.set(project.id, forKey: RuntimeIntentDefaults.lastProjectIDKey)
            UserDefaults.standard.set(project.name, forKey: RuntimeIntentDefaults.lastProjectNameKey)
            sessionState.clearTimeline()
            // A new conversation starts free even while another one keeps working: it used
            // to inherit isProcessing, so the composer stayed on Stop and nothing could be sent.
            sessionState.isProcessing = false
            if backendMode == .native {
                sessionState.pendingPermission = nil
            }
            try? await backend.selectSession(session.id)
            return session
        } catch {
            addErrorEvent("No pude crear la conversación: \(error.localizedDescription)")
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
            addErrorEvent("No pude renombrar la conversación: \(error.localizedDescription)")
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
        let attachments = sessionState.composerAttachments
        guard (!trimmed.isEmpty || !attachments.isEmpty), !sessionState.isProcessing else { return }

        if attachments.contains(where: {
            if case .preparing = $0.state { return true }
            if case .selected = $0.state { return true }
            return false
        }) {
            addErrorEvent("Espera un momento a que terminen de prepararse los adjuntos antes de enviar.")
            return
        }

        guard let backend = currentBackend else {
            addErrorEvent("No backend available")
            return
        }

        let effectivePrompt = trimmed.isEmpty ? "Analiza los elementos adjuntos." : trimmed
        let snapshot = runtimeSnapshot
        let activeProviderID = sessionState.selectedModel?.route ?? snapshot.providerID
        let activeModelID = sessionState.selectedModel?.apiModelId ?? snapshot.modelName ?? configuredModelName

        sessionState.isProcessing = true
        let runningID = currentSessionID
        if let runningID {
            runningSessionIDs.insert(runningID)
        }
        if backendMode == .remote {
            isProcessingRemote = true
        }
        if let native = backend as? NativeSwiftBackend {
            native.flowMode = sessionState.flowMode
        }

        let agent = sessionState.agentMode.rawValue.lowercased()
        let model = sessionState.selectedModel

        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = await ChatAttachmentManager.shared.prepareForSend(
                    attachments: attachments,
                    providerID: activeProviderID,
                    modelID: activeModelID,
                    backendMode: self.backendMode
                )

                if let blockedReason = prepared.blockedReason {
                    await MainActor.run {
                        self.sessionState.isProcessing = false
                        if let runningID { self.runningSessionIDs.remove(runningID) }
                        self.isProcessingRemote = false
                        self.addErrorEvent("Adjunto no compatible con el proveedor actual:\n\(blockedReason)")
                    }
                    return
                }

                let sentAttachments: [Attachment] = attachments.map { item in
                    var copy = item
                    copy.state = .sent
                    return copy
                }

                await MainActor.run {
                    let userEvent = TimelineEvent.userPrompt(
                        effectivePrompt,
                        attachments: sentAttachments,
                        agentMode: self.sessionState.agentMode
                    )
                    self.sessionState.addEvent(userEvent)
                    self.sessionState.composerAttachments.removeAll()
                }

                if prepared.parts.isEmpty && !attachments.isEmpty {
                    let promptText = effectivePrompt + "\n" + prepared.fallbackPromptNotes.joined(separator: " ")
                    try await backend.sendPrompt(promptText, agent: agent, model: model)
                } else {
                    try await backend.sendPrompt(effectivePrompt, multimodalParts: prepared.parts, agent: agent, model: model)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    if let runningID { self.runningSessionIDs.remove(runningID) }
                    self.isProcessingRemote = false
                    self.addSystemEvent("Stopped")
                }
            } catch {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    if let runningID { self.runningSessionIDs.remove(runningID) }
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
        PermissionNotifier.shared.clear(requestID: requestId)
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
    
    public func revokeActiveSequenceApproval() {
        Task { [weak self] in
            if let native = self?.currentBackend as? NativeSwiftBackend {
                await native.revokeSequenceApproval()
            }
            await MainActor.run {
                self?.activeSequenceScope = nil
                self?.addSystemEvent("Secuencia WDA revocada por el usuario.")
            }
        }
    }

    /// Refreshes project/session listings cleanly without re-authenticating providers or canceling active runs (Section 4).
    public func refreshConversations() async {
        guard !isRefreshingSessions else { return }
        guard let backend = currentBackend else {
            await refreshRuntimeIntent()
            return
        }
        isRefreshingSessions = true
        defer { isRefreshingSessions = false }
        do {
            let refreshedProjects = try await backend.listProjects()
            if !refreshedProjects.isEmpty {
                projects = refreshedProjects
            }
            if let projectID = currentProjectID ?? projects.first?.id {
                sessions = try await backend.listSessions(projectID: projectID)
            }
            await refreshRuntimeIntent()
        } catch {
            // Preserve existing sessions on failure; surface recoverable notice
            lastRuntimeError = error.localizedDescription
        }
    }

    /// Activa o desactiva el vigilante del buzón [GUS]. Al activarlo arranca en el
    /// backend nativo si hay sesión abierta; al desactivarlo se detiene. El ajuste
    /// vive en UserDefaults y el vigilante lo vuelve a leer en cada revisión.
    public func setMailboxWatcherEnabled(_ enabled: Bool) {
        GUSMailboxWatcher.isEnabled = enabled
        Task { [weak self] in
            guard let backend = self?.currentBackend as? NativeSwiftBackend else { return }
            if enabled {
                await backend.maybeStartMailboxWatcher()
            } else {
                await backend.stopMailboxWatcher()
            }
        }
    }

    public func setModel(_ model: ModelInfo) {
        sessionState.selectedModel = model
        let modelIdentifier = model.apiModelId ?? model.name
        configuredModelName = modelIdentifier
        addSystemEvent("Model: \(model.name)")
        Task {
            if let persistence = try? IOSPersistence() {
                var configuration = (try? await persistence.loadConfiguration()) ?? Configuration()
                configuration.defaultModelName = modelIdentifier
                if let route = model.route, SandboxModelProvider.provider(id: route) != nil {
                    configuration.defaultModelProvider = route
                    configuredProviderID = route
                }
                try? await persistence.saveConfiguration(configuration)
            }
            await refreshRuntimeIntent()
        }
    }
    
    public func setAgentMode(_ mode: AgentMode) {
        sessionState.agentMode = mode
        addSystemEvent("Agent mode: \(mode.rawValue)")
    }
    
    @discardableResult
    public func loadFiles(path: String = "") async -> Bool {
        guard let backend = currentBackend else { return false }
        do {
            fileTree = try await backend.listFiles(path: path)
            filesPath = path
            return true
        } catch {
            addErrorEvent("No pude cargar los archivos: \(error.localizedDescription)")
            return false
        }
    }
    
    public func loadFileContent(path: String) async -> WorkbenchFileContent? {
        guard let backend = currentBackend else { return nil }
        do {
            return try await backend.fileContent(path: path)
        } catch {
            addErrorEvent("No pude abrir el archivo: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func loadDiff(sessionID: String) async {
        guard let backend = currentBackend else { return }
        do {
            diffFiles = try await backend.sessionDiff(sessionID: sessionID)
        } catch {
            if backendMode != .native {
                addErrorEvent("No pude cargar los cambios: \(error.localizedDescription)")
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
            addErrorEvent("No pude cargar modelos y agentes: \(error.localizedDescription)")
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
            runningSessionIDs.removeAll()
            connectionHealth = .connected
            addSystemEvent("Connected")

        case .disconnected(let reason):
            sessionState.isProcessing = false
            isProcessingRemote = false
            runningSessionIDs.removeAll()
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
                OCHaptics.attention()
                PermissionNotifier.shared.onDecision = { [weak self] requestID, decision in
                    // Only the request still on screen can be answered from a notification.
                    guard self?.sessionState.pendingPermission?.permissionRequestId == requestID else { return }
                    self?.respondToPermission(requestId: requestID, decision: decision)
                }
                PermissionNotifier.shared.notify(requestID: requestID, tool: tool, command: command, explanation: explanation)
            } else if backendMode == .native {
                // A conversation working in the background is waiting: tell the person.
                // The question shows up in full when they open that conversation.
                PermissionNotifier.shared.notify(requestID: requestID, tool: tool, command: command, explanation: explanation)
            }

        case .sessionIdle(let sessionID):
            // The native backend reports busy/idle with `.sessionRunState`, sent once the
            // turn has fully released the model; `.sessionIdle` comes a moment earlier.
            if backendMode != .native {
                runningSessionIDs.remove(sessionID)
            }
            if sessionID == currentSessionID {
                if backendMode != .native {
                    sessionState.isProcessing = false
                    isProcessingRemote = false
                }
                addSuccessEvent("Listo")
                OCHaptics.done()
            }

        case .sessionError(let message):
            sessionState.isProcessing = false
            isProcessingRemote = false
            if backendMode != .native, let currentSessionID {
                runningSessionIDs.remove(currentSessionID)
            }
            addErrorEvent(message)

        case .sessionRunState(let sessionID, let state):
            let onScreen = sessionID == currentSessionID
            switch state {
            case .running:
                runningSessionIDs.insert(sessionID)
                if onScreen { sessionState.isProcessing = true }
            case .queued:
                runningSessionIDs.insert(sessionID)
                if onScreen {
                    sessionState.isProcessing = true
                    addSystemEvent("En fila: el modelo del iPhone está terminando otra conversación. Esta empieza en cuanto quede libre.")
                }
            case .idle:
                runningSessionIDs.remove(sessionID)
                if onScreen { sessionState.isProcessing = false }
            }
            
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

        case .sequenceScopeChanged(let scope):
            activeSequenceScope = scope
            
        case .filesChanged:
            await loadFiles()
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
            let resolvedOutput = (output?.isEmpty == false ? output : nil) ?? error
            if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == eventID }) {
                sessionState.updateToolCall(id: eventID, state: state, output: resolvedOutput, duration: nil)
            } else {
                let toolName = tool ?? "tool"
                let event = TimelineEvent.toolCall(id: eventID, name: toolName, arguments: input, state: state, agentMode: sessionState.agentMode)
                sessionState.addEvent(event)
                if let resolvedOutput {
                    sessionState.updateToolCall(id: eventID, state: state, output: resolvedOutput, duration: nil)
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
        Task {
            await ChatAttachmentManager.shared.removeStagedFile(for: attachment)
        }
    }
    
    public func saveAPIKeys(xai: String, openAI: String) async {
        await saveAPIKeys(values: ["xai": xai, "openai": openAI], selectedProviderID: "xai")
    }

    public func saveAPIKeys(values: [String: String], selectedProviderID: String) async {
        do {
            let persistence = try IOSPersistence()
            guard SandboxModelProvider.provider(id: selectedProviderID) != nil else {
                throw ModelProviderError.invalidRequest("Unknown sandbox provider")
            }
            for (providerID, value) in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { try await persistence.saveAPIKey(provider: providerID, key: trimmed) }
            }
            var configuration = try await persistence.loadConfiguration() ?? Configuration()
            configuration.defaultModelProvider = selectedProviderID
            try await persistence.saveConfiguration(configuration)
            hasCompletedOnboarding = true
            UserDefaults.standard.set("native", forKey: RuntimeIntentDefaults.lastRuntimeModeKey)
            if let backend = currentBackend as? NativeSwiftBackend {
                try await backend.reloadSandboxModel()
                connectionStatus = await backend.connectionStatus
                sandboxUsesLiveModel = backend.usesLiveModel
                lastRuntimeError = nil
                lastVerifiedAt = Date()
                await loadModelsAndAgents()
                let preferredModelID = backend.currentModelName
                if let preferredModelID,
                   let match = availableModels.first(where: { $0.apiModelId == preferredModelID || $0.name == preferredModelID }) {
                    sessionState.selectedModel = match
                } else if let model = availableModels.first {
                    sessionState.selectedModel = model
                }
                addSystemEvent(connectionStatus)
            } else {
                await useNativeRuntime()
            }
            await refreshRuntimeIntent()
        } catch {
            lastRuntimeError = error.localizedDescription
            addErrorEvent("Could not save the API key: \(error.localizedDescription)")
            await refreshRuntimeIntent()
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
                await makeSandboxExecutor(client: client, sandboxID: prepared.status.id, info: info),
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
            if iphoneControlActive != nil {
                addSystemEvent(iphoneControlEventText)
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

    /// Builds the sandbox executor with the iPhone control that applies right now: the person's
    /// preference, resolved against what is reachable (the computer's bridge tools and WebDriverAgent
    /// on this phone at 127.0.0.1:8100).
    func makeSandboxExecutor(client: SandboxHostClient, sandboxID: String, info: SandboxBridgeInfo) async -> SandboxToolExecutor {
        let localReachable = await Self.localWdaReachable()
        let mode = IphoneControlMode.resolve(
            preferred: iphoneControlPreference,
            bridgeTools: info.iphoneTools,
            localReachable: localReachable
        )
        iphoneControlActive = mode
        let local: LocalIphoneController? = mode == .thisPhone
            ? LocalIphoneController(wda: WdaClientDriver(client: WdaClient()), elementReader: WdaElementReader())
            : nil
        return SandboxToolExecutor(
            client: client,
            sandboxID: sandboxID,
            info: info,
            localIphone: local,
            iphoneMode: mode ?? .computer
        )
    }

    /// True when WebDriverAgent answers /status on this phone's loopback. Read-only.
    nonisolated static func localWdaReachable() async -> Bool {
        do {
            return try await WdaClient().status().ready
        } catch {
            return false
        }
    }

    /// Saves who drives the iPhone and, if a sandbox is linked, rebuilds its tools with the new mode.
    public func setIphoneControlPreference(_ preference: IphoneControlMode?) async {
        iphoneControlPreference = preference
        if let preference {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.iphoneControlPreferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.iphoneControlPreferenceKey)
        }
        guard let client = sandboxClient, let link = sandboxLink, !sandboxLinkBusy,
              let backend = currentBackend as? NativeSwiftBackend else { return }
        sandboxLinkBusy = true
        defer { sandboxLinkBusy = false }
        do {
            let info = try await client.bridgeInfo()
            backend.attachSandbox(
                await makeSandboxExecutor(client: client, sandboxID: link.sandboxID, info: info),
                projectName: info.projectName,
                projectPath: link.directory
            )
            addSystemEvent(iphoneControlEventText)
        } catch {
            sandboxLinkError = error.localizedDescription
        }
    }

    var iphoneControlEventText: String {
        switch iphoneControlActive {
        case .thisPhone: return "El agente controla este iPhone directamente (sin pasar por la computadora)."
        case .computer: return "El agente controla el iPhone a través de tu computadora."
        case nil: return "El agente no tiene control del iPhone: ni la computadora lo ofrece ni este iPhone responde."
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
                await makeSandboxExecutor(client: client, sandboxID: prepared.status.id, info: info),
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
        iphoneControlActive = nil
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

// MARK: - Persisted Runtime & Session Restoration

extension WorkbenchStore {
    /// Refreshes the user's persisted runtime intent (configured provider, model, key & local model availability).
    public func refreshRuntimeIntent() async {
        await GUSModelDownloadManager.shared.refresh()
        hasInstalledLocalModel = GUSModelDownloadManager.shared.selectedModelURL != nil
        if let persistence = try? IOSPersistence(),
           let configuration = try? await persistence.loadConfiguration() {
            configuredProviderID = configuration.defaultModelProvider
            configuredModelName = configuration.defaultModelName
            if let providerID = configuration.defaultModelProvider, providerID != "gus-local" {
                if providerID == "chatgpt-oauth" {
                    hasSavedSelectedProviderKey = ChatGPTOAuthStore.hasStoredTokens()
                } else {
                    let savedKey = (try? await persistence.loadAPIKey(provider: providerID)) ?? ""
                    hasSavedSelectedProviderKey = !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            } else {
                hasSavedSelectedProviderKey = false
            }
        } else {
            configuredProviderID = nil
            configuredModelName = nil
            hasSavedSelectedProviderKey = false
        }
    }

    /// Restores the user's last runtime, model, project, and session at app launch so
    /// returning users land directly in WorkspaceHomeView ready to continue.
    public func restorePersistedExperience() async {
        guard !isRestoringRuntime, backendMode == .unconfigured else {
            await refreshRuntimeIntent()
            return
        }
        isRestoringRuntime = true
        defer { isRestoringRuntime = false }

        await refreshRuntimeIntent()
        let lastMode = UserDefaults.standard.string(forKey: RuntimeIntentDefaults.lastRuntimeModeKey)
        let hasPairing = await hasStoredPairing()

        if lastMode == "remote" && hasPairing {
            await reconnectStoredPairing()
            await refreshRuntimeIntent()
            return
        }

        if let providerID = configuredProviderID {
            hasCompletedOnboarding = true
            let canStart = (providerID == "gus-local" && hasInstalledLocalModel)
                || (providerID != "gus-local" && hasSavedSelectedProviderKey)
            if canStart {
                await useNativeRuntime()
                return
            }
        }

        if lastMode == "demo" {
            hasCompletedOnboarding = true
            await useNativeDemoRuntime()
            await refreshRuntimeIntent()
            return
        }

        if lastMode == "native" || hasCompletedOnboarding {
            hasCompletedOnboarding = true
            if hasInstalledLocalModel || hasSavedSelectedProviderKey {
                await useNativeRuntime()
            }
            return
        }

        if hasPairing {
            hasCompletedOnboarding = true
        }
    }

    /// Ensures the native runtime is active and opens either the last active conversation or a new one.
    @discardableResult
    public func openOrCreateConversation(preferNew: Bool = false, initialPrompt: String? = nil) async -> Bool {
        if backendMode == .unconfigured {
            let canUseConfigured = (configuredProviderID == "gus-local" && hasInstalledLocalModel)
                || (configuredProviderID != nil && configuredProviderID != "gus-local" && hasSavedSelectedProviderKey)
            if canUseConfigured {
                await useNativeRuntime()
            } else {
                await useNativeDemoRuntime()
            }
        }

        guard backendMode != .unconfigured else { return false }

        if sessionState.currentProject == nil, let firstProject = projects.first {
            await selectProject(firstProject)
        }
        guard let project = sessionState.currentProject else { return false }

        if preferNew || sessionState.currentSession == nil {
            let title = initialPrompt.flatMap { prompt -> String? in
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
            } ?? "Nueva conversación"
            guard await createNewSession(in: project, title: title) != nil else { return false }
        }

        sessionState.activeSurface = .chat
        let hasAttachments = !sessionState.composerAttachments.isEmpty
        if let initialPrompt {
            let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || hasAttachments {
                sendPrompt(trimmed)
            }
        } else if hasAttachments {
            sendPrompt("")
        }
        return true
    }

    public func retryRuntimeConnection() async {
        lastRuntimeError = nil
        sandboxSetupError = nil
        switch backendMode {
        case .remote:
            await reconnectStoredPairing()
        case .native, .unconfigured:
            if configuredProviderID != nil {
                await useNativeRuntime()
            } else {
                await restorePersistedExperience()
            }
        }
    }
}

// MARK: - Conversation sandboxes (Ajustes)

public struct ConversationSandboxSummary: Equatable, Sendable {
    public let folders: Int
    public let bytes: Int64
    /// Folders whose conversation was deleted; nil when the conversation list could not be read.
    public let orphanFolders: Int?
    public let orphanBytes: Int64
}

extension WorkbenchStore {
    /// How many conversation folders exist and how much they take, for Ajustes.
    public func conversationSandboxSummary() async -> ConversationSandboxSummary {
        let entries = ConversationSandboxes.list()
        let live = await liveConversationIDs()
        let orphans = live.map { ConversationSandboxes.orphans(entries, liveConversationIDs: $0) }
        return ConversationSandboxSummary(
            folders: entries.count,
            bytes: entries.reduce(0) { $0 + $1.byteCount },
            orphanFolders: orphans?.count,
            orphanBytes: orphans?.reduce(0) { $0 + $1.byteCount } ?? 0
        )
    }

    /// `onlyOrphans`: folders of deleted conversations. Otherwise every folder. Folders of
    /// conversations working right now are always kept.
    public func cleanConversationSandboxes(onlyOrphans: Bool) async -> ConversationSandboxes.CleanupResult {
        let entries = ConversationSandboxes.list()
        let targets: [ConversationSandboxes.Entry]
        if onlyOrphans {
            // Without the conversation list we cannot tell which folders are orphans: delete nothing.
            guard let live = await liveConversationIDs() else {
                return ConversationSandboxes.CleanupResult(removedFolders: 0, freedBytes: 0, skippedRunning: 0)
            }
            targets = ConversationSandboxes.orphans(entries, liveConversationIDs: live)
        } else {
            targets = entries
        }
        let result = ConversationSandboxes.remove(targets, keepingRunning: runningSessionIDs)
        (currentBackend as? NativeSwiftBackend)?.forgetIdleRuntimes(folderNames: Set(targets.map(\.folderName)))
        if !onlyOrphans {
            _ = await loadFiles()
        }
        return result
    }

    private func liveConversationIDs() async -> Set<String>? {
        let persistence: IOSPersistence?
        if let native = currentBackend as? NativeSwiftBackend, let shared = native.persistence {
            persistence = shared
        } else {
            persistence = try? IOSPersistence()
        }
        guard let persistence, let conversations = try? await persistence.listConversations() else { return nil }
        return Set(conversations.map(\.id))
    }
}

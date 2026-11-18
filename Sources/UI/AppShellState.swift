import Foundation
import SwiftUI

public enum AppShellTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case conversations
    case projects
    case google
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Inicio"
        case .conversations: return "Conversaciones"
        case .projects: return "Proyectos"
        case .google: return "Google"
        case .settings: return "Ajustes"
        }
    }

    public var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .conversations: return "bubble.left.and.bubble.right.fill"
        case .projects: return "folder.fill"
        case .google: return "person.crop.circle.badge.checkmark"
        case .settings: return "gearshape.fill"
        }
    }

    public var accessibilityID: String { "tab-\(rawValue)" }
}

public enum GoogleHubSubtab: String, CaseIterable, Identifiable, Sendable {
    case google
    case memory
    case log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .google: return "Google y tools"
        case .memory: return "Memoria"
        case .log: return "Registro"
        }
    }

    public static func visible(developerMode: Bool) -> [GoogleHubSubtab] {
        developerMode ? [.google, .memory, .log] : [.google, .memory]
    }
}

public enum RuntimeSetupTrack: String, CaseIterable, Identifiable, Sendable {
    case local
    case connected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return "Local en iPhone"
        case .connected: return "Proveedor conectado"
        }
    }

    public var subtitle: String {
        switch self {
        case .local: return "Sin internet · modelo en el dispositivo"
        case .connected: return "NVIDIA, xAI, OpenAI, Gemini, OpenRouter"
        }
    }

    public var symbol: String {
        switch self {
        case .local: return "iphone"
        case .connected: return "cloud"
        }
    }
}

public enum AppShellDestination: String, CaseIterable, Identifiable, Sendable {
    case chat
    case builder
    case myAgents
    case browser
    case projects
    case google
    case connections
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .builder: return "Construir"
        case .myAgents: return "Mis agentes"
        case .browser: return "Navegador"
        case .projects: return "Proyectos"
        case .google: return "Google"
        case .connections: return "Conexiones"
        case .settings: return "Ajustes"
        }
    }

    public var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .builder: return "hammer.fill"
        case .myAgents: return "square.stack.3d.up.fill"
        case .browser: return "safari"
        case .projects: return "folder.fill"
        case .google: return "person.crop.circle.badge.checkmark"
        case .connections: return "link.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class AppShellRouter: ObservableObject {
    @Published public var selectedTab: AppShellTab = .conversations
    @Published public var activeDestination: AppShellDestination = .chat
    @Published public var isSidebarOpen = false
    @Published public var googleSubtab: GoogleHubSubtab = .google
    @Published public var showRuntimeSetupSheet = false
    @Published public var runtimeSetupInitialTrack: RuntimeSetupTrack = .connected
    @Published public var runtimeSetupInitialProviderID: String?
    @Published public var showRemotePairingSheet = false
    @Published public var showGoogleOAuthSetupSheet = false
    @Published public var showSandboxExplanationSheet = false
    @Published public var showLearnActionSheet = false
    @Published public var showSecretVaultSheet = false

    public init() {}

    public func openHome() {
        selectedTab = .home
        activeDestination = .chat
        isSidebarOpen = false
    }

    public func openConversations() {
        selectedTab = .conversations
        activeDestination = .chat
        isSidebarOpen = false
    }

    public func openBuilder() {
        activeDestination = .builder
        isSidebarOpen = false
    }

    public func openMyAgents() {
        activeDestination = .myAgents
        isSidebarOpen = false
    }

    public func openProjects() {
        selectedTab = .projects
        activeDestination = .projects
        isSidebarOpen = false
    }

    public func openGoogle(subtab: GoogleHubSubtab = .google) {
        googleSubtab = subtab
        selectedTab = .google
        activeDestination = .google
        isSidebarOpen = false
    }

    public func openConnections() {
        activeDestination = .connections
        isSidebarOpen = false
    }

    public func openBrowser() {
        activeDestination = .browser
        isSidebarOpen = false
    }

    public func openSettings() {
        selectedTab = .settings
        activeDestination = .settings
        isSidebarOpen = false
    }

    public func openLearnAction() {
        isSidebarOpen = false
        showLearnActionSheet = true
    }

    public func openSecretVault() {
        isSidebarOpen = false
        showSecretVaultSheet = true
    }

    public func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.22)) {
            isSidebarOpen.toggle()
        }
    }

    public func closeSidebar() {
        withAnimation(.easeOut(duration: 0.2)) {
            isSidebarOpen = false
        }
    }

    public func openRuntimeSetup(track: RuntimeSetupTrack, providerID: String? = nil) {
        runtimeSetupInitialTrack = track
        runtimeSetupInitialProviderID = providerID
        showRuntimeSetupSheet = true
    }

    public func handle(_ target: GoogleDeepLinkTarget, assistant: AssistantStore) {
        switch target {
        case .googleHome:
            openGoogle(subtab: .google)
        case .googleOAuthSetup:
            showGoogleOAuthSetupSheet = true
        case .authorizeService(let service):
            openGoogle(subtab: .google)
            assistant.authorizeService(service)
        case .reconnectExpired:
            openGoogle(subtab: .google)
            assistant.signIn()
        }
    }
}

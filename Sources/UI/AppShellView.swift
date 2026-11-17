import SwiftUI

/// Main workspace shell uniting Home, Conversations, Projects, Google/Memory, and Settings.
/// Uses TabView on compact screens and NavigationSplitView (defaulting to Home) on regular screens.
public struct AppShellView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init() {}

    public var body: some View {
        Group {
            if sizeClass == .regular {
                regularShell
            } else {
                compactShell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .sheet(isPresented: $router.showRuntimeSetupSheet) {
            RuntimeSetupSheet(
                initialTrack: router.runtimeSetupInitialTrack,
                initialProviderID: router.runtimeSetupInitialProviderID,
                onOpenRemotePairing: { router.showRemotePairingSheet = true }
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $router.showRemotePairingSheet) {
            ReconnectSheet(isPresented: $router.showRemotePairingSheet)
                .environmentObject(store)
        }
        .sheet(isPresented: $router.showGoogleOAuthSetupSheet) {
            GoogleOAuthSetupSheet()
                .environmentObject(assistant)
        }
        .sheet(item: $assistant.pending) { action in
            AssistantConfirmActionSheet(action: action)
                .environmentObject(assistant)
                .presentationDetents([.medium, .large])
        }
    }

    private var compactShell: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack {
                WorkspaceHomeView()
            }
            .tabItem {
                Label(AppShellTab.home.title, systemImage: AppShellTab.home.symbol)
            }
            .tag(AppShellTab.home)
            .accessibilityIdentifier(AppShellTab.home.accessibilityID)

            NavigationStack {
                ConversationsTabView()
            }
            .tabItem {
                Label(AppShellTab.conversations.title, systemImage: AppShellTab.conversations.symbol)
            }
            .tag(AppShellTab.conversations)
            .accessibilityIdentifier(AppShellTab.conversations.accessibilityID)

            NavigationStack {
                ProjectsTabView()
            }
            .tabItem {
                Label(AppShellTab.projects.title, systemImage: AppShellTab.projects.symbol)
            }
            .tag(AppShellTab.projects)
            .accessibilityIdentifier(AppShellTab.projects.accessibilityID)

            NavigationStack {
                GoogleWorkspaceHubView()
            }
            .tabItem {
                Label(AppShellTab.google.title, systemImage: AppShellTab.google.symbol)
            }
            .tag(AppShellTab.google)
            .accessibilityIdentifier(AppShellTab.google.accessibilityID)

            NavigationStack {
                UnifiedSettingsView()
            }
            .tabItem {
                Label(AppShellTab.settings.title, systemImage: AppShellTab.settings.symbol)
            }
            .tag(AppShellTab.settings)
            .accessibilityIdentifier(AppShellTab.settings.accessibilityID)
        }
        .tint(IysThemePreferences.active.accent)
    }

    private var regularShell: some View {
        NavigationSplitView {
            List(selection: Binding<AppShellTab?>(
                get: { router.selectedTab },
                set: { if let next = $0 { router.selectedTab = next } }
            )) {
                Section("Espacio de trabajo") {
                    ForEach(AppShellTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .tag(tab)
                            .accessibilityIdentifier("sidebar-\(tab.rawValue)")
                    }
                }
            }
            .navigationTitle("ISYCODE")
        } detail: {
            NavigationStack {
                regularDetailContent
            }
        }
    }

    @ViewBuilder
    private var regularDetailContent: some View {
        switch router.selectedTab {
        case .home:
            WorkspaceHomeView()
        case .conversations:
            ConversationsTabView()
        case .projects:
            ProjectsTabView()
        case .google:
            GoogleWorkspaceHubView()
        case .settings:
            UnifiedSettingsView()
        }
    }
}

/// Conversations tab: embeds the active chat directly inside the shell when selected,
/// or lets the user resume/start a conversation without going through Sandbox/Settings.
public struct ConversationsTabView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var router: AppShellRouter

    public init() {}

    public var body: some View {
        Group {
            if sessionState.currentSession != nil {
                ActiveSessionView()
            } else if let project = sessionState.currentProject {
                SessionListView(project: project)
            } else {
                emptyConversationsHub
            }
        }
    }

    private var emptyConversationsHub: some View {
        let runtime = store.runtimeSnapshot
        return VStack(spacing: OCSpacing.xl) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(IysThemePreferences.active.accent)

            VStack(spacing: OCSpacing.xs) {
                Text("Sin conversación abierta")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(OCColor.textPrimary)
                Text(runtime.readiness.isUsableForChat
                     ? "Tu motor (\(runtime.providerName)) está listo para empezar de inmediato."
                     : "Empieza una conversación de prueba o configura tu motor en Inicio.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { _ = await store.openOrCreateConversation(preferNew: true) }
            } label: {
                Label("Nueva conversación", systemImage: "plus.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Capsule().fill(IysThemePreferences.active.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversations-empty-new-button")

            Button("Ver proyectos") {
                router.openProjects()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(OCColor.textSecondary)
        }
        .padding(OCSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Conversaciones")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Projects tab preserving ProjectListContent -> SessionListView -> ActiveSessionView navigation.
public struct ProjectsTabView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var router: AppShellRouter

    public init() {}

    public var body: some View {
        Group {
            if sessionState.currentProject == nil {
                ProjectListContent()
            } else if sessionState.currentSession == nil {
                SessionListView(project: sessionState.currentProject!)
            } else {
                ActiveSessionView()
            }
        }
    }
}

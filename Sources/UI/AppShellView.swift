import SwiftUI

/// Main workspace shell: ChatGPT/Claude-style chat home with a slide-over sidebar drawer
/// on compact screens, and a persistent NavigationSplitView sidebar on regular screens.
public struct AppShellView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var dragOffset: CGFloat = 0

    public init() {}

    private let sidebarWidth: CGFloat = 292

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
        .sheet(isPresented: $router.showSandboxExplanationSheet) {
            SandboxExplanationSheet()
        }
        .sheet(item: $assistant.pending) { action in
            AssistantConfirmActionSheet(action: action)
                .environmentObject(assistant)
                .presentationDetents([.medium, .large])
        }
    }

    private var compactShell: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                destinationContent(showsSidebarButton: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(router.isSidebarOpen)

            if router.isSidebarOpen {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { router.closeSidebar() }
                    .transition(.opacity)
            }

            if router.isSidebarOpen || dragOffset > 0 {
                ChatSidebarView(showsCloseButton: true) {
                    router.closeSidebar()
                }
                .frame(width: sidebarWidth)
                .offset(x: router.isSidebarOpen ? min(0, dragOffset) : (-sidebarWidth + min(sidebarWidth, dragOffset)))
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 4, y: 0)
                .transition(.move(edge: .leading))
            }
        }
        .simultaneousGesture(edgeSwipeGesture)
        .animation(.easeOut(duration: 0.22), value: router.isSidebarOpen)
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                if router.isSidebarOpen {
                    if value.translation.width < 0 {
                        dragOffset = value.translation.width
                    }
                } else if value.startLocation.x < 32 && value.translation.width > 0 {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                let threshold: CGFloat = 72
                if router.isSidebarOpen {
                    if value.translation.width < -threshold {
                        router.closeSidebar()
                    }
                } else if value.startLocation.x < 32 && value.translation.width > threshold {
                    withAnimation(.easeOut(duration: 0.22)) {
                        router.isSidebarOpen = true
                    }
                }
                dragOffset = 0
            }
    }

    private var regularShell: some View {
        NavigationSplitView {
            ChatSidebarView(showsCloseButton: false)
                .navigationTitle("ISYCODE")
        } detail: {
            NavigationStack {
                destinationContent(showsSidebarButton: false)
            }
        }
    }

    @ViewBuilder
    private func destinationContent(showsSidebarButton: Bool) -> some View {
        switch router.activeDestination {
        case .chat:
            if sessionState.currentSession != nil {
                ActiveSessionView(onOpenSidebar: showsSidebarButton ? { router.toggleSidebar() } : nil)
            } else {
                ChatLandingView(onOpenSidebar: { router.toggleSidebar() })
            }
        case .browser:
            InAppBrowserView()
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        case .projects:
            ProjectsTabView()
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        case .google:
            GoogleWorkspaceHubView()
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        case .connections:
            ConnectionsView()
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        case .settings:
            UnifiedSettingsView()
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        }
    }

    private var sidebarLeadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                router.toggleSidebar()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(OCColor.iconPrimary)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Abrir barra lateral")
        }
    }
}

/// Conversations tab view kept for compatibility.
public struct ConversationsTabView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var router: AppShellRouter

    public init() {}

    public var body: some View {
        Group {
            if sessionState.currentSession != nil {
                ActiveSessionView()
            } else {
                ChatLandingView(onOpenSidebar: { router.toggleSidebar() })
            }
        }
    }
}

/// Projects view: starts at the project list and drills into a project's sessions on tap.
public struct ProjectsTabView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var router: AppShellRouter
    @State private var browsingProject: Project?

    public init() {}

    public var body: some View {
        Group {
            if let project = browsingProject {
                SessionListView(
                    project: project,
                    onBack: { browsingProject = nil },
                    onOpenSession: { router.openConversations() }
                )
            } else {
                ProjectListContent(onSelectProject: { project in
                    browsingProject = project
                })
            }
        }
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactPath = NavigationPath()
    @State private var dragOffset: CGFloat = 0
    /// Set after a gesture release so the settle uses a spring carrying that velocity;
    /// the time-based drawer curve is for releases that did not involve a finger.
    @State private var settleAnimation: Animation = OCMotion.drawer

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
        .sheet(isPresented: $router.showSandboxExplanationSheet) {
            SandboxExplanationSheet()
        }
        .sheet(isPresented: $router.showLearnActionSheet) {
            LearnActionRecorderSheet()
                .environmentObject(router)
        }
        .sheet(isPresented: $router.showActivitySheet) {
            AgentActivityDetailSheet(events: sessionState.timelineEvents)
        }
        .sheet(isPresented: $router.showSecretVaultSheet) {
            SecretVaultSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLearnActionSheet)) { _ in
            router.openLearnAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSecretVaultSheet)) { _ in
            router.openSecretVault()
        }
        .sheet(item: $assistant.pending) { action in
            AssistantConfirmActionSheet(action: action)
                .environmentObject(assistant)
                .presentationDetents([.medium, .large])
        }
    }

    private var compactShell: some View {
        GeometryReader { geometry in
            let width = min(OCNavigation.drawerWidth, max(0, geometry.size.width - OCNavigation.dismissGutter))
            drawer(width: width)
        }
    }

    private func drawer(width sidebarWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            NavigationStack(path: $compactPath) {
                destinationContent(showsSidebarButton: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(router.isSidebarOpen)
            .accessibilityHidden(router.isSidebarOpen)

            if router.isSidebarOpen {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
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
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { router.closeSidebar() }
                .transition(reduceMotion ? .identity : .move(edge: .leading))
            }
        }
        .simultaneousGesture(edgeSwipeGesture)
        .animation(settleAnimation, value: router.isSidebarOpen)
        .onChange(of: router.isSidebarOpen) { if $0 { OCHaptics.light() } }
        .onChange(of: router.activeDestination) { _ in compactPath = NavigationPath() }
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if router.isSidebarOpen {
                    if value.translation.width < 0 {
                        dragOffset = value.translation.width
                    }
                } else if compactPath.isEmpty && value.startLocation.x < OCNavigation.edgeActivation && value.translation.width > 0 {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    dragOffset = 0
                    return
                }
                // Commit by distance OR projected momentum: a fast flick from 10 px away must
                // open/close just like a slow 80 pt drag (appllama motion law: finger → spring).
                let threshold: CGFloat = OCNavigation.drawerCommitDistance
                let projected = value.predictedEndTranslation.width
                if router.isSidebarOpen {
                    if projected < -threshold || value.velocity.width < -OCNavigation.drawerFlickVelocity {
                        settleAnimation = reduceMotion ? nil : OCMotion.drawerSpring(velocity: Double(value.velocity.width) / 100)
                        router.closeSidebar()
                    }
                } else if compactPath.isEmpty && value.startLocation.x < OCNavigation.edgeActivation
                            && (projected > threshold || value.velocity.width > OCNavigation.drawerFlickVelocity) {
                    settleAnimation = reduceMotion ? nil : OCMotion.drawerSpring(velocity: Double(value.velocity.width) / 100)
                    router.isSidebarOpen = true
                }
                dragOffset = 0
            }
    }

    private var regularShell: some View {
        NavigationSplitView {
            ChatSidebarView(showsCloseButton: false)
                .navigationTitle("iSyCode")
        } detail: {
            NavigationStack {
                destinationContent(showsSidebarButton: false)
            }
        }
    }

    @ViewBuilder
    private func destinationContent(showsSidebarButton: Bool) -> some View {
        VStack(spacing: 0) {
            LearnActionLiveBanner(
                onOpenRecorder: { router.openLearnAction() },
                onOpenVault: { router.openSecretVault() }
            )
            destinationBody(showsSidebarButton: showsSidebarButton)
        }
    }

    @ViewBuilder
    private func destinationBody(showsSidebarButton: Bool) -> some View {
        switch router.activeDestination {
        case .chat:
            if sessionState.currentSession != nil && !router.showsNewConversation {
                ActiveSessionView(onOpenSidebar: showsSidebarButton ? { router.toggleSidebar() } : nil)
            } else {
                ChatLandingView(onOpenSidebar: { router.toggleSidebar() })
            }
        case .builder:
            AgentBuilderView()
                .overlay(alignment: .bottomTrailing) {
                    GUSFloatingAdvisorButton()
                        .padding(.trailing, OCSpacing.contentMargin)
                        .padding(.bottom, 68)
                }
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
                }
        case .myAgents:
            MyAgentsView()
                .overlay(alignment: .bottomTrailing) {
                    GUSFloatingAdvisorButton()
                        .padding(.trailing, OCSpacing.contentMargin)
                        .padding(.bottom, OCSpacing.lg)
                }
                .toolbar {
                    if showsSidebarButton {
                        sidebarLeadingToolbarItem
                    }
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
                .overlay(alignment: .bottomTrailing) {
                    GUSFloatingAdvisorButton()
                        .padding(.trailing, OCSpacing.contentMargin)
                        .padding(.bottom, OCSpacing.lg)
                }
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
            if sessionState.currentSession != nil && !router.showsNewConversation {
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

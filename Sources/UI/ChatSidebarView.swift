import SwiftUI

/// ChatGPT/Claude-style sidebar drawer: new chat at top, conversations one by one,
/// and navigation to Google, Projects, Connections and Settings at the bottom.
public struct ChatSidebarView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var router: AppShellRouter
    let showsCloseButton: Bool
    let onClose: () -> Void

    @State private var sessionToRename: Session?
    @State private var renameText = ""
    @State private var sessionToDelete: Session?
    @State private var showDeleteConfirm = false

    public init(showsCloseButton: Bool = false, onClose: @escaping () -> Void = {}) {
        self.showsCloseButton = showsCloseButton
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, OCSpacing.lg)
                .padding(.top, OCSpacing.md)
                .padding(.bottom, OCSpacing.sm)

            newConversationButton
                .padding(.horizontal, OCSpacing.lg)
                .padding(.bottom, OCSpacing.md)

            Divider().overlay(OCColor.borderMuted)

            conversationsSection

            Divider().overlay(OCColor.borderMuted)

            destinationsSection
                .padding(.vertical, OCSpacing.sm)
        }
        .frame(maxHeight: .infinity)
        .background(OCColor.bgBase.ignoresSafeArea())
        .sheet(item: $sessionToRename) { session in
            SidebarRenameSessionSheet(initialTitle: session.title) { newTitle in
                Task { await store.renameSession(session, title: newTitle) }
            }
        }
        .alert("Eliminar conversación", isPresented: $showDeleteConfirm, presenting: sessionToDelete) { session in
            Button("Eliminar", role: .destructive) {
                Task { await store.deleteSession(session) }
            }
            Button("Cancelar", role: .cancel) { sessionToDelete = nil }
        } message: { _ in
            Text("¿Eliminar esta conversación? Esta acción no se puede deshacer.")
        }
    }

    private var header: some View {
        HStack {
            Text("ISYCODE")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .tracking(1.6)
                .foregroundColor(OCColor.textPrimary)
            Spacer()
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OCColor.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar barra lateral")
            }
        }
    }

    private var newConversationButton: some View {
        Button {
            Task {
                _ = await store.openOrCreateConversation(preferNew: true)
                router.openConversations()
                onClose()
            }
        } label: {
            HStack(spacing: OCSpacing.sm) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Nueva conversación")
                    .font(.system(size: 14.5, weight: .semibold))
                Spacer()
            }
            .foregroundColor(OCColor.onAccent)
            .padding(.horizontal, OCSpacing.md)
            .frame(height: 42)
            .background(IysThemePreferences.active.accent.gradient)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-new-conversation")
    }

    private var conversationsSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("CONVERSACIONES")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                    .padding(.horizontal, OCSpacing.lg)
                    .padding(.top, OCSpacing.md)
                    .padding(.bottom, 4)

                if store.sessions.isEmpty {
                    Text("Tus conversaciones aparecerán aquí.")
                        .font(.system(size: 13))
                        .foregroundColor(OCColor.textFaint)
                        .padding(.horizontal, OCSpacing.lg)
                        .padding(.vertical, OCSpacing.sm)
                } else {
                    ForEach(store.sessions) { session in
                        conversationRow(session)
                    }
                }
            }
            .padding(.bottom, OCSpacing.md)
        }
        .refreshable {
            await store.refreshConversations()
        }
    }

    private func conversationRow(_ session: Session) -> some View {
        let isActive = router.activeDestination == .chat && sessionState.currentSession?.id == session.id
        return Button {
            Task {
                await store.selectSession(session)
                router.openConversations()
                onClose()
            }
        } label: {
            HStack(spacing: OCSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                        .foregroundColor(OCColor.textPrimary)
                        .lineLimit(1)
                    Text(session.timestamp, style: .relative)
                        .environment(\.locale, Locale(identifier: "es"))
                        .font(.system(size: 11.5))
                        .foregroundColor(OCColor.textFaint)
                }
                Spacer(minLength: 4)
                // Several conversations can work at once: show which ones are busy.
                if store.runningSessionIDs.contains(session.id) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IysThemePreferences.active.accent)
                        .accessibilityLabel("Trabajando")
                }
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.vertical, 9)
            .background(isActive ? IysThemePreferences.active.accent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OCSpacing.sm)
        .contextMenu {
            if store.supportsSessionManagement {
                Button("Renombrar") {
                    renameText = session.title
                    sessionToRename = session
                }
                Button("Eliminar", role: .destructive) {
                    sessionToDelete = session
                    showDeleteConfirm = true
                }
            }
        }
    }

    private var destinationsSection: some View {
        VStack(spacing: 2) {
            Button {
                sessionState.currentSession = nil
                router.openConversations()
                onClose()
            } label: {
                let isHomeActive = router.activeDestination == .chat && sessionState.currentSession == nil
                HStack(spacing: OCSpacing.md) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isHomeActive ? IysThemePreferences.active.accent : OCColor.iconPrimary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Inicio")
                            .font(.system(size: 14.5, weight: isHomeActive ? .semibold : .medium))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Conversar, Construir, Agentes")
                            .font(.system(size: 11.5))
                            .foregroundColor(OCColor.textFaint)
                    }
                    Spacer()
                }
                .padding(.horizontal, OCSpacing.md)
                .padding(.vertical, 8)
                .background(isHomeActive ? IysThemePreferences.active.accent.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-dest-home")

            destinationButton(.builder, title: "Construir agente", subtitle: "Plantillas y capacidades")
            destinationButton(.myAgents, title: "Mis agentes", subtitle: "Contratos y pruebas")

            HStack(spacing: OCSpacing.xs) {
                Button {
                    OCHaptics.light()
                    router.openLearnAction()
                    onClose()
                } label: {
                    Label("Aprender acción", systemImage: "record.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(IysThemePreferences.active.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(OCColor.bgLayer1)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                }
                .buttonStyle(.plain)

                Button {
                    OCHaptics.light()
                    router.openSecretVault()
                    onClose()
                } label: {
                    Label("Llavero", systemImage: "key.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(OCColor.warning)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(OCColor.bgLayer1)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.vertical, 4)

            destinationButton(.browser, title: "Navegador", subtitle: "Web integrada")
            destinationButton(.google, title: "Google", subtitle: "Correo, agenda, Drive")
            destinationButton(.projects, title: "Proyectos", subtitle: nil)
            destinationButton(.connections, title: "Conexiones", subtitle: "iPhone, PC e ISyMCP")
            destinationButton(.settings, title: "Ajustes", subtitle: nil)
        }
        .padding(.horizontal, OCSpacing.sm)
    }

    private func destinationButton(_ destination: AppShellDestination, title: String, subtitle: String?) -> some View {
        let isActive = router.activeDestination == destination
        return Button {
            switch destination {
            case .chat: router.openConversations()
            case .builder: router.openBuilder()
            case .myAgents: router.openMyAgents()
            case .browser: router.openBrowser()
            case .google: router.openGoogle()
            case .projects: router.openProjects()
            case .connections: router.openConnections()
            case .settings: router.openSettings()
            }
            onClose()
        } label: {
            HStack(spacing: OCSpacing.md) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isActive ? IysThemePreferences.active.accent : OCColor.iconPrimary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14.5, weight: isActive ? .semibold : .medium))
                        .foregroundColor(OCColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.vertical, 9)
            .background(isActive ? IysThemePreferences.active.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-dest-\(destination.rawValue)")
    }
}

private struct SidebarRenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialTitle: String
    let onRename: (String) -> Void
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre de la conversación") {
                    TextField("Título", text: $title)
                }
            }
            .navigationTitle("Renombrar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onRename(title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { title = initialTitle }
        }
        .presentationDetents([.medium])
    }
}

/// Modern 2026 Home Screen: highlights the 3 core actions (Conversar, Construir, Mis agentes),
/// compact expandable system state, GUS contextual advisor, and quick prompt composer (Section 5).
public struct ChatLandingView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @ObservedObject private var isymcpStore = ISyMCPStore.shared
    @ObservedObject private var loopback = LoopbackDeviceSession.shared
    @State private var draft = ""
    @State private var sending = false
    @State private var showSystemDetails = false
    @State private var showGUSAssistant = false
    @StateObject private var mediaCoordinator = MultimodalComposerCoordinator()
    @FocusState private var isInputFocused: Bool
    let onOpenSidebar: () -> Void

    public init(onOpenSidebar: @escaping () -> Void) {
        self.onOpenSidebar = onOpenSidebar
    }

    public var body: some View {
        let runtime = store.runtimeSnapshot
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.lg) {
                    heroHeader(runtime: runtime)

                    if let activeAgent = contractStore.activeAgentForSession {
                        activeAgentBanner(activeAgent)
                    }

                    primaryThreeActionsGrid

                    compactSystemStatusCard(runtime: runtime)

                    suggestedPromptsSection
                }
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.md)
                .padding(.bottom, OCSpacing.lg)
            }
            .refreshable {
                loopback.refreshState()
                await store.refreshConversations()
                if isymcpStore.isPaired {
                    await isymcpStore.refresh()
                }
            }
            .scrollDismissesKeyboard(.interactively)

            composerBar
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(OCColor.iconPrimary)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Abrir barra lateral")
                .accessibilityIdentifier("chat-open-sidebar")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Button {
                        OCHaptics.light()
                        showGUSAssistant = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                            Text("GUS")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(IysThemePreferences.active.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(OCColor.agentBuildSoft))
                        .overlay(Capsule().stroke(OCColor.agentBuildBorder, lineWidth: 1))
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                    .accessibilityLabel("Abrir asistente GUS")
                    .accessibilityIdentifier("landing-gus-button")

                    Button {
                        router.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(OCColor.iconPrimary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Ajustes")
                }
            }
        }
        .sheet(isPresented: $showGUSAssistant) {
            GUSContextualSheet()
                .environmentObject(router)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func heroHeader(runtime: RuntimeSelectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            Text("¿Qué quieres lograr hoy?")
                .font(.system(size: 25, weight: .bold))
                .foregroundColor(OCColor.textPrimary)
            Text("Conversa con tu asistente, construye un agente con capacidades reales sin programar o administra los que ya creaste.")
                .font(.system(size: 13.5))
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                assistantPill(runtime: runtime)
                if let link = store.sandboxLink {
                    Button {
                        router.showSandboxExplanationSheet = true
                    } label: {
                        Label(link.projectName, systemImage: "shippingbox.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OCColor.agentBuild)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(OCColor.agentBuildSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(OCInteractiveButtonStyle())
                }
            }
        }
    }

    private func activeAgentBanner(_ agent: AgentContract) -> some View {
        HStack(spacing: OCSpacing.sm) {
            Image(systemName: agent.icon)
                .foregroundColor(Color(hex: agent.accentHex))
            VStack(alignment: .leading, spacing: 1) {
                Text("Agente activo: \(agent.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text("\(agent.enabledL0Tools.count) L0 · \(agent.l1Tools.count) L1 · \(agent.preferredBackend.shortLabel)")
                    .font(.system(size: 11))
                    .foregroundColor(OCColor.textFaint)
            }
            Spacer()
            Button("Cambiar") {
                contractStore.activeAgentForSession = nil
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(IysThemePreferences.active.accent)
        }
        .padding(10)
        .ocCard(radius: OCRadius.r12, border: Color(hex: agent.accentHex).opacity(0.4))
    }

    private var primaryThreeActionsGrid: some View {
        VStack(spacing: OCSpacing.sm) {
            HStack(spacing: OCSpacing.sm) {
                primaryActionCard(
                    title: "Conversar",
                    subtitle: "Modelos y herramientas",
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: IysThemePreferences.active.accent,
                    id: "home-action-chat"
                ) {
                    OCHaptics.light()
                    if let first = store.sessions.first {
                        Task { await store.selectSession(first) }
                    } else {
                        isInputFocused = true
                    }
                }

                primaryActionCard(
                    title: "Construir",
                    subtitle: "Crea un agente nuevo",
                    symbol: "hammer.fill",
                    tint: OCColor.info,
                    id: "home-action-build"
                ) {
                    OCHaptics.light()
                    router.openBuilder()
                }
            }

            primaryActionCard(
                title: "Mis agentes",
                subtitle: contractStore.agents.isEmpty
                    ? "Administra tus agentes y contratos"
                    : "\(contractStore.agents.count) \(contractStore.agents.count == 1 ? "agente listo" : "agentes listos") · Contratos .isyagent.json y pruebas",
                symbol: "square.stack.3d.up.fill",
                tint: OCColor.success,
                id: "home-action-agents"
            ) {
                OCHaptics.light()
                router.openMyAgents()
            }

            HStack(spacing: OCSpacing.sm) {
                primaryActionCard(
                    title: "Aprender acción",
                    subtitle: "Graba flujo por WDA",
                    symbol: "record.circle",
                    tint: OCColor.danger,
                    id: "home-action-learn"
                ) {
                    OCHaptics.medium()
                    router.openLearnAction()
                }

                primaryActionCard(
                    title: "Llavero",
                    subtitle: "Claves con Face ID",
                    symbol: "key.fill",
                    tint: OCColor.warning,
                    id: "home-action-vault"
                ) {
                    OCHaptics.light()
                    router.openSecretVault()
                }
            }
        }
    }

    private func primaryActionCard(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: OCRadius.r10)
                        .fill(tint.opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(OCColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(OCSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ocCard(radius: OCRadius.r14, border: tint.opacity(0.28), background: OCColor.bgBase)
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .accessibilityIdentifier(id)
    }

    private func compactSystemStatusCard(runtime: RuntimeSelectionSnapshot) -> some View {
        let backendLabel: String
        if store.sandboxLink != nil {
            backendLabel = "Sandbox en PC"
        } else if isymcpStore.isPaired {
            backendLabel = "iPhone + ISyMCP"
        } else {
            backendLabel = "Este iPhone"
        }

        let recentSummary = store.sessions.first?.title ?? "Sin actividad reciente"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runtime.readiness.isUsableForChat ? OCColor.success : OCColor.warning)
                    .frame(width: 8, height: 8)
                Text("Sistema listo · \(backendLabel)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
                Button {
                    withAnimation(OCMotion.snappy) {
                        showSystemDetails.toggle()
                    }
                } label: {
                    Label(showSystemDetails ? "Ocultar" : "Detalles", systemImage: showSystemDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(OCColor.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Label(runtime.providerName, systemImage: "cpu")
                Text("·")
                Label("Python local", systemImage: "terminal")
                Text("·")
                Label(isymcpStore.isPaired ? "ISyMCP OK" : "Solo iPhone", systemImage: isymcpStore.isPaired ? "desktopcomputer" : "iphone")
            }
            .font(.system(size: 11))
            .foregroundColor(OCColor.textFaint)
            .lineLimit(1)

            if showSystemDetails {
                Divider().overlay(OCColor.borderMuted)
                VStack(alignment: .leading, spacing: 5) {
                    statusDetailRow("Modelo", value: runtime.modelName ?? runtime.providerName)
                    statusDetailRow("Backend", value: backendLabel)
                    statusDetailRow("Herramientas", value: "Archivos, Python (pocketpy 2.2.0), Web, Google, WDA\(isymcpStore.isPaired ? ", ISyMCP" : "")")
                    statusDetailRow("Conexión", value: isymcpStore.isPaired ? "Local + Tailscale (:8797)" : (loopback.loopbackVPNActive ? "LocalDevVPN (10.7.0.1)" : "Local en iPhone"))
                    statusDetailRow("Actividad reciente", value: recentSummary)
                }
                .font(.system(size: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(OCSpacing.md)
        .ocCard(radius: OCRadius.r14)
    }

    private func statusDetailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(OCColor.textFaint)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var suggestedPrompts: [(icon: String, tint: Color, text: String)] {
        [
            ("envelope.fill", OCColor.info, "Revisa mis últimos correos de Gmail"),
            ("calendar", OCColor.warning, "¿Qué eventos tengo hoy en mi agenda?"),
            store.sandboxLink != nil
                ? ("folder.fill", OCColor.agentBuild, "Explora el proyecto del sandbox y dime qué hace")
                : ("iphone", OCColor.success, "Revisa el estado de mi iPhone y qué hay en pantalla")
        ]
    }

    private var suggestedPromptsSection: some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            ForEach(suggestedPrompts, id: \.text) { item in
                Button {
                    sendPrompt(item.text)
                } label: {
                    HStack(spacing: OCSpacing.md) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(item.tint)
                            .frame(width: 24)
                        Text(item.text)
                            .font(.system(size: 14.5))
                            .foregroundColor(OCColor.textSecondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, OCSpacing.md)
                    .padding(.vertical, 10)
                    .background(OCColor.bgBase.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }
        }
    }

    private func assistantPill(runtime: RuntimeSelectionSnapshot) -> some View {
        let label: String
        if !runtime.readiness.isUsableForChat {
            label = "Configurar asistente"
        } else if assistant.developerMode, let model = runtime.modelName, !model.isEmpty {
            label = "Asistente · \(runtime.providerName) · \(model)"
        } else {
            label = "Asistente · \(runtime.providerName)"
        }

        return Button {
            router.openRuntimeSetup(track: runtime.isLocal ? .local : .connected, providerID: runtime.providerID)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(runtime.readiness.isUsableForChat ? OCColor.success : OCColor.warning)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(OCColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(OCColor.bgBase)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(OCColor.borderMuted, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-assistant-selector")
    }

    private var composerBar: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !store.sessionState.composerAttachments.isEmpty
        let canSend = !trimmed.isEmpty || hasAttachments
        let runtime = store.runtimeSnapshot
        let capabilityReport = MultimodalProviderCompatibility.evaluate(
            providerID: store.sessionState.selectedModel?.route ?? runtime.providerID,
            modelID: store.sessionState.selectedModel?.apiModelId ?? runtime.modelName,
            backendMode: store.backendMode
        )

        return VStack(spacing: 6) {
            DictationLiveStatusBar()
                .padding(.horizontal, OCSpacing.contentMargin)

            if hasAttachments {
                RichAttachmentsBar(
                    attachments: store.sessionState.composerAttachments,
                    capabilityReport: capabilityReport,
                    onInspect: { mediaCoordinator.inspectingAttachment = $0 },
                    onRemove: { store.removeAttachment($0) }
                )
                .padding(.horizontal, OCSpacing.contentMargin)
            }

            HStack(alignment: .bottom, spacing: OCSpacing.xs) {
                ComposerPlusMenuButton(coordinator: mediaCoordinator, includesWorkspaceFiles: false)

                TextField("Pregunta lo que quieras…", text: $draft, axis: .vertical)
                    .focused($isInputFocused)
                    .lineLimit(1...6)
                    .font(.system(size: 15.5))
                    .foregroundColor(OCColor.textPrimary)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .accessibilityIdentifier("chat-landing-input")

                DictationMicrophoneButton(targetText: $draft) {
                    isInputFocused = true
                }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(OCColor.onAccent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(IysThemePreferences.active.accent))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
                .opacity(!canSend || sending ? 0.35 : 1)
                .padding(4)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Enviar mensaje")
                .accessibilityIdentifier("chat-landing-send")
            }
            .padding(.leading, 4)
            .background(OCColor.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r24))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r24).stroke(OCColor.borderBase, lineWidth: 1))
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.bottom, OCSpacing.sm)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { isInputFocused = false }
            }
        }
        .multimodalComposerSupport(
            coordinator: mediaCoordinator,
            attachments: $store.sessionState.composerAttachments
        )
        .alert("Adjuntos", isPresented: Binding(
            get: { mediaCoordinator.statusError != nil },
            set: { if !$0 { mediaCoordinator.statusError = nil } }
        )) {
            Button("Entendido", role: .cancel) { mediaCoordinator.statusError = nil }
        } message: {
            Text(mediaCoordinator.statusError ?? "")
        }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !store.sessionState.composerAttachments.isEmpty
        guard (!trimmed.isEmpty || hasAttachments), !sending else { return }
        draft = ""
        sendPrompt(trimmed.isEmpty ? "Analiza los archivos adjuntos." : trimmed)
    }

    private func sendPrompt(_ prompt: String) {
        guard !sending else { return }
        sending = true
        isInputFocused = false
        Task {
            _ = await store.openOrCreateConversation(preferNew: true, initialPrompt: prompt)
            sending = false
        }
    }
}

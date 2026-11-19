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
    @State private var historyExpanded = false
    @State private var toolsExpanded = false
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

            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.md) {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        conversationsSection
                    } label: {
                        Label("Conversaciones", systemImage: "bubble.left.and.bubble.right")
                            .font(.headline)
                            .frame(minHeight: 44)
                    }
                    .padding(.horizontal, OCSpacing.lg)
                    .accessibilityIdentifier("sidebar-history")

                    destinationsSection
                }
                .padding(.bottom, OCSpacing.lg)
            }
            .refreshable { await store.refreshConversations() }

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
            Text("ISyCode")
                .font(.system(.callout, design: .rounded, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
                .foregroundColor(OCColor.textPrimary)
            Spacer()
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OCColor.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar barra lateral")
            }
        }
    }

    private var newConversationButton: some View {
        Button {
            router.openNewConversation()
            onClose()
        } label: {
            HStack(spacing: OCSpacing.sm) {
                Image(systemName: "plus.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Nueva conversación")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundColor(OCColor.onAccent)
            .padding(.horizontal, OCSpacing.md)
            .frame(minHeight: 44)
            .background(IysThemePreferences.active.accent.gradient)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-new-conversation")
    }

    private var conversationsSection: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if store.sessions.isEmpty {
                Text("Tus conversaciones aparecerán aquí.")
                    .font(.footnote)
                    .foregroundColor(OCColor.textFaint)
                    .padding(.horizontal, OCSpacing.lg)
                    .padding(.vertical, OCSpacing.sm)
            } else {
                ForEach(store.sessions) { session in
                    conversationRow(session)
                }
            }
        }
    }

    private func conversationRow(_ session: Session) -> some View {
        let isActive = router.activeDestination == .chat && !router.showsNewConversation && sessionState.currentSession?.id == session.id
        return Button {
            router.openConversations()
            onClose()
            Task {
                await store.selectSession(session)
            }
        } label: {
            HStack(spacing: OCSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.subheadline.weight(isActive ? .semibold : .medium))
                        .foregroundColor(OCColor.textPrimary)
                        .lineLimit(1)
                    Text(session.timestamp, style: .relative)
                        .environment(\.locale, Locale(identifier: "es"))
                        .font(.caption2)
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
            destinationButton(.myAgents, title: "Mis agentes", subtitle: nil)
            destinationButton(.builder, title: "Crear agente", subtitle: nil)

            DisclosureGroup(isExpanded: $toolsExpanded) {
                actionRow(title: "Flujos grabados", symbol: "record.circle", tint: OCColor.iconPrimary) {
                    router.openLearnAction()
                }
                actionRow(title: "Llavero", symbol: "key", tint: OCColor.iconPrimary) {
                    router.openSecretVault()
                }
                destinationButton(.browser, title: "Navegador", subtitle: nil)
                destinationButton(.projects, title: "Proyectos", subtitle: nil)
                destinationButton(.google, title: "Google Workspace", subtitle: nil)
            } label: {
                Label("Herramientas", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, OCSpacing.md)
            .accessibilityIdentifier("sidebar-tools")

            actionRow(title: "Memoria", symbol: "books.vertical", tint: OCColor.iconPrimary) {
                router.openGoogle(subtab: .memory)
            }
            actionRow(title: "Actividad", symbol: "clock", tint: OCColor.iconPrimary) {
                router.showActivitySheet = true
            }
            destinationButton(.connections, title: "Conexiones", subtitle: nil)
            actionRow(title: "Modelos", symbol: "cpu", tint: OCColor.iconPrimary) {
                let runtime = store.runtimeSnapshot
                router.openRuntimeSetup(track: runtime.isLocal ? .local : .connected, providerID: runtime.providerID)
            }
            destinationButton(.settings, title: "Ajustes", subtitle: nil)
        }
        .padding(.horizontal, OCSpacing.sm)
    }

    private func destinationButton(_ destination: AppShellDestination, title: String, subtitle: String?) -> some View {
        let isActive = router.activeDestination == destination && (destination != .google || router.googleSubtab == .google)
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
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isActive ? IysThemePreferences.active.accent : OCColor.iconPrimary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(isActive ? .semibold : .medium))
                        .foregroundColor(OCColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(isActive ? IysThemePreferences.active.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("sidebar-dest-\(destination.rawValue)")
    }

    /// A row for an action that opens a sheet (not a destination), same size as the others.
    private func actionRow(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            OCHaptics.light()
            action()
            onClose()
        } label: {
            HStack(spacing: OCSpacing.md) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, OCSpacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @EnvironmentObject private var sessionState: ActiveSessionState
    private var landingAttachments: Binding<[Attachment]> { sessionState.attachments(for: .landing) }
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var contractStore = AgentContractStore.shared
    @ObservedObject private var isymcpStore = ISyMCPStore.shared
    @ObservedObject private var loopback = LoopbackDeviceSession.shared
    @State private var showStartError = false
    @State private var sending = false
    @State private var showSystemDetails = false
    @State private var showGUSAssistant = false
    @StateObject private var mediaCoordinator = MultimodalComposerCoordinator()
    @FocusState private var isInputFocused: Bool
    @State private var showTools = false
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

                    conversationActions

                    if showTools { compactSystemStatusCard(runtime: runtime) }

                    if router.landingDraft.isEmpty { suggestedPromptsSection }
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
                        .font(.body.weight(.semibold))
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
                                .font(.footnote.weight(.bold))
                            Text("GUS")
                                .font(.caption.weight(.semibold))
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
                            .font(.callout.weight(.medium))
                            .foregroundColor(OCColor.iconPrimary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Ajustes")
                }
            }
        }
        .alert("No se pudo abrir la conversación", isPresented: $showStartError) {
            Button("Volver al borrador") { isInputFocused = true }
        } message: {
            Text("Tu mensaje sigue en el compositor. Revisa la conexión y vuelve a enviarlo.")
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
            Text("Nueva conversación")
                .font(.title2.weight(.bold))
                .foregroundColor(OCColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            OCFlowLayout(spacing: 8, lineSpacing: 8) {
                assistantPill(runtime: runtime)
                if let link = store.sandboxLink {
                    Button {
                        router.showSandboxExplanationSheet = true
                    } label: {
                        Label(link.projectName, systemImage: "shippingbox.fill")
                            .font(.caption.weight(.medium))
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
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text("\(agent.enabledL0Tools.count + agent.l1Tools.count) herramientas · \(agent.preferredBackend.shortLabel)")
                    .font(.caption2)
                    .foregroundColor(OCColor.textFaint)
            }
            Spacer()
            Button("Desactivar") {
                contractStore.activeAgentForSession = nil
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(IysThemePreferences.active.accent)
        }
        .padding(10)
        .ocCard(radius: OCRadius.r12, border: Color(hex: agent.accentHex).opacity(0.4))
    }

    private var conversationActions: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            if let session = store.sessions.max(by: { $0.timestamp < $1.timestamp }) {
                secondaryActionRow(
                    title: "Retomar conversación",
                    subtitle: session.title,
                    symbol: "bubble.left",
                    tint: IysThemePreferences.active.accent,
                    id: "home-action-chat"
                ) {
                    OCHaptics.light()
                    Task {
                        await store.selectSession(session)
                        router.openConversations()
                    }
                }
            }

            DisclosureGroup(isExpanded: $showTools) {
                secondaryActionsGroup
            } label: {
                Label("Herramientas", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(OCColor.textPrimary)
                    .frame(minHeight: 44)
            }
            .tint(OCColor.textSecondary)
        }
    }

    private var secondaryActionsGroup: some View {
        VStack(spacing: 0) {
            secondaryActionRow(
                title: "Crear agente",
                subtitle: "Configura sus instrucciones y herramientas",
                symbol: "hammer",
                tint: OCColor.textSecondary,
                id: "home-action-build"
            ) {
                OCHaptics.light()
                router.openBuilder()
            }
            Divider().overlay(OCColor.borderMuted).padding(.leading, 52)
            secondaryActionRow(
                title: "Mis agentes",
                subtitle: contractStore.agents.isEmpty
                    ? "Administra tus agentes y contratos"
                    : "\(contractStore.agents.count) \(contractStore.agents.count == 1 ? "agente listo" : "agentes listos")",
                symbol: "square.stack.3d.up.fill",
                tint: OCColor.success,
                id: "home-action-agents"
            ) {
                OCHaptics.light()
                router.openMyAgents()
            }
            Divider().overlay(OCColor.borderMuted).padding(.leading, 52)
            secondaryActionRow(
                title: "Aprender acción",
                subtitle: "Graba un flujo en el iPhone",
                symbol: "record.circle",
                tint: OCColor.danger,
                id: "home-action-learn"
            ) {
                OCHaptics.medium()
                router.openLearnAction()
            }
            Divider().overlay(OCColor.borderMuted).padding(.leading, 52)
            secondaryActionRow(
                title: "Llavero",
                subtitle: "Claves protegidas con Face ID",
                symbol: "key.fill",
                tint: OCColor.warning,
                id: "home-action-vault"
            ) {
                OCHaptics.light()
                router.openSecretVault()
            }
        }
        .ocCard(radius: OCRadius.r14, border: OCColor.borderMuted, background: OCColor.bgBase)
    }

    /// A list row (icon, title, subtitle, chevron) for tools used less often than
    /// chatting or building.
    private func secondaryActionRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: OCSpacing.md) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: OCRadius.r8).fill(tint.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(OCColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(OCColor.iconMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.vertical, OCSpacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                // It said "Sistema listo" even with "Motor sin configurar" right below it.
                Text(runtime.readiness.isUsableForChat ? "Listo · \(backendLabel)" : "Falta elegir un motor · \(backendLabel)")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
                Button {
                    withAnimation(OCMotion.snappy) {
                        showSystemDetails.toggle()
                    }
                } label: {
                    Label(showSystemDetails ? "Ocultar" : "Detalles", systemImage: showSystemDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(OCColor.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if showSystemDetails {
                OCFlowLayout(spacing: 12, lineSpacing: 4) {
                    Label(runtime.providerName, systemImage: "cpu")
                    Label("Python local", systemImage: "terminal")
                    Label(isymcpStore.isPaired ? "ISyMCP OK" : "Solo iPhone", systemImage: isymcpStore.isPaired ? "desktopcomputer" : "iphone")
                }
                .font(.caption2)
                .foregroundColor(OCColor.textFaint)
                .lineLimit(1)

                Divider().overlay(OCColor.borderMuted)
                VStack(alignment: .leading, spacing: 5) {
                    statusDetailRow("Modelo", value: runtime.modelName ?? runtime.providerName)
                    statusDetailRow("Backend", value: backendLabel)
                    statusDetailRow("Herramientas", value: "Archivos, Python (pocketpy 2.2.0), Web, Google, WDA\(isymcpStore.isPaired ? ", ISyMCP" : "")")
                    statusDetailRow("Conexión", value: isymcpStore.isPaired ? "Local + Tailscale (:8797)" : (loopback.loopbackVPNActive ? "LocalDevVPN (10.7.0.1)" : "Local en iPhone"))
                    statusDetailRow("Actividad reciente", value: recentSummary)
                }
                .font(.caption)
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
                    router.landingDraft = item.text
                    isInputFocused = true
                } label: {
                    HStack(spacing: OCSpacing.md) {
                        Image(systemName: item.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(item.tint)
                            .frame(width: 24)
                        Text(item.text)
                            .font(.subheadline)
                            .foregroundColor(OCColor.textSecondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, OCSpacing.md)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
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
                    .font(.footnote.weight(.medium))
                    .foregroundColor(OCColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
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
        let trimmed = router.landingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !landingAttachments.wrappedValue.isEmpty
        let canSend = (!trimmed.isEmpty || hasAttachments) && landingAttachments.wrappedValue.allSatisfy { $0.state.isReady }
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
                    attachments: landingAttachments.wrappedValue,
                    capabilityReport: capabilityReport,
                    onInspect: { mediaCoordinator.inspectingAttachment = $0 },
                    onRemove: { store.removeAttachment($0, from: landingAttachments) }
                )
                .padding(.horizontal, OCSpacing.contentMargin)
            }

            HStack(alignment: .bottom, spacing: OCSpacing.xs) {
                // Same "+" sheet as inside a chat. The model picker only exists in a chat, so
                // here "Modelo" opens the engine setup.
                ComposerOptionsButton(
                    coordinator: mediaCoordinator,
                    agentMode: $store.sessionState.agentMode,
                    flowMode: $store.sessionState.flowMode,
                    availableModes: AgentMode.allCases,
                    modelName: runtime.modelName ?? runtime.providerName,
                    onModelTap: {
                        router.openRuntimeSetup(track: runtime.isLocal ? .local : .connected, providerID: runtime.providerID)
                    }
                )

                TextField("Pregunta lo que quieras…", text: $router.landingDraft, axis: .vertical)
                    .focused($isInputFocused)
                    .lineLimit(1...6)
                    .font(.subheadline)
                    .foregroundColor(OCColor.textPrimary)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .accessibilityIdentifier("chat-landing-input")

                DictationMicrophoneButton(targetText: $router.landingDraft) {
                    isInputFocused = true
                }

                Button(action: send) {
                    // Same rule as the chat composer: disabled is a gray disc, not a
                    // faded accent that still looks pressable.
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(canSend && !sending ? OCColor.onAccent : OCColor.iconMuted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend && !sending ? IysThemePreferences.active.accent : OCColor.bgLayer2))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
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
            attachments: landingAttachments,
            workspaceSheet: { AnyView(AttachmentsSheet(attachments: landingAttachments).environmentObject(store)) }
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
        let trimmed = router.landingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !landingAttachments.wrappedValue.isEmpty
        guard (!trimmed.isEmpty || hasAttachments), landingAttachments.wrappedValue.allSatisfy({ $0.state.isReady }), !sending else { return }
        sendPrompt(trimmed.isEmpty ? "Analiza los archivos adjuntos." : trimmed)
    }

    private func sendPrompt(_ prompt: String) {
        guard !sending else { return }
        sending = true
        isInputFocused = false
        let originalDraft = router.landingDraft
        let selectedAttachments = landingAttachments.wrappedValue
        Task {
            if await store.openOrCreateConversation(preferNew: true, initialPrompt: prompt, landingAttachments: selectedAttachments) {
                router.showsNewConversation = false
                if router.landingDraft == originalDraft { router.landingDraft = "" }
            } else {
                showStartError = true
            }
            sending = false
        }
    }
}

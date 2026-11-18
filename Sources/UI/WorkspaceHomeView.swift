import SwiftUI

/// Persistent workspace hub ("Inicio") that composes runtime readiness,
/// session continuation, connections, quick actions, and recent activity into one entry screen.
public struct WorkspaceHomeView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @Environment(\.openURL) private var openURL

    @State private var quickPrompt = ""
    @State private var startingConversation = false

    public init() {}

    private var runtime: RuntimeSelectionSnapshot { store.runtimeSnapshot }
    private var googleState: GoogleConnectionState { assistant.googleConnectionState }
    private var hostState: HostConnectionState {
        ConnectionStatusEvaluator.evaluateHost(
            backendMode: store.backendMode,
            connectionHealth: store.connectionHealth,
            remoteProviderName: store.activeRemoteProviderDisplayName,
            sandboxLink: store.sandboxLink,
            hostLiveness: hostStore.hostLiveness,
            heartbeatState: hostStore.heartbeatState,
            monitorStatus: assistant.monitorStatus
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OCSpacing.xl) {
                headerAndConnectionBar
                if let message = assistant.message {
                    homeNoticeBanner(message)
                }
                pendingConfirmationBanner
                continueCard
                runtimeCard
                quickActionsSection
                recentActivitySection
            }
            .padding(OCSpacing.contentMargin)
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle("Inicio")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("home-root")
    }

    // MARK: - 1. Header & Connection Status Bar

    private var headerAndConnectionBar: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            // The large "Inicio" title already names the screen: no second "Centro de
            // trabajo" title. A greeting only when we know the person's name.
            VStack(alignment: .leading, spacing: 4) {
                if let name = assistant.email?.split(separator: "@").first.map(String.init), !name.isEmpty {
                    Text("Hola, \(name)")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(OCColor.textPrimary)
                }
                Label("Nada sale de tu iPhone sin tu confirmación.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Wraps to a second line instead of hiding the third chip off-screen ("Eq…").
            OCFlowLayout(spacing: OCSpacing.base, lineSpacing: OCSpacing.base) {
                statusPill(
                    text: "Motor: \(runtime.readiness.badgeText)",
                    symbol: runtime.readiness.symbol,
                    tone: runtime.readiness.tone,
                    id: "status-pill-runtime"
                ) {
                    router.openRuntimeSetup(track: runtime.isLocal ? .local : .connected, providerID: runtime.providerID)
                }

                statusPill(
                    text: googleState.shortChipText,
                    symbol: googleState.symbol,
                    tone: googleState.tone,
                    id: "status-pill-google"
                ) {
                    switch googleState {
                    case .needsClientID:
                        router.showGoogleOAuthSetupSheet = true
                    case .notConnected, .expired:
                        router.openGoogle(subtab: .google)
                    case .readOnly, .connected:
                        router.openGoogle(subtab: .google)
                    }
                }

                statusPill(
                    text: hostState.shortChipText,
                    symbol: hostState.symbol,
                    tone: hostState.tone,
                    id: "status-pill-host"
                ) {
                    router.openSettings()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("home-connection-bar")
        }
    }

    private func statusPill(
        text: String,
        symbol: String,
        tone: ConnectionBadgeTone,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tone.semanticColor)
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(OCColor.bgBase))
            .overlay(Capsule().stroke(tone.semanticColor.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func homeNoticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(IysThemePreferences.active.accent)
            Text(text)
                .font(.footnote)
                .foregroundColor(OCColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { assistant.message = nil } label: {
                Image(systemName: "xmark")
                    .foregroundColor(OCColor.textSecondary)
            }
            .accessibilityLabel("Cerrar aviso")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: OCRadius.r12).fill(OCColor.agentBuildSoft))
    }

    @ViewBuilder
    private var pendingConfirmationBanner: some View {
        if let pending = assistant.pending {
            let formatted = HumanConfirmationFormatter.format(action: pending)
            Button {
                // AssistantConfirmActionSheet is presented at AppShell level when assistant.pending != nil;
                // tapping reinforces visibility or triggers review if dismissed.
                assistant.pending = pending
            } label: {
                HStack(spacing: OCSpacing.md) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundColor(OCColor.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confirmación pendiente")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(OCColor.warning)
                        Text(formatted.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(OCColor.textPrimary)
                    }
                    Spacer()
                    Text("Revisar")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(OCColor.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OCColor.warning))
                }
                .padding(OCSpacing.md)
                .background(RoundedRectangle(cornerRadius: OCRadius.r14).fill(OCColor.warning.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.warning.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-pending-confirmation")
        } else if let permission = sessionState.pendingPermission {
            let formatted = HumanConfirmationFormatter.format(permission: permission)
            Button {
                router.openConversations()
            } label: {
                HStack(spacing: OCSpacing.md) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title3)
                        .foregroundColor(OCColor.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permiso pendiente en conversación")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(OCColor.warning)
                        Text(formatted.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(OCColor.textPrimary)
                    }
                    Spacer()
                    Text("Abrir")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(OCColor.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OCColor.warning))
                }
                .padding(OCSpacing.md)
                .background(RoundedRectangle(cornerRadius: OCRadius.r14).fill(OCColor.warning.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.warning.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-pending-permission")
        }
    }

    // MARK: - 2. Continue Where You Left Off + Quick Prompt

    private var continueCard: some View {
        let activeSessionTitle = sessionState.currentSession?.title ?? store.lastSessionTitle
        let activeProjectTitle = sessionState.currentProject?.name ?? store.lastProjectName

        // One primary action: type what you need. Continuing the last conversation is a
        // secondary row, and "Nueva conversación" a text button (it used to be a second
        // filled capsule with the same weight, plus a duplicate tile in the grid).
        return VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(activeSessionTitle?.isEmpty == false ? "¿Qué sigue?" : "Empieza una conversación")
                    .font(.headline)
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
                if startingConversation {
                    ProgressView().controlSize(.small)
                }
            }

            if activeSessionTitle?.isEmpty != false {
                Text(runtime.readiness.isUsableForChat
                     ? "Tu motor (\(runtime.providerName)) ya está listo."
                     : "Configura un motor abajo o prueba el guion de demo.")
                    .font(.footnote)
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: OCSpacing.sm) {
                TextField("¿Qué necesitas? Ej. revisa mi agenda o pregunta a GUS", text: $quickPrompt)
                    .font(.subheadline)
                    .foregroundColor(OCColor.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: OCRadius.r12).fill(OCColor.bgLayer1))
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderMuted, lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit { submitQuickPrompt() }
                    .accessibilityIdentifier("home-quick-prompt")

                Button(action: submitQuickPrompt) {
                    Image(systemName: "arrow.up")
                        .font(.callout.weight(.bold))
                        .foregroundColor(quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OCColor.textFaint : OCColor.onAccent)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(
                                quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? OCColor.bgLayer2
                                    : IysThemePreferences.active.accent
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || startingConversation)
                .accessibilityLabel("Enviar")
                .accessibilityIdentifier("home-quick-prompt-send")
            }

            if let activeSessionTitle, !activeSessionTitle.isEmpty {
                Button {
                    continueLastConversation()
                } label: {
                    HStack(spacing: OCSpacing.md) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.subheadline)
                            .foregroundColor(IysThemePreferences.active.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continuar: \(activeSessionTitle)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(OCColor.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let activeProjectTitle, !activeProjectTitle.isEmpty {
                                Text(activeProjectTitle)
                                    .font(.caption)
                                    .foregroundColor(OCColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(OCColor.iconMuted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, OCSpacing.lg)
                    .padding(.vertical, OCSpacing.md)
                    .frame(minHeight: 44)
                    .background(OCColor.bgLayer1)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(startingConversation)
                .accessibilityIdentifier("home-continue-button")
            }

            Button {
                startNewConversation()
            } label: {
                Label("Nueva conversación", systemImage: "plus.bubble")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(IysThemePreferences.active.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(startingConversation)
            .accessibilityIdentifier("home-new-chat-button")
        }
        .padding(OCSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCard(radius: OCRadius.r22, border: OCColor.borderMuted, background: OCColor.bgBase)
        .accessibilityIdentifier("home-continue-card")
    }

    // MARK: - 3. Active AI Engine Card (Local vs Connected)

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MOTOR DE IA")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                    Text(runtime.providerName)
                        .font(.headline)
                        .foregroundColor(OCColor.textPrimary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: runtime.readiness.symbol)
                        .font(.caption.weight(.semibold))
                    Text(runtime.readiness.badgeText)
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(runtime.readiness.tone.semanticColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(runtime.readiness.tone.semanticColor.opacity(0.14)))
            }

            Text(runtime.runtimeSummaryLine)
                .font(.footnote)
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let verifiedAt = runtime.lastVerifiedAt {
                Text("Verificado \(verifiedAt.formatted(.relative(presentation: .named)))")
                    .environment(\.locale, Locale(identifier: "es"))
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
            }

            if runtime.readiness == .notConfigured {
                HStack(spacing: OCSpacing.base) {
                    mentalModelCard(
                        title: "Local en iPhone",
                        detail: "Privado y sin internet",
                        symbol: "iphone",
                        id: "home-setup-local-card"
                    ) {
                        router.openRuntimeSetup(track: .local, providerID: "gus-local")
                    }
                    mentalModelCard(
                        title: "Proveedor conectado",
                        detail: "NVIDIA, OpenAI, xAI…",
                        symbol: "cloud",
                        id: "home-setup-cloud-card"
                    ) {
                        router.openRuntimeSetup(track: .connected, providerID: "nvidia")
                    }
                }
            } else {
                HStack(spacing: OCSpacing.base) {
                    Button {
                        handleRuntimePrimaryCTA()
                    } label: {
                        Text(runtime.primaryCTATitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(OCColor.onAccent)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 42)
                            .background(Capsule().fill(IysThemePreferences.active.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(runtime.readiness == .checking || startingConversation)
                    .accessibilityIdentifier("home-runtime-cta")

                    Button {
                        router.openRuntimeSetup(
                            track: runtime.isLocal ? .local : .connected,
                            providerID: runtime.providerID
                        )
                    } label: {
                        Text("Cambiar motor")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(OCColor.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 42)
                            .background(Capsule().fill(OCColor.bgLayer1))
                            .overlay(Capsule().stroke(OCColor.borderMuted, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-change-runtime-button")
                }
            }
        }
        .padding(OCSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCard(radius: OCRadius.r18)
        .accessibilityIdentifier("home-runtime-card")
    }

    private func mentalModelCard(
        title: String,
        detail: String,
        symbol: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundColor(IysThemePreferences.active.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(OCSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OCColor.bgLayer1)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - 4. Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            Text("Acciones rápidas")
                .font(.headline)
                .foregroundColor(OCColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // "Nueva conversación" and "Cambiar motor" were tiles too, repeating the card
            // above and the engine card: the grid keeps only actions found nowhere else.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                workspaceTile(
                    title: "Abrir proyecto",
                    subtitle: store.projects.isEmpty ? "Espacio de trabajo" : "\(store.projects.count) disponible(s)",
                    symbol: "folder.fill",
                    badge: nil,
                    id: "quick-action-projects"
                ) {
                    router.openProjects()
                }

                workspaceTile(
                    title: googleState.isAuthorizedSession ? "Google conectado" : "Conectar Google",
                    subtitle: googleState.badgeText,
                    symbol: "person.crop.circle.badge.checkmark",
                    badge: googleState.isAuthorizedSession ? nil : googleState.primaryCTATitle,
                    id: "quick-action-google"
                ) {
                    switch googleState {
                    case .needsClientID:
                        router.showGoogleOAuthSetupSheet = true
                    case .notConnected, .expired:
                        router.openGoogle(subtab: .google)
                        assistant.signIn()
                    case .readOnly, .connected:
                        router.openGoogle(subtab: .google)
                    }
                }

                ForEach(AssistantCatalog.quickActions) { action in
                    let availability = ConnectionStatusEvaluator.availability(
                        for: action,
                        googleState: googleState,
                        grantedScopes: assistant.grantedScopes
                    )
                    workspaceTile(
                        title: action.title,
                        subtitle: availability.isReady ? action.subtitle : (availability.blockedReason ?? action.subtitle),
                        symbol: action.symbol,
                        badge: availability.isReady ? nil : availability.ctaTitle,
                        id: "quick-action-\(action.id)"
                    ) {
                        if let target = availability.target {
                            router.handle(target, assistant: assistant)
                        } else if let query = assistant.run(action) {
                            openMaps(query)
                        } else if action.kind == .saveMemory {
                            router.openGoogle(subtab: .memory)
                        } else {
                            router.openGoogle(subtab: .google)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("home-quick-actions")
    }

    private func workspaceTile(
        title: String,
        subtitle: String,
        symbol: String,
        badge: String?,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(IysThemePreferences.active.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(OCColor.agentBuildSoft))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(OCColor.warning)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(OCColor.warning.opacity(0.14)))
                            .lineLimit(1)
                    }
                }

                // Title and subtitle reserve their lines, so every tile in the grid has
                // the same height whatever the text ("Aprender acción" vs "Llavero").
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(OCColor.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .ocCard(radius: OCRadius.r18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - 5. Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: OCSpacing.md) {
            HStack {
                Text("Actividad reciente")
                    .font(.headline)
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
                if assistant.developerMode && !assistant.logs.isEmpty {
                    Button("Ver registro") {
                        router.openGoogle(subtab: .log)
                    }
                    .font(.footnote.weight(.medium))
                }
            }

            if assistant.feed.isEmpty && store.runtimeSnapshot.readiness.errorDetail == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aún no hay actividad reciente")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Text("Aquí verás tus respuestas, avisos del daemon de tu PC y confirmaciones ejecutadas.")
                        .font(.footnote)
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(OCSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ocCard(radius: OCRadius.r14)
            } else {
                if let err = runtime.readiness.errorDetail {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(OCColor.danger)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Error del motor")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(OCColor.textPrimary)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(OCColor.textSecondary)
                            Button("Reintentar") {
                                Task { await store.retryRuntimeConnection() }
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.top, 2)
                        }
                    }
                    .padding(OCSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ocCard(radius: OCRadius.r14, border: OCColor.danger.opacity(0.45))
                }

                ForEach(assistant.feed.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.source)
                                .font(OCTypography.metaMono)
                                .foregroundColor(IysThemePreferences.active.accent)
                            Spacer()
                            Text(item.time, style: .relative)
                                .font(.caption)
                                .foregroundColor(OCColor.textFaint)
                        }
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(OCColor.textPrimary)
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.footnote)
                                .foregroundColor(OCColor.textSecondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(OCSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ocCard(radius: OCRadius.r14)
                }
            }
        }
        .accessibilityIdentifier("home-recent-activity")
    }

    // MARK: - Actions

    private func handleRuntimePrimaryCTA() {
        switch runtime.readiness {
        case .ready, .demo:
            continueLastConversation()
        case .needsModel:
            router.openRuntimeSetup(track: .local, providerID: "gus-local")
        case .needsKey, .notConfigured:
            router.openRuntimeSetup(track: .connected, providerID: runtime.providerID ?? "nvidia")
        case .error:
            Task { await store.retryRuntimeConnection() }
        case .checking:
            break
        }
    }

    private func continueLastConversation() {
        startingConversation = true
        Task {
            let ok = await store.openOrCreateConversation(preferNew: false)
            startingConversation = false
            if ok { router.openConversations() }
        }
    }

    private func startNewConversation() {
        startingConversation = true
        Task {
            let ok = await store.openOrCreateConversation(preferNew: true)
            startingConversation = false
            if ok { router.openConversations() }
        }
    }

    private func submitQuickPrompt() {
        let text = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let tools = AssistantCatalog.selectTools(text)
        if let first = tools.first {
            if first == AssistantCatalog.mapsSearch {
                quickPrompt = ""
                openMaps(text)
                return
            }
            if first == AssistantCatalog.saveContext {
                quickPrompt = ""
                _ = assistant.ask(text)
                return
            }
            if let info = AssistantCatalog.tool(first), let service = info.service {
                let availability = ConnectionStatusEvaluator.availability(
                    forService: service,
                    mode: info.mode,
                    googleState: googleState,
                    grantedScopes: assistant.grantedScopes
                )
                if let target = availability.target {
                    assistant.message = availability.blockedReason
                    router.handle(target, assistant: assistant)
                    return
                }
                quickPrompt = ""
                _ = assistant.ask(text)
                router.openGoogle(subtab: .google)
                return
            }
        }

        // Send directly into a live GUS conversation without routing through Sandbox/Settings!
        let promptToSend = text
        quickPrompt = ""
        startingConversation = true
        Task {
            let ok = await store.openOrCreateConversation(preferNew: sessionState.currentSession == nil, initialPrompt: promptToSend)
            startingConversation = false
            if ok { router.openConversations() }
        }
    }

    private func openMaps(_ query: String) {
        let text = query.isEmpty ? "cerca de mí" : query
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?q=\(encoded)") { openURL(url) }
    }
}

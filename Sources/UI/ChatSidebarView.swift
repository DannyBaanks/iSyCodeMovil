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
            destinationButton(.google, title: "Google", subtitle: "Correo, agenda, Drive")
            destinationButton(.projects, title: "Proyectos", subtitle: nil)
            destinationButton(.connections, title: "Conexiones", subtitle: "Computadora e iPhone")
            destinationButton(.settings, title: "Ajustes", subtitle: nil)
        }
        .padding(.horizontal, OCSpacing.sm)
    }

    private func destinationButton(_ destination: AppShellDestination, title: String, subtitle: String?) -> some View {
        let isActive = router.activeDestination == destination
        return Button {
            switch destination {
            case .chat: router.openConversations()
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

/// Clean ChatGPT/Claude-style landing view when no conversation is active yet.
public struct ChatLandingView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var isInputFocused: Bool
    let onOpenSidebar: () -> Void

    public init(onOpenSidebar: @escaping () -> Void) {
        self.onOpenSidebar = onOpenSidebar
    }

    public var body: some View {
        let runtime = store.runtimeSnapshot
        return VStack(spacing: 0) {
            Spacer(minLength: OCSpacing.lg)

            VStack(spacing: OCSpacing.md) {
                Text("¿En qué te ayudo?")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(OCColor.textPrimary)
                    .multilineTextAlignment(.center)

                assistantPill(runtime: runtime)

                if let link = store.sandboxLink {
                    Button {
                        router.showSandboxExplanationSheet = true
                    } label: {
                        Label("Sandbox activo en \(link.projectName) · ¿Qué es?", systemImage: "shippingbox.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(OCColor.agentBuild)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(OCColor.agentBuildSoft)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(OCColor.agentBuildBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OCSpacing.contentMargin)

            Spacer(minLength: OCSpacing.lg)

            suggestedPromptsSection
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.bottom, OCSpacing.md)

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
                Button {
                    router.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Ajustes")
            }
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
        return HStack(alignment: .bottom, spacing: OCSpacing.xs) {
            TextField("Pregunta lo que quieras…", text: $draft, axis: .vertical)
                .focused($isInputFocused)
                .lineLimit(1...6)
                .font(.system(size: 15.5))
                .foregroundColor(OCColor.textPrimary)
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .submitLabel(.send)
                .onSubmit { send() }
                .accessibilityIdentifier("chat-landing-input")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(OCColor.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(IysThemePreferences.active.accent))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty || sending)
            .opacity(trimmed.isEmpty || sending ? 0.35 : 1)
            .padding(4)
            .accessibilityLabel("Enviar mensaje")
            .accessibilityIdentifier("chat-landing-send")
        }
        .background(OCColor.bgBase)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r24))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r24).stroke(OCColor.borderBase, lineWidth: 1))
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.bottom, OCSpacing.sm)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { isInputFocused = false }
            }
        }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        draft = ""
        sendPrompt(trimmed)
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

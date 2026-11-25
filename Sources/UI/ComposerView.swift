import SwiftUI

// MARK: - Composer View

public struct ComposerView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState

    public init() {}

    public var body: some View {
        if let session = sessionState.currentSession {
            ConversationComposer(draft: sessionState.draft(for: session), attachments: sessionState.attachments(for: .init(session)))
                .id(session.id)
        }
    }
}

private struct ConversationComposer: View {
    @ObservedObject var draft: ConversationDraft
    @Binding var attachments: [Attachment]
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @StateObject private var mediaCoordinator = MultimodalComposerCoordinator()
    @FocusState private var isFocused: Bool

    public var body: some View {
        let runtime = store.runtimeSnapshot
        let capabilityReport = MultimodalProviderCompatibility.evaluate(
            providerID: sessionState.selectedModel?.route ?? runtime.providerID,
            modelID: sessionState.selectedModel?.apiModelId ?? runtime.modelName,
            backendMode: store.backendMode
        )
        return VStack(spacing: 0) {
            if store.gusDualSmolActive {
                HStack {
                    Label("Dual-Smol · experimental", systemImage: "sparkles")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(IysThemePreferences.active.accent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OCSpacing.lg)
                .padding(.top, OCSpacing.xs)
            }

            DictationLiveStatusBar()
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.xs)

            // Attachments preview row (photos, camera, PDF/docs with live state)
            if !attachments.isEmpty {
                RichAttachmentsBar(
                    attachments: attachments,
                    capabilityReport: capabilityReport,
                    onInspect: { mediaCoordinator.inspectingAttachment = $0 },
                    onRemove: { store.removeAttachment($0, from: $attachments) }
                )
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Input area
            HStack(alignment: .bottom, spacing: OCSpacing.xs) {
                ComposerOptionsButton(
                    coordinator: mediaCoordinator,
                    agentMode: $sessionState.agentMode,
                    flowMode: $sessionState.flowMode,
                    availableModes: availableModes,
                    modelName: sessionState.selectedModel?.name,
                    onModelTap: { sessionState.showModelPicker = true }
                )

                TextField(
                    "",
                    text: $draft.text,
                    prompt: Text(composerPlaceholder)
                        .foregroundColor(OCColor.textFaint),
                    axis: .vertical
                )
                .font(OCTypography.body)
                .foregroundColor(OCColor.textPrimary)
                .accessibilityLabel("Mensaje")
                .accessibilityIdentifier("chat-composer-input")
                .focused($isFocused)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit { handleSend() }
                .padding(.horizontal, OCSpacing.xs)
                .padding(.vertical, OCSpacing.sm)
                .frame(minHeight: 42)

                DictationMicrophoneButton(targetText: $draft.text) {
                    isFocused = true
                }

                // Send/Stop button
                SendStopButton(
                    isProcessing: sessionState.isProcessing,
                    canSend: canSend,
                    agentColor: sessionState.agentMode.color
                ) {
                    if sessionState.isProcessing {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        NotificationCenter.default.post(name: .composerStop, object: nil)
                    } else {
                        handleSend()
                    }
                }
            }
            .padding(.horizontal, OCSpacing.base)
            .padding(.vertical, OCSpacing.xs)

            // Control row
            ComposerControlRow(
                agentMode: sessionState.agentMode,
                onAgentTap: { sessionState.showAgentPicker = true },
                selectedModel: sessionState.selectedModel,
                onModelTap: { sessionState.showModelPicker = true },
                onAttachTap: { mediaCoordinator.showWorkspaceSheet = true },
                showsAttachButton: false,
                flowMode: $sessionState.flowMode,
                codexMode: sessionState.selectedModel?.route == "codex",
                limitedLabel: sessionState.selectedModel?.route == "grok" ? "Grok · en tu computadora" : nil
            )
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.bottom, OCSpacing.base)
        }
        .background(
            RoundedRectangle(cornerRadius: OCRadius.r24)
                .fill(OCColor.bgBase.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: OCRadius.r24)
                        .stroke(OCColor.borderBase, lineWidth: 1)
                )
                .shadow(color: OCShadow.composer.color, radius: OCShadow.composer.radius, x: OCShadow.composer.x, y: OCShadow.composer.y)
        )
        .padding(.horizontal, OCSpacing.compactMargin)
        .padding(.bottom, OCSpacing.compactMargin)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { isFocused = false }
            }
        }
        .onAppear {
            if !sessionState.composerText.isEmpty && draft.text.isEmpty {
                draft.text = sessionState.composerText
                sessionState.composerText = ""
            }
        }
        .onChange(of: sessionState.composerText) { incoming in
            if !incoming.isEmpty {
                draft.text = incoming
                sessionState.composerText = ""
            }
        }
        .multimodalComposerSupport(
            coordinator: mediaCoordinator,
            attachments: $attachments,
            workspaceSheet: {
                AnyView(
                    AttachmentsSheet(attachments: $attachments)
                        .environmentObject(store)
                        .environmentObject(sessionState)
                )
            }
        )
        .onChange(of: sessionState.showAttachments) { open in
            if open {
                mediaCoordinator.showWorkspaceSheet = true
                sessionState.showAttachments = false
            }
        }
        .alert("Adjuntos", isPresented: Binding(
            get: { mediaCoordinator.statusError != nil },
            set: { if !$0 { mediaCoordinator.statusError = nil } }
        )) {
            Button("Entendido", role: .cancel) { mediaCoordinator.statusError = nil }
        } message: {
            Text(mediaCoordinator.statusError ?? "")
        }
    }

    private func handleSend() {
        guard !sessionState.isProcessing, canSend else { return }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        OCHaptics.sent()
        let outgoing = draft.text
        draft.submittedText = outgoing
        isFocused = false
        NotificationCenter.default.post(name: .composerSend, object: outgoing)
    }

    /// Same list the agent picker uses: the remote server's agents, else every mode.
    private var availableModes: [AgentMode] {
        if store.backendMode == .remote, !store.availableAgents.isEmpty {
            return store.availableAgents.compactMap { AgentMode(rawValue: $0) }
        }
        return AgentMode.allCases
    }

    private var canSend: Bool {
        guard store.currentBackend != nil, !attachments.contains(where: {
            switch $0.state {
            case .preparing, .selected: return true
            default: return false
            }
        }) else { return false }
        return !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var composerPlaceholder: String {
        if store.backendMode == .native { return "Escribe a iSyCode…" }
        switch sessionState.selectedModel?.route {
        case "codex": return "Escribe a Codex…"
        case "grok": return "Escribe a Grok…"
        default: return "Escribe a OpenCode…"
        }
    }
}

// MARK: - Send/Stop Button

public struct SendStopButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isProcessing: Bool
    let canSend: Bool
    let agentColor: Color
    let action: () -> Void

    public init(isProcessing: Bool, canSend: Bool, agentColor: Color, action: @escaping () -> Void) {
        self.isProcessing = isProcessing
        self.canSend = canSend
        self.agentColor = agentColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(isProcessing ? false : !canSend)
        .frame(width: 44, height: 44)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .accessibilityLabel(isProcessing ? "Detener" : "Enviar")
        .animation(reduceMotion ? nil : OCMotion.snappy, value: isProcessing)
        .animation(reduceMotion ? nil : OCMotion.snappy, value: canSend)
    }

    /// Disabled reads as disabled: a neutral gray disc, not a faded accent that looks
    /// like it is still the thing to press.
    private var backgroundColor: Color {
        if isProcessing { return agentColor.opacity(0.9) }
        return canSend ? IysThemePreferences.active.accent : OCColor.bgLayer2
    }

    private var iconColor: Color {
        isProcessing || canSend ? OCColor.onAccent : OCColor.iconMuted
    }

    private var iconName: String {
        isProcessing ? "stop.fill" : "arrow.up"
    }

    private var iconSize: CGFloat {
        isProcessing ? 11 : 14
    }
}

// MARK: - Composer Control Row

public struct ComposerControlRow: View {
    let agentMode: AgentMode
    let onAgentTap: () -> Void
    let selectedModel: ModelInfo?
    let onModelTap: () -> Void
    let onAttachTap: () -> Void
    let showsAttachButton: Bool
    @Binding var flowMode: Bool
    let codexMode: Bool
    let limitedLabel: String?

    public init(
        agentMode: AgentMode,
        onAgentTap: @escaping () -> Void,
        selectedModel: ModelInfo?,
        onModelTap: @escaping () -> Void,
        onAttachTap: @escaping () -> Void,
        showsAttachButton: Bool = true,
        flowMode: Binding<Bool> = .constant(false),
        codexMode: Bool = false,
        limitedLabel: String? = nil
    ) {
        self.agentMode = agentMode
        self.onAgentTap = onAgentTap
        self.selectedModel = selectedModel
        self.onModelTap = onModelTap
        self.onAttachTap = onAttachTap
        self.showsAttachButton = showsAttachButton
        self._flowMode = flowMode
        self.codexMode = codexMode
        self.limitedLabel = limitedLabel
    }

    // Wraps instead of truncating: at large Dynamic Type sizes the chips used to read
    // "Con…" / "iSy…" in one squeezed line.
    public var body: some View {
        OCFlowLayout(spacing: OCSpacing.base, lineSpacing: 0) {
            if showsAttachButton {
                // Attach remains available for Codex sessions too; the old layout
                // hid it whenever the Codex-specific controls were shown.
                Button(action: onAttachTap) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                        .frame(width: 40, height: 40)
                        .background(OCColor.bgLayer1)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                        .overlay(RoundedRectangle(cornerRadius: OCRadius.r10).stroke(OCColor.borderMuted, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adjuntar archivo")
            }

            if let limitedLabel {
                Label(limitedLabel, systemImage: "terminal")
                    .font(OCTypography.control)
                    .foregroundColor(OCColor.textSecondary)
                if let model = selectedModel {
                    ModelPill(model: model, onTap: onModelTap)
                } else {
                    ModelPillPlaceholder(onTap: onModelTap)
                }
            } else if codexMode {
                Label("Codex · App Server", systemImage: "terminal")
                    .font(OCTypography.control)
                    .foregroundColor(OCColor.textSecondary)
                if let model = selectedModel {
                    ModelPill(model: model, onTap: onModelTap)
                } else {
                    ModelPillPlaceholder(onTap: onModelTap)
                }
            } else {
                // Only the model is always visible. Mode and Flow live in the "+" sheet and show
                // up here only while they differ from the default, so the person still sees them.
                if let model = selectedModel {
                    ModelPill(model: model, onTap: onModelTap)
                } else {
                    ModelPillPlaceholder(onTap: onModelTap)
                }
                if agentMode != .build {
                    AgentPill(mode: agentMode, onTap: onAgentTap)
                }
            }

            if flowMode {
                FlowPill(isActive: $flowMode)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

// MARK: - Flow Pill

public struct FlowPill: View {
    @Binding var isActive: Bool

    public init(isActive: Binding<Bool>) {
        self._isActive = isActive
    }

    public var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isActive.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "bolt.fill" : "bolt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isActive ? OCColor.warning : OCColor.textFaint)
                Text("Flow")
                    .font(OCTypography.pillLabel)
                    .foregroundColor(isActive ? OCColor.warning : OCColor.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(isActive ? OCColor.warning.opacity(0.14) : OCColor.bgLayer1.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(isActive ? OCColor.warning.opacity(0.55) : OCColor.borderMuted, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(isActive ? "Modo Flow activado: omite confirmaciones rutinarias (acciones sensibles siguen pidiendo permiso)" : "Activar modo Flow acotado")
    }
}

// MARK: - Agent Pill

public struct AgentPill: View {
    let mode: AgentMode
    let onTap: () -> Void

    public init(mode: AgentMode, onTap: @escaping () -> Void) {
        self.mode = mode
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                // State dot
                Circle()
                    .fill(mode.color)
                    .frame(width: 6, height: 6)

                Text(mode.displayName)
                    .font(OCTypography.pillLabel)
                    .foregroundColor(OCColor.textPrimary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(mode.softColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(mode.borderColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .frame(minHeight: 44) // hit target
        .contentShape(Rectangle())
    }
}

// MARK: - Model Pill

public struct ModelPill: View {
    let model: ModelInfo
    let onTap: () -> Void

    public init(model: ModelInfo, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                if let icon = model.providerIcon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                }

                Text(providerModelLabel)
                    .font(OCTypography.modelPillLabel)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .frame(maxWidth: 260)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(OCColor.bgLayer1.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(OCColor.borderMuted, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(OCInteractiveButtonStyle())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var providerModelLabel: String {
        let combined = "\(model.provider) · \(model.name)"
        if combined.count <= 22 { return combined }
        // Keep provider identity; middle-truncate the model name.
        let nameLimit = 22 - model.provider.count - 3
        if nameLimit >= 2 {
            let prefix = model.name.prefix(max(1, nameLimit / 2))
            let suffix = model.name.suffix(max(2, nameLimit / 2))
            return "\(model.provider) · \(prefix)…\(suffix)"
        }
        return model.provider
    }
}

// MARK: - Model Pill Placeholder

public struct ModelPillPlaceholder: View {
    let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconMuted)

                Text("Elegir modelo")
                    .font(OCTypography.modelPillLabel)
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(OCColor.bgLayer1.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(OCColor.borderMuted, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Attachments Bar

public struct AttachmentsBar: View {
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    public init(attachments: [Attachment], onRemove: @escaping (Attachment) -> Void) {
        self.attachments = attachments
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OCSpacing.xs) {
                ForEach(attachments) { attachment in
                    AttachmentToken(attachment: attachment, onRemove: { onRemove(attachment) })
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 36)
    }
}

// MARK: - Agent Picker Sheet

public struct AgentPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMode: AgentMode
    let availableModes: [AgentMode]

    public init(selectedMode: Binding<AgentMode>, availableModes: [AgentMode] = AgentMode.allCases) {
        self._selectedMode = selectedMode
        self.availableModes = availableModes
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Modos") {
                    ForEach(availableModes.prefix(2)) { mode in
                        AgentPickerRow(mode: mode, isSelected: selectedMode == mode) {
                            selectedMode = mode
                            dismiss()
                        }
                    }
                }

                if availableModes.count > 2 {
                    Section("Agentes") {
                        ForEach(availableModes.dropFirst(2)) { mode in
                            AgentPickerRow(mode: mode, isSelected: selectedMode == mode) {
                                selectedMode = mode
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .navigationTitle("Agente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(CGFloat(availableModes.count * 56 + 120))])
    }
}

public struct AgentPickerRow: View {
    let mode: AgentMode
    let isSelected: Bool
    let onTap: () -> Void

    public init(mode: AgentMode, isSelected: Bool, onTap: @escaping () -> Void) {
        self.mode = mode
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                // State dot
                Circle()
                    .fill(mode.color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.system(size: 15, weight: .medium, design: .default))
                        .foregroundColor(OCColor.textPrimary)

                    Text(mode.description)
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(OCColor.textFaint)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(mode.color)
                }
            }
            .padding(.vertical, OCSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Model Picker Sheet

public struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedModel: ModelInfo?
    let models: [ModelInfo]
    @State private var searchText = ""
    @State private var reasoningEffort: ReasoningEffort = ReasoningEffortSetting.current

    public init(selectedModel: Binding<ModelInfo?>, models: [ModelInfo] = []) {
        self._selectedModel = selectedModel
        self.models = models
    }

    public var body: some View {
        NavigationStack {
            Group {
                if filteredModels.isEmpty {
                    modelEmptyState
                } else {
                    List {
                        Section {
                            Picker("Razonamiento", selection: $reasoningEffort) {
                                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                    Text(effort.displayName).tag(effort)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("Auto no envía ningún ajuste. Bajo, Medio y Alto piden ese esfuerzo al modelo; solo viaja a proveedores que lo aceptan (NVIDIA NIM, OpenAI, OpenRouter y Codex). Aplica en el siguiente mensaje.")
                                .font(OCTypography.meta)
                                .foregroundColor(OCColor.textSecondary)
                        } header: {
                            Text("Razonamiento")
                                .font(OCTypography.sectionLabel)
                                .foregroundColor(OCColor.textFaint)
                                .textCase(nil)
                        }
                        ForEach(groupedModels.keys.sorted(), id: \.self) { provider in
                            Section(header: ProviderHeader(provider: provider)) {
                                ForEach(groupedModels[provider] ?? []) { model in
                                    ModelPickerRow(
                                        model: model,
                                        isSelected: selectedModel.map { matches($0, model) } ?? false
                                    ) {
                                        selectedModel = model
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(OCColor.bgDeep)
            .navigationTitle("Modelo")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar modelos")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: reasoningEffort) { ReasoningEffortSetting.current = $0 }
    }

    private var modelEmptyState: some View {
        VStack(spacing: OCSpacing.lg) {
            Image(systemName: searchText.isEmpty ? "cpu" : "magnifyingglass")
                .font(.system(size: 25, weight: .medium))
                .foregroundColor(IysThemePreferences.active.accent)
                .frame(width: 54, height: 54)
                .background(IysThemePreferences.active.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))

            VStack(spacing: OCSpacing.xs) {
                Text(searchText.isEmpty ? "Modelo del servidor" : "Sin resultados")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                Text(searchText.isEmpty
                    ? "El host mantiene su modelo predeterminado y no publicó modelos seleccionables."
                    : "Prueba con otro nombre de modelo o proveedor.")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 280)

            if searchText.isEmpty {
                Label("La sesión seguirá usando la configuración del host", systemImage: "info.circle")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OCSpacing.huge)
        .background(OCColor.bgDeep)
    }

    private func matches(_ lhs: ModelInfo, _ rhs: ModelInfo) -> Bool {
        lhs.id == rhs.id || (lhs.apiModelId != nil && lhs.apiModelId == rhs.apiModelId
            && (lhs.route ?? lhs.provider) == (rhs.route ?? rhs.provider))
    }

    private var groupedModels: [String: [ModelInfo]] {
        Dictionary(grouping: filteredModels, by: { $0.provider })
    }

    private var filteredModels: [ModelInfo] {
        var candidates = models.filter { $0.apiModelId != nil }
        if let selectedModel, selectedModel.apiModelId != nil, !candidates.contains(where: { matches($0, selectedModel) }) {
            candidates.insert(selectedModel, at: 0)
        }
        if searchText.isEmpty { return candidates }
        return candidates.filter { model in
            model.name.localizedCaseInsensitiveContains(searchText) ||
            model.provider.localizedCaseInsensitiveContains(searchText)
        }
    }
}

public struct ProviderHeader: View {
    let provider: String

    public var body: some View {
        Text(provider)
            .font(OCTypography.sectionLabel)
            .foregroundColor(OCColor.textFaint)
            .textCase(nil)
            .padding(.vertical, OCSpacing.xs)
    }
}

public struct ModelPickerRow: View {
    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void

    public init(model: ModelInfo, isSelected: Bool, onTap: @escaping () -> Void) {
        self.model = model
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                if let icon = model.providerIcon {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                        .frame(width: 32)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 13.5, weight: .medium, design: .default))
                        .foregroundColor(OCColor.textPrimary)

                    HStack(spacing: OCSpacing.xs) {
                        ForEach(Array(metadataItems.enumerated()), id: \.offset) { _, item in
                            Label(item.0, systemImage: item.1)
                                .font(OCTypography.metaMono)
                                .foregroundColor(item.2)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.agentBuild)
                }
            }
            .padding(.vertical, OCSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// At most two metadata badges per row, in priority order: Local → Reasoning → context.
    private var metadataItems: [(String, String, Color)] {
        var items: [(String, String, Color)] = []
        if model.isLocal {
            items.append(("Local", "iphone", OCColor.agentExplore))
        }
        if model.supportsReasoning {
            items.append(("Reasoning", "brain", OCColor.agentBuild))
        }
        if items.count < 2, let ctx = model.contextWindow {
            items.append(("\(ctx / 1000)k ctx", "text.line", OCColor.textFaint))
        }
        return Array(items.prefix(2))
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let composerSend = Notification.Name("composerSend")
    static let composerStop = Notification.Name("composerStop")
}

// MARK: - Attachments Sheet

public struct AttachmentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    private var owner: Binding<[Attachment]>?
    private var attachments: [Attachment] {
        get { owner?.wrappedValue ?? sessionState.composerAttachments }
        nonmutating set {
            if let owner { owner.wrappedValue = newValue }
            else { sessionState.composerAttachments = newValue }
        }
    }
    @State private var manualName = ""

    public init(attachments: Binding<[Attachment]>? = nil) { owner = attachments }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Adjuntos") {
                    if attachments.isEmpty {
                        Text("Todavía no hay adjuntos")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textFaint)
                    } else {
                        ForEach(attachments) { attachment in
                            HStack {
                                Image(systemName: attachment.icon)
                                    .foregroundColor(OCColor.iconPrimary)
                                Text(attachment.name)
                                    .foregroundColor(OCColor.textPrimary)
                                Spacer()
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(OCColor.textFaint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Archivos del proyecto") {
                    if store.fileTree.isEmpty {
                        Text("Sin archivos disponibles")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textFaint)
                    } else {
                        ForEach(workspaceFiles) { file in
                            Button {
                                addAttachment(name: file.name, path: file.path)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(OCColor.iconPrimary)
                                    Text(file.name)
                                        .foregroundColor(OCColor.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(OCColor.agentBuild)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Agregar por nombre") {
                    TextField("Nombre del archivo", text: $manualName)
                        .autocorrectionDisabled()
                    Button("Agregar") {
                        addAttachment(name: manualName, path: nil)
                    }
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Adjuntos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .onAppear {
                if store.fileTree.isEmpty {
                    Task { await store.loadFiles() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var workspaceFiles: [WorkbenchFileNode] {
        store.fileTree.filter { !$0.isDirectory }
    }

    private func addAttachment(name: String, path: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let attachment = Attachment(
            type: path == nil ? .context : .file,
            name: trimmed,
            path: path,
            icon: path == nil ? "text.quote" : "doc"
        )
        attachments.append(attachment)
        manualName = ""
    }
}

import SwiftUI

// MARK: - Composer View

public struct ComposerView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
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

            // Attachments row
            if !sessionState.composerAttachments.isEmpty {
                AttachmentsBar(attachments: sessionState.composerAttachments) { attachment in
                    sessionState.composerAttachments.removeAll { $0.id == attachment.id }
                }
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Input area
            HStack(alignment: .bottom, spacing: OCSpacing.base) {
                // Input text
                ZStack(alignment: .topLeading) {
                    if sessionState.composerText.isEmpty {
                        Text(sessionState.isProcessing ? "" : composerPlaceholder)
                            .font(OCTypography.body)
                            .foregroundColor(OCColor.textFaint)
                            .padding(.horizontal, OCSpacing.base)
                            .padding(.vertical, OCSpacing.sm)
                    }

                    TextField("", text: $sessionState.composerText, axis: .vertical)
                        .font(OCTypography.body)
                        .foregroundColor(OCColor.textPrimary)
                        .focused($isFocused)
                        .lineLimit(1...8)
                        .submitLabel(.send)
                        .onSubmit { handleSend() }
                        .disabled(sessionState.isProcessing)
                        .padding(.horizontal, OCSpacing.base)
                        .padding(.vertical, OCSpacing.sm)
                }
                .frame(minHeight: 42)

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
            .padding(.horizontal, OCSpacing.lg)
            .padding(.vertical, OCSpacing.base)

            // Control row
            ComposerControlRow(
                agentMode: sessionState.agentMode,
                onAgentTap: { sessionState.showAgentPicker = true },
                selectedModel: sessionState.selectedModel,
                onModelTap: { sessionState.showModelPicker = true },
                onAttachTap: { sessionState.showAttachments = true },
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
        .animation(.easeInOut(duration: 0.18), value: sessionState.composerAttachments.isEmpty)
        .animation(.easeInOut(duration: 0.18), value: sessionState.isProcessing)
    }

    private func handleSend() {
        guard !sessionState.isProcessing else { return }
        guard !sessionState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // This will be handled by the parent view model
        NotificationCenter.default.post(name: .composerSend, object: sessionState.composerText)
        sessionState.composerText = ""
    }

    private var canSend: Bool {
        !sessionState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        }
        .disabled(isProcessing ? false : !canSend)
        .opacity(isProcessing || canSend ? 1 : 0.4)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isProcessing)
        .animation(.easeInOut(duration: 0.15), value: canSend)
    }

    private var backgroundColor: Color {
        isProcessing ? agentColor.opacity(0.9) : IysThemePreferences.active.accent
    }

    private var iconColor: Color {
        OCColor.bgDeep
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
    let codexMode: Bool
    let limitedLabel: String?

    public init(
        agentMode: AgentMode,
        onAgentTap: @escaping () -> Void,
        selectedModel: ModelInfo?,
        onModelTap: @escaping () -> Void,
        onAttachTap: @escaping () -> Void,
        codexMode: Bool = false,
        limitedLabel: String? = nil
    ) {
        self.agentMode = agentMode
        self.onAgentTap = onAgentTap
        self.selectedModel = selectedModel
        self.onModelTap = onModelTap
        self.onAttachTap = onAttachTap
        self.codexMode = codexMode
        self.limitedLabel = limitedLabel
    }

    public var body: some View {
        HStack(spacing: OCSpacing.base) {
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
                AgentPill(mode: agentMode, onTap: onAgentTap)

            // Model pill
            if let model = selectedModel {
                ModelPill(model: model, onTap: onModelTap)
            } else {
                ModelPillPlaceholder(onTap: onModelTap)
            }
            }

            Spacer()
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

// MARK: - Agent Pill

public struct AgentPill: View {
    let mode: AgentMode
    let onTap: () -> Void
    @State private var isPressed = false

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

                Text(mode.rawValue)
                    .font(OCTypography.pillLabel)
                    .foregroundColor(OCColor.textPrimary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(mode.softColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(mode.borderColor, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .frame(height: 44) // hit target
        .contentShape(Rectangle())
    }
}

// MARK: - Model Pill

public struct ModelPill: View {
    let model: ModelInfo
    let onTap: () -> Void
    @State private var isPressed = false

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
            .frame(height: 28)
            .frame(maxWidth: 136)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(OCColor.bgLayer1.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(OCColor.borderMuted, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .frame(height: 44)
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

                Text("Select model")
                    .font(OCTypography.modelPillLabel)
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
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
        .frame(height: 44)
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
                Section("Modes") {
                    ForEach(availableModes.prefix(2)) { mode in
                        AgentPickerRow(mode: mode, isSelected: selectedMode == mode) {
                            selectedMode = mode
                            dismiss()
                        }
                    }
                }

                if availableModes.count > 2 {
                    Section("Agents") {
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
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

    public init(selectedModel: Binding<ModelInfo?>, models: [ModelInfo] = ModelInfo.demoModels) {
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
                        ForEach(groupedModels.keys.sorted(), id: \.self) { provider in
                            Section(header: ProviderHeader(provider: provider)) {
                                ForEach(groupedModels[provider] ?? []) { model in
                                    ModelPickerRow(
                                        model: model,
                                        isSelected: selectedModel?.id == model.id
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
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    private var groupedModels: [String: [ModelInfo]] {
        Dictionary(grouping: filteredModels, by: { $0.provider })
    }

    private var filteredModels: [ModelInfo] {
        var candidates = models.filter { $0.apiModelId != nil }
        if let selectedModel, selectedModel.apiModelId != nil, !candidates.contains(where: { $0.id == selectedModel.id }) {
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
    @State private var manualName = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Current") {
                    if sessionState.composerAttachments.isEmpty {
                        Text("No attachments")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textFaint)
                    } else {
                        ForEach(sessionState.composerAttachments) { attachment in
                            HStack {
                                Image(systemName: attachment.icon)
                                    .foregroundColor(OCColor.iconPrimary)
                                Text(attachment.name)
                                    .foregroundColor(OCColor.textPrimary)
                                Spacer()
                                Button {
                                    sessionState.composerAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(OCColor.textFaint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Workspace files") {
                    if store.fileTree.isEmpty {
                        Text("Loading workspace…")
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

                Section("Add by name") {
                    TextField("File or context name", text: $manualName)
                        .autocorrectionDisabled()
                    Button("Add") {
                        addAttachment(name: manualName, path: nil)
                    }
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        sessionState.composerAttachments.append(attachment)
        manualName = ""
    }
}

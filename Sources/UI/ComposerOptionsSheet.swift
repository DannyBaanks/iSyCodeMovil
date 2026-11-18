import SwiftUI

/// The chat composer's "+": one sheet with what used to be a seven-item menu plus the chips
/// that were always on screen (mode, Flow). Attaching comes first, how the agent works
/// second, everything else under "Más" — the pattern Muse, Claude and ChatGPT use so the
/// composer itself stays a text field and a send button.
struct ComposerOptionsButton: View {
    @ObservedObject var coordinator: MultimodalComposerCoordinator
    @Binding var agentMode: AgentMode
    @Binding var flowMode: Bool
    let availableModes: [AgentMode]
    let modelName: String?
    let onModelTap: () -> Void

    @State private var showSheet = false
    /// A picker can't open while the sheet is still on screen: the choice runs after it closes.
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        Button {
            OCHaptics.light()
            showSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundColor(OCColor.iconPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(OCColor.bgLayer1))
                .overlay(Circle().stroke(OCColor.borderMuted, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Opciones: adjuntar, modo y Flow")
        .accessibilityIdentifier("composer-plus-button")
        .sheet(isPresented: $showSheet, onDismiss: {
            let action = pendingAction
            pendingAction = nil
            action?()
        }) {
            ComposerOptionsSheet(
                agentMode: $agentMode,
                flowMode: $flowMode,
                availableModes: availableModes,
                modelName: modelName,
                onModelTap: onModelTap,
                pick: { action in
                    pendingAction = action
                    showSheet = false
                },
                coordinator: coordinator
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ComposerOptionsSheet: View {
    @Binding var agentMode: AgentMode
    @Binding var flowMode: Bool
    let availableModes: [AgentMode]
    let modelName: String?
    let onModelTap: () -> Void
    let pick: (@escaping () -> Void) -> Void
    let coordinator: MultimodalComposerCoordinator
    @State private var showMore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OCSpacing.xl) {
                attachTiles

                VStack(alignment: .leading, spacing: OCSpacing.md) {
                    sectionTitle("Cómo trabaja")
                    if availableModes.count > 1 {
                        Picker("Modo", selection: $agentMode) {
                            ForEach(availableModes) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle(isOn: $flowMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flow")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(OCColor.textPrimary)
                            Text("Omite las confirmaciones de rutina. Lo sensible sigue preguntando.")
                                .font(.caption)
                                .foregroundColor(OCColor.textSecondary)
                        }
                    }
                    .tint(IysThemePreferences.active.accent)
                    .onChange(of: flowMode) { _ in OCHaptics.selection() }
                }

                optionRow(
                    title: "Modelo",
                    detail: modelName ?? "Elegir",
                    symbol: "cpu"
                ) {
                    pick(onModelTap)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(OCMotion.smooth) { showMore.toggle() }
                    } label: {
                        HStack {
                            sectionTitle("Más")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(OCColor.iconMuted)
                                .rotationEffect(.degrees(showMore ? 180 : 0))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(showMore ? "Ocultar" : "Mostrar video, audio, archivos del proyecto, aprender acción y Llavero")

                    if showMore {
                        VStack(spacing: 0) {
                            optionRow(title: "Video de la Fototeca", symbol: "video") { pick { coordinator.showVideoPicker = true } }
                            optionRow(title: "Audio existente", symbol: "waveform") { pick { coordinator.showAudioImporter = true } }
                            optionRow(title: "Archivos del proyecto", symbol: "doc.text.magnifyingglass") { pick { coordinator.showWorkspaceSheet = true } }
                            optionRow(title: "Aprender una acción", symbol: "record.circle") {
                                pick { NotificationCenter.default.post(name: .openLearnActionSheet, object: nil) }
                            }
                            optionRow(title: "Llavero de contraseñas", symbol: "key.fill") {
                                pick { NotificationCenter.default.post(name: .openSecretVaultSheet, object: nil) }
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, OCSpacing.xl)
            .padding(.top, OCSpacing.xxl)
            .padding(.bottom, OCSpacing.xl)
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
    }

    private var attachTiles: some View {
        HStack(spacing: OCSpacing.md) {
            attachTile("Fotos", symbol: "photo.on.rectangle.angled") { coordinator.showPhotosPicker = true }
            attachTile("Cámara", symbol: "camera") { coordinator.openCamera() }
            attachTile("Archivo", symbol: "folder") { coordinator.showFileImporter = true }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func attachTile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            OCHaptics.light()
            pick(action)
        } label: {
            VStack(spacing: OCSpacing.sm) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundColor(IysThemePreferences.active.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(OCColor.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, OCSpacing.lg)
            .background(OCColor.bgLayer1)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(OCInteractiveButtonStyle())
    }

    private func optionRow(title: String, detail: String? = nil, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            OCHaptics.light()
            action()
        } label: {
            HStack(spacing: OCSpacing.md) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundColor(OCColor.iconPrimary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(OCColor.textPrimary)
                Spacer(minLength: OCSpacing.sm)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(OCColor.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(OCColor.iconMuted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundColor(OCColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

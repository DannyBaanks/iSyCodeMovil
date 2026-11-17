import SwiftUI

/// Separates "Local on this iPhone" from "Connected cloud provider" into clear mental models
/// while persisting the user's chosen provider, key, and model.
public struct RuntimeSetupSheet: View {
    public let initialTrack: RuntimeSetupTrack
    public let initialProviderID: String?
    public var onOpenRemotePairing: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @StateObject private var gusModelManager = GUSModelDownloadManager.shared

    @State private var track: RuntimeSetupTrack = .connected
    @State private var selectedCloudProviderID = "nvidia"
    @State private var apiKeyDraft = ""
    @State private var savedKeyProviders: Set<String> = []
    @State private var isApplying = false
    @State private var showProviderHelp = false
    @FocusState private var keyFocused: Bool

    public init(
        initialTrack: RuntimeSetupTrack = .connected,
        initialProviderID: String? = nil,
        onOpenRemotePairing: (() -> Void)? = nil
    ) {
        self.initialTrack = initialTrack
        self.initialProviderID = initialProviderID
        self.onOpenRemotePairing = onOpenRemotePairing
    }

    private var selectedCloudProvider: SandboxModelProvider {
        SandboxModelProvider.provider(id: selectedCloudProviderID) ?? SandboxModelProvider.all[0]
    }

    private var hasSavedKeyForSelected: Bool {
        savedKeyProviders.contains(selectedCloudProviderID)
    }

    private var canStartSelectedCloud: Bool {
        !isApplying && (hasSavedKeyForSelected || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canStartLocal: Bool {
        !isApplying && gusModelManager.installedModelURL != nil
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.xl) {
                    headerSection
                    trackSwitcher
                    trackContent
                    secondaryOptionsSection
                }
                .padding(OCSpacing.contentMargin)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("Motor de IA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                        .accessibilityIdentifier("runtime-setup-close")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showProviderHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Ayuda de proveedores y modelos")
                }
            }
            .sheet(isPresented: $showProviderHelp) {
                ProviderDirectoryView()
            }
            .task {
                configureInitialSelection()
                await loadSavedProviderKeys()
            }
            .onChange(of: selectedCloudProviderID) { _ in
                apiKeyDraft = ""
                store.sandboxSetupError = nil
            }
        }
        .presentationDetents([.large])
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: OCSpacing.xs) {
            Text("Elige cómo trabaja el asistente")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(OCColor.textPrimary)
            Text("Tu selección se guarda y se restaura al abrir la app. Puedes cambiar de motor cuando quieras sin perder tus conversaciones.")
                .font(.system(size: 14))
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trackSwitcher: some View {
        HStack(spacing: OCSpacing.base) {
            ForEach(RuntimeSetupTrack.allCases) { item in
                let isSelected = track == item
                Button {
                    track = item
                    store.sandboxSetupError = nil
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(isSelected ? OCColor.onAccent : OCColor.textPrimary)

                        Text(item.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(isSelected ? OCColor.onAccent.opacity(0.85) : OCColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(OCSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? IysThemePreferences.active.accent : OCColor.bgBase)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(isSelected ? IysThemePreferences.active.accent : OCColor.borderMuted, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runtime-track-\(item.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var trackContent: some View {
        switch track {
        case .local:
            localTrackCard
        case .connected:
            connectedTrackCard
        }
    }

    private var localTrackCard: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Label("Local en este iPhone", systemImage: "lock.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.success)
                Text("Privacidad completa y uso sin internet. Descarga un modelo verificado por SHA-256 una sola vez y úsalo en tus conversaciones.")
                    .font(.system(size: 13.5))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(OCSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ocCard(radius: OCRadius.r14)

            GUSModelDownloadView(manager: gusModelManager)

            Button {
                applyLocalRuntime()
            } label: {
                HStack {
                    if isApplying {
                        ProgressView().tint(OCColor.onAccent)
                    }
                    Text(isApplying ? "Activando GUS local…" : "Usar GUS local")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundColor(OCColor.onAccent)
                .padding(.horizontal, OCSpacing.xl)
                .frame(height: 48)
                .background(canStartLocal ? IysThemePreferences.active.accent : OCColor.textFaint)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
            }
            .buttonStyle(.plain)
            .disabled(!canStartLocal)
            .accessibilityIdentifier("runtime-use-local-button")

            if !canStartLocal && !isApplying {
                Text("Descarga y selecciona primero un modelo GGUF arriba para activar GUS local.")
                    .font(.system(size: 12.5))
                    .foregroundColor(OCColor.textFaint)
            }

            if let error = store.sandboxSetupError {
                errorBanner(error)
            }
        }
    }

    private var connectedTrackCard: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Label("Proveedor conectado", systemImage: "network")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.info)
                Text("Lo que escribas se envía directamente desde tu iPhone al proveedor elegido usando tu API key guardada en el llavero.")
                    .font(.system(size: 13.5))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(OCSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ocCard(radius: OCRadius.r14)

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("PROVEEDOR")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)

                ForEach(SandboxModelProvider.all) { provider in
                    let isSelected = selectedCloudProviderID == provider.id
                    let hasSaved = savedKeyProviders.contains(provider.id)
                    Button {
                        selectedCloudProviderID = provider.id
                    } label: {
                        HStack(spacing: OCSpacing.md) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundColor(isSelected ? IysThemePreferences.active.accent : OCColor.iconMuted)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(OCColor.textPrimary)
                                    if hasSaved {
                                        Text("Clave guardada")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(OCColor.success)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(OCColor.success.opacity(0.14)))
                                    }
                                }
                                Text(provider.description)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(OCColor.textSecondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(OCSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? IysThemePreferences.active.accent.opacity(0.10) : OCColor.bgBase)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                        .overlay(
                            RoundedRectangle(cornerRadius: OCRadius.r12)
                                .stroke(isSelected ? IysThemePreferences.active.accent : OCColor.borderMuted, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runtime-provider-\(provider.id)")
                }
            }

            if selectedCloudProviderID == "gemini" {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(OCColor.info)
                    Text("Esta opción usa una API key de Gemini (AI Studio). Para conectar Gmail, Calendar, Drive o Tasks usa la pestaña Google con OAuth.")
                        .font(.system(size: 12.5))
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(OCSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: OCRadius.r12).fill(OCColor.info.opacity(0.10)))
            }

            VStack(alignment: .leading, spacing: OCSpacing.sm) {
                Text("API KEY DE \(selectedCloudProvider.name.uppercased())")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)

                SecureField(
                    hasSavedKeyForSelected
                        ? "Clave guardada en Keychain (pega otra para reemplazar)"
                        : selectedCloudProvider.keyPlaceholder,
                    text: $apiKeyDraft
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(OCColor.textPrimary)
                .focused($keyFocused)
                .padding(OCSpacing.md)
                .background(OCColor.bgBase)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderBase, lineWidth: 1))
                .accessibilityIdentifier("runtime-api-key-field")

                Link(destination: selectedCloudProvider.apiKeyURL) {
                    Label("Obtener clave de \(selectedCloudProvider.name)", systemImage: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(IysThemePreferences.active.accent)
                }
            }

            Button {
                applyConnectedProvider()
            } label: {
                HStack {
                    if isApplying {
                        ProgressView().tint(OCColor.onAccent)
                    }
                    Text(isApplying
                        ? "Verificando conexión…"
                        : (hasSavedKeyForSelected && apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Continuar con \(selectedCloudProvider.name)"
                            : "Guardar clave y activar"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundColor(OCColor.onAccent)
                .padding(.horizontal, OCSpacing.xl)
                .frame(height: 48)
                .background(canStartSelectedCloud ? IysThemePreferences.active.accent : OCColor.textFaint)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
            }
            .buttonStyle(.plain)
            .disabled(!canStartSelectedCloud)
            .accessibilityIdentifier("runtime-activate-cloud-button")

            if let error = store.sandboxSetupError {
                errorBanner(error)
            }
        }
    }

    private var secondaryOptionsSection: some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            Text("OTRAS OPCIONES")
                .font(OCTypography.sectionLabel)
                .foregroundColor(OCColor.textFaint)

            Button {
                applyDemoRuntime()
            } label: {
                HStack {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundColor(OCColor.info)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Probar guion de demo sin conexión")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Explora el chat y los permisos sin API key ni descargas.")
                            .font(.system(size: 12))
                            .foregroundColor(OCColor.textSecondary)
                    }
                    Spacer()
                }
                .padding(OCSpacing.md)
                .ocCard(radius: OCRadius.r12)
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .accessibilityIdentifier("runtime-demo-button")

            if let onOpenRemotePairing {
                Button {
                    dismiss()
                    onOpenRemotePairing()
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .foregroundColor(IysThemePreferences.active.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Conectar mi computadora")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(OCColor.textPrimary)
                            Text("Usa OpenCode, Codex o Grok corriendo en tu PC.")
                                .font(.system(size: 12))
                                .foregroundColor(OCColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(OCColor.iconMuted)
                    }
                    .padding(OCSpacing.md)
                    .ocCard(radius: OCRadius.r12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runtime-remote-pairing-button")
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(OCColor.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(OCColor.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(OCSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OCRadius.r12).fill(OCColor.danger.opacity(0.10)))
        .accessibilityIdentifier("runtime-setup-error")
    }

    private func configureInitialSelection() {
        track = initialTrack
        let candidate = initialProviderID ?? store.configuredProviderID
        if let candidate {
            if candidate == "gus-local" {
                track = .local
            } else if SandboxModelProvider.provider(id: candidate) != nil {
                track = .connected
                selectedCloudProviderID = candidate
            }
        }
        store.sandboxSetupError = nil
    }

    private func loadSavedProviderKeys() async {
        guard let persistence = try? IOSPersistence() else { return }
        var found = Set<String>()
        for provider in SandboxModelProvider.all {
            if let saved = try? await persistence.loadAPIKey(provider: provider.id),
               !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.insert(provider.id)
            }
        }
        savedKeyProviders = found
    }

    private func applyLocalRuntime() {
        keyFocused = false
        isApplying = true
        Task {
            let started = await store.startSandbox(providerID: "gus-local", apiKey: nil)
            isApplying = false
            if started { dismiss() }
        }
    }

    private func applyConnectedProvider() {
        keyFocused = false
        let typed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplying = true
        Task {
            let started = await store.startSandbox(
                providerID: selectedCloudProviderID,
                apiKey: typed.isEmpty ? nil : typed
            )
            if started {
                await loadSavedProviderKeys()
                isApplying = false
                dismiss()
            } else {
                isApplying = false
            }
        }
    }

    private func applyDemoRuntime() {
        keyFocused = false
        isApplying = true
        Task {
            await store.useNativeDemoRuntime()
            isApplying = false
            if store.backendMode == .native, store.connectionHealth == .connected {
                dismiss()
            } else {
                store.sandboxSetupError = store.connectionStatus.isEmpty
                    ? "No pude iniciar el guion de demo."
                    : store.connectionStatus
            }
        }
    }
}

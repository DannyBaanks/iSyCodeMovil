import SwiftUI

/// Unified Settings view accessible as a top-level destination in AppShell,
/// keeping common actions human-friendly and burying raw diagnostics under "Avanzado".
public struct UnifiedSettingsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter

    @State private var showLegacySettingsSheet = false
    @State private var showAssistantOptionsSheet = false

    public init() {}

    private var runtime: RuntimeSelectionSnapshot { store.runtimeSnapshot }
    private var googleState: GoogleConnectionState { assistant.googleConnectionState }

    public var body: some View {
        List {
            Section("Motor de IA") {
                HStack(spacing: OCSpacing.md) {
                    Image(systemName: runtime.readiness.symbol)
                        .foregroundColor(runtime.readiness.tone.semanticColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runtime.providerName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Text(runtime.runtimeSummaryLine)
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textSecondary)
                    }
                    Spacer()
                    Text(runtime.readiness.badgeText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(runtime.readiness.tone.semanticColor)
                }

                Button {
                    router.openRuntimeSetup(
                        track: runtime.isLocal ? .local : .connected,
                        providerID: runtime.providerID
                    )
                } label: {
                    Label("Cambiar motor o API key", systemImage: "cpu")
                }
                .accessibilityIdentifier("settings-change-runtime")

                NavigationLink {
                    APIKeysView()
                } label: {
                    Label("Proveedores y claves en Keychain", systemImage: "key.fill")
                }

                NavigationLink {
                    GUSModelDownloadView()
                } label: {
                    Label("Modelos locales GUS", systemImage: "arrow.down.circle")
                }
            }

            Section("Google Workspace (OAuth)") {
                HStack {
                    Image(systemName: googleState.symbol)
                        .foregroundColor(googleState.tone.semanticColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(googleState.badgeText)
                            .font(.system(size: 14.5, weight: .semibold))
                        if let email = assistant.email {
                            Text(email)
                                .font(OCTypography.meta)
                                .foregroundColor(OCColor.textSecondary)
                        }
                    }
                }

                Button {
                    router.showGoogleOAuthSetupSheet = true
                } label: {
                    Label("Configurar cliente OAuth iOS y permisos", systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("settings-google-oauth")
            }

            Section("Tu computadora") {
                MobileHostPairingSection()
                    .environmentObject(hostStore)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)

                Button {
                    router.showRemotePairingSheet = true
                } label: {
                    Label("Conectar por enlace (OpenCode / Codex / Grok)", systemImage: "link")
                }
            }

            Section("Espacio de trabajo y permisos") {
                NavigationLink {
                    NativeCapabilitySettingsView()
                } label: {
                    Label("Capacidades nativas del iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                }

                Button {
                    showLegacySettingsSheet = true
                } label: {
                    Label("Carpeta autorizada, tema y apariencia", systemImage: "folder.badge.gearshape")
                }

                Button {
                    showAssistantOptionsSheet = true
                } label: {
                    Label("Monitor de PC, notificaciones y opciones", systemImage: "bell.badge")
                }
            }

            Section("Avanzado") {
                Toggle(isOn: Binding(
                    get: { GUSMailboxWatcher.isEnabled },
                    set: { store.setMailboxWatcherEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vigilante del buzón [GUS]")
                        Text("GUS revisa el buzón [GUS] en Gmail mientras la app está viva y ejecuta las tareas pendientes. El buzón es la fuente de verdad; las notificaciones solo avisan. Apagado por defecto.")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textSecondary)
                    }
                }
                .tint(IysThemePreferences.active.accent)

                Toggle(isOn: Binding(
                    get: { assistant.developerMode },
                    set: { assistant.setDeveloperMode($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modo desarrollador")
                        Text("Muestra el registro técnico, endpoints y detalles de tools.")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.textSecondary)
                    }
                }
                .tint(IysThemePreferences.active.accent)

                if assistant.developerMode {
                    NavigationLink("Registro técnico de eventos") {
                        AssistantLogSectionView()
                    }
                    LabeledContent("Modo de backend", value: store.backendMode.rawValue)
                    LabeledContent("Estado de conexión", value: store.connectionStatus.isEmpty ? "—" : store.connectionStatus)
                }

                Button("Abrir pantalla de bienvenida", role: .none) {
                    store.hasCompletedOnboarding = false
                    Task { await store.disconnect() }
                }
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showLegacySettingsSheet) {
            SettingsSheet()
                .environmentObject(store)
                .environmentObject(hostStore)
        }
        .sheet(isPresented: $showAssistantOptionsSheet) {
            NavigationStack {
                AssistantOptionsSectionView()
                    .navigationTitle("Opciones del asistente")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Listo") { showAssistantOptionsSheet = false }
                        }
                    }
            }
        }
    }
}

/// Focused sheet for configuring Google OAuth Client ID and service scopes
/// without burying it inside unrelated settings.
public struct GoogleOAuthSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var assistant: AssistantStore

    public init() {}

    public var body: some View {
        NavigationStack {
            AssistantOptionsSectionView()
                .navigationTitle("Google OAuth y opciones")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

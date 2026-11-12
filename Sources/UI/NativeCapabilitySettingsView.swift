import SwiftUI

struct NativeCapabilitySettingsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Environment(\.openURL) private var openURL
    @State private var notificationState: NativeAuthorizationState = .notRequested
    @State private var shortcutName = ""
    @State private var configuredShortcut: ConfiguredShortcut?
    @State private var confirmShortcutLaunch = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(capabilities) { capability in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: capability))
                            .foregroundStyle(color(for: capability))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(capability.title)
                                Spacer()
                                Text(capability.displayState)
                                    .font(OCTypography.metaMono)
                                    .foregroundStyle(color(for: capability))
                            }
                            Text(capability.detail)
                                .font(OCTypography.meta)
                                .foregroundStyle(OCColor.textFaint)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("iPhone nativo")
            } footer: {
                Text("Disponibilidad, permiso de iOS y aprobación de iSyCode son controles separados. El catálogo no concede acceso por sí mismo.")
            }

            Section {
                TextField("Nombre exacto del atajo", text: $shortcutName)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                Button("Guardar atajo permitido") { saveShortcut() }
                    .disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let configuredShortcut {
                    LabeledContent("Permitido", value: configuredShortcut.name)
                    Button {
                        confirmShortcutLaunch = true
                    } label: {
                        Label("Abrir en Atajos…", systemImage: "arrow.up.right.square")
                    }
                    .confirmationDialog("Abrir Atajos", isPresented: $confirmShortcutLaunch, titleVisibility: .visible) {
                        Button("Abrir \(configuredShortcut.name)") { launch(configuredShortcut) }
                        Button("Cancelar", role: .cancel) { }
                    } message: {
                        Text("iOS abrirá Shortcuts. Ese atajo puede mostrar interfaz o producir efectos externos; iSyCode no puede enumerar ni verificar su ejecución.")
                    }
                    Button("Quitar atajo permitido", role: .destructive) {
                        self.configuredShortcut = nil
                        ShortcutRegistry.remove()
                    }
                }
            } header: {
                Text("Shortcuts configurados por ti")
            } footer: {
                Text("Solo se configura este nombre. iSyCode no enumera tus atajos ni los ejecuta en segundo plano.")
            }

            Section {
                Button(notificationState == .authorized ? "Actualizar permiso" : "Permitir notificaciones") {
                    Task {
                        do {
                            notificationState = try await LocalNotificationCapability.shared.requestAuthorizationFromUserAction()
                            statusMessage = notificationState == .authorized ? "Permiso concedido por iOS." : "iOS no concedió permiso para notificaciones."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                }
                if let statusMessage {
                    Text(statusMessage).font(OCTypography.meta).foregroundStyle(OCColor.textFaint)
                }
            } header: {
                Text("Notificaciones")
            } footer: {
                Text("El permiso se solicita solo después de tocar el botón. iSyCode decide qué eventos de tarea merecen una notificación.")
            }
        }
        .navigationTitle("Capacidades nativas")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notificationState = await LocalNotificationCapability.shared.authorizationState()
            configuredShortcut = loadShortcut()
        }
    }

    private var capabilities: [NativeCapabilityDescriptor] {
        NativeCapabilityCatalog.current(
            hasExternalFolderGrant: store.sandboxFolderName != nil,
            hasConfiguredShortcut: configuredShortcut != nil,
            notificationAuthorization: notificationState
        )
    }

    private func saveShortcut() {
        let shortcut = ConfiguredShortcut(name: shortcutName)
        guard !shortcut.name.isEmpty else { return }
        configuredShortcut = shortcut
        shortcutName = ""
        ShortcutRegistry.save(shortcut)
    }

    private func loadShortcut() -> ConfiguredShortcut? {
        ShortcutRegistry.loadConfiguredShortcut()
    }

    private func launch(_ shortcut: ConfiguredShortcut) {
        guard configuredShortcut == shortcut else {
            statusMessage = "Este atajo ya no está en la lista configurada."
            return
        }
        let proposal = NativeCapabilityProposal(capabilityID: "shortcuts.configured", input: ["shortcut_id": shortcut.id])
        let decision = NativeCapabilityBroker().evaluate(
            proposal,
            catalog: capabilities,
            modelPermitted: true,
            userApproved: true // This method is reachable only from the explicit confirmation button.
        )
        guard decision == .allowed else {
            statusMessage = "iSyCode bloqueó este atajo porque su permiso local no está configurado."
            return
        }
        guard let url = ShortcutURLBuilder.runURL(shortcut: shortcut) else { return }
        openURL(url) { accepted in
            statusMessage = accepted ? "Atajos abierto. iOS no confirma aquí que la automatización terminó." : "No se pudo abrir Atajos."
        }
    }

    private func icon(for capability: NativeCapabilityDescriptor) -> String {
        capability.displayState == "Authorized" ? "checkmark.circle.fill" : "circle"
    }

    private func color(for capability: NativeCapabilityDescriptor) -> Color {
        capability.displayState == "Authorized" ? IysThemePreferences.active.accent : OCColor.textFaint
    }
}

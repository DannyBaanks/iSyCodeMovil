import SwiftUI

/// Plain-language overview of the computer sandbox, iPhone control and assistant connection.
public struct ConnectionsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @State private var sandboxLinkInput = ""
    @State private var showSandboxPanel = false

    public init() {}

    public var body: some View {
        Form {
            assistantSection
            computerSandboxSection
            mobileHostSection
        }
        .navigationTitle("Conexiones")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSandboxPanel) {
            SandboxPanelView()
                .environmentObject(store)
        }
    }

    private var assistantSection: some View {
        let runtime = store.runtimeSnapshot
        return Section {
            LabeledContent("Asistente", value: runtime.providerName)
            if assistant.developerMode, let model = runtime.modelName, !model.isEmpty {
                LabeledContent("Modelo", value: model)
            }
            LabeledContent("Estado", value: runtime.readiness.isUsableForChat ? "Listo" : "Sin configurar")
            Button("Elegir o cambiar asistente") {
                router.openRuntimeSetup(track: runtime.isLocal ? .local : .connected, providerID: runtime.providerID)
            }
        } header: {
            Text("Asistente")
        } footer: {
            Text("Puedes usar un proveedor conectado con tu clave o un modelo guardado en este iPhone.")
        }
    }

    private var computerSandboxSection: some View {
        Section {
            if let link = store.sandboxLink {
                LabeledContent("Proyecto", value: link.projectName)
                LabeledContent("Estado", value: link.remainingLabel.map { "\(link.phaseLabel) · \($0)" } ?? link.phaseLabel)
                Button("Administrar sandbox") {
                    showSandboxPanel = true
                }
            } else {
                TextField("Pega el enlace isysandbox://…", text: $sandboxLinkInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                Button("Conectar sandbox de tu computadora") {
                    let raw = sandboxLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return }
                    Task {
                        await store.connectSandboxHost(raw)
                        if store.sandboxLink != nil {
                            sandboxLinkInput = ""
                        }
                    }
                }
                .disabled(store.isConnecting || sandboxLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = store.sandboxLinkError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.danger)
            }

            Button {
                router.showSandboxExplanationSheet = true
            } label: {
                Label("¿Qué es el sandbox?", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Computadora (Sandbox)")
        } footer: {
            Text("Conecta una carpeta de tu computadora para que el asistente edite y ejecute pruebas en un espacio aislado.")
        }
    }

    private var mobileHostSection: some View {
        Section {
            MobileHostPairingSection()
        } header: {
            Text("Servidor de conversaciones")
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Plain-language overview of the computer sandbox, iPhone control and assistant connection.
public struct ConnectionsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var loopback = LoopbackDeviceSession.shared
    @State private var sandboxLinkInput = ""
    @State private var showSandboxPanel = false
    @State private var showPairingImporter = false

    public init() {}

    public var body: some View {
        Form {
            assistantSection
            computerSandboxSection
            loopbackSection
            mobileHostSection
        }
        .navigationTitle("Conexiones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loopback.refreshState() }
        .sheet(isPresented: $showSandboxPanel) {
            SandboxPanelView()
                .environmentObject(store)
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: [.propertyList, .xml, .data]
        ) { result in
            if case .success(let url) = result {
                loopback.importPairingFile(from: url)
            }
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

    private var loopbackSection: some View {
        Section {
            LabeledContent("Archivo de emparejamiento", value: loopback.hasPairingFile ? "Cargado" : "Falta importar")
            LabeledContent("VPN loopback (10.7.0.1)", value: loopback.loopbackVPNActive ? "Activa" : "Inactiva")
            if loopback.tailscaleActive && !loopback.loopbackVPNActive {
                Label("Tailscale está usando la VPN de iOS. Apágalo un momento mientras usas LocalDevVPN.", systemImage: "exclamationmark.triangle")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.warning)
            }

            Button(loopback.hasPairingFile ? "Reemplazar pairingFile.plist" : "Importar pairingFile.plist") {
                showPairingImporter = true
            }

            if loopback.hasPairingFile {
                Button {
                    Task { await loopback.launchWDAOverLoopback() }
                } label: {
                    if loopback.isBusy {
                        ProgressView()
                    } else {
                        Label("Arrancar WDA desde este iPhone", systemImage: "play.circle")
                    }
                }
                .disabled(loopback.isBusy)

                Button {
                    Task { await loopback.testScreenshotOverLoopback() }
                } label: {
                    Label("Probar captura por túnel", systemImage: "camera")
                }
                .disabled(loopback.isBusy)

                Button("Eliminar pairingFile.plist", role: .destructive) {
                    loopback.removePairingFile()
                }
            }

            if let msg = loopback.statusMessage {
                Text(msg)
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.success)
            }
            if let err = loopback.errorMessage {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.danger)
            }

            if let url = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044") {
                Link(destination: url) {
                    Label("Descargar LocalDevVPN", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Sin computadora (VPN loopback)")
        } footer: {
            Text("Permite hablar con este iPhone usando idevice + LocalDevVPN y un pairingFile.plist generado una sola vez en tu PC. Una vez que WDA arranque, puedes apagar LocalDevVPN y volver a encender Tailscale.")
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

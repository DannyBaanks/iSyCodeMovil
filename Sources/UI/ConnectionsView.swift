import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Plain-language overview of the computer sandbox, iPhone control and assistant connection.
public struct ConnectionsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @ObservedObject private var loopback = LoopbackDeviceSession.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthStore.shared
    @ObservedObject private var isymcp = ISyMCPStore.shared
    @ObservedObject private var vault = SecretVaultStore.shared
    @ObservedObject private var recorder = ActionRecorderService.shared
    @State private var sandboxLinkInput = ""
    @State private var isymcpServerInput = ISyMCPStore.shared.serverURLString
    @State private var isymcpCodeInput = ""
    @State private var showSandboxPanel = false
    @State private var showPairingImporter = false
    @State private var isActivatingChatGPT = false
    @State private var chatGPTActivationFeedback: String?

    public init() {}

    public var body: some View {
        Form {
            assistantSection
            chatGPTOAuthSection
            vaultAndRecorderSection
            isymcpRemoteSection
            computerSandboxSection
            loopbackSection
            mobileHostSection
        }
        .refreshable {
            loopback.refreshState()
            await store.refreshRuntimeIntent()
            await store.refreshSandboxStatus()
            if isymcp.isPaired {
                await isymcp.refresh()
            }
        }
        .navigationTitle("Conexiones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loopback.refreshState()
            if isymcp.isPaired {
                Task { await isymcp.refresh() }
            }
        }
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

    private var chatGPTOAuthSection: some View {
        Section {
            LabeledContent("Suscripción ChatGPT", value: chatgptOAuth.isSignedIn ? "Conectada" : "Sin conectar")
            if let code = chatgptOAuth.userCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Código de autorización:")
                        .font(OCTypography.meta)
                        .foregroundStyle(OCColor.textFaint)
                    Text(code)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)

                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = code
                    #endif
                    openURL(ChatGPTOAuthStore.verificationURL)
                } label: {
                    Label("Copiar código y abrir OpenAI", systemImage: "safari")
                }

                Button("Cancelar", role: .cancel) {
                    chatgptOAuth.cancelLogin()
                }
            } else if chatgptOAuth.isPolling {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Esperando confirmación…")
                        .font(OCTypography.meta)
                }
                Button("Cancelar", role: .cancel) {
                    chatgptOAuth.cancelLogin()
                }
            } else if chatgptOAuth.isSignedIn {
                Button {
                    guard !isActivatingChatGPT else { return }
                    isActivatingChatGPT = true
                    chatGPTActivationFeedback = "Consultando modelos disponibles…"
                    Task {
                        let ok = await store.startSandbox(providerID: "chatgpt-oauth", apiKey: nil)
                        isActivatingChatGPT = false
                        if ok {
                            let models = ChatGPTOAuthStore.storedModelIDs()
                            chatGPTActivationFeedback = models.isEmpty
                                ? "Activado."
                                : "Activado · Modelos: \(models.prefix(4).joined(separator: ", "))"
                        } else {
                            chatGPTActivationFeedback = store.sandboxSetupError
                                ?? chatgptOAuth.lastDiscoveryError
                                ?? "No se pudo activar ChatGPT OAuth."
                        }
                    }
                } label: {
                    HStack {
                        Label("Activar ChatGPT Plus/Pro (OAuth)", systemImage: "bolt.fill")
                        if isActivatingChatGPT {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isActivatingChatGPT)
                if let feedback = chatGPTActivationFeedback {
                    Text(feedback)
                        .font(OCTypography.meta)
                        .foregroundStyle(store.sandboxSetupError != nil || chatgptOAuth.lastDiscoveryError != nil ? OCColor.danger : OCColor.success)
                }
                Button("Cerrar sesión ChatGPT", role: .destructive) {
                    chatGPTActivationFeedback = nil
                    chatgptOAuth.signOut()
                }
            } else {
                Button {
                    chatgptOAuth.startDeviceLogin()
                } label: {
                    Label("Conectar ChatGPT Plus/Pro (OAuth)", systemImage: "person.badge.key")
                }
            }

            if let msg = chatgptOAuth.statusMessage {
                Text(msg)
                    .font(OCTypography.meta)
                    .foregroundStyle(OCColor.textSecondary)
            }
            if let err = chatgptOAuth.errorMessage {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(OCTypography.meta)
                    .foregroundStyle(OCColor.danger)
            }
        } header: {
            Text("ChatGPT Plus/Pro (OAuth)")
        } footer: {
            Text("Inicia sesión con tu cuenta ChatGPT Plus o Pro usando el flujo de dispositivo de Codex para usar los modelos reales de tu cuenta con tu suscripción semanal sin pagar API key.")
        }
    }

    private var isymcpRemoteSection: some View {
        Section {
            if isymcp.isPaired {
                LabeledContent("Estado", value: isymcp.statusSummary ?? "Emparejado")
                LabeledContent("Compuerta Shell (PC)", value: isymcp.shellGateOpen ? "Abierta" : "Cerrada")
                LabeledContent("Compuerta Consolas", value: isymcp.agentsGateOpen ? "Abierta" : "Cerrada")

                if let taint = isymcp.taintSummary {
                    Label("Contenido externo (taint): \(taint)", systemImage: "exclamationmark.shield.fill")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.warning)
                    Button {
                        Task { await isymcp.clearTaint() }
                    } label: {
                        Label("Limpiar marca taint (Face ID)", systemImage: "faceid")
                    }
                    .disabled(isymcp.isBusy)
                }

                if isymcp.pendingGatesCount > 0 {
                    Label("\(isymcp.pendingGatesCount) solicitud(es) esperando permiso en tu PC", systemImage: "hand.raised.fill")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.warning)
                }

                Button {
                    Task { await isymcp.grantOnce(capability: "shell", uses: 1) }
                } label: {
                    Label("Dar 1 uso de shell en PC (Face ID)", systemImage: "faceid")
                }
                .disabled(isymcp.isBusy)

                Button {
                    Task { await isymcp.grantOnce(capability: "agents", uses: 1) }
                } label: {
                    Label("Dar 1 uso de consolas TUI (Face ID)", systemImage: "faceid")
                }
                .disabled(isymcp.isBusy)

                if !isymcp.recentTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TAREAS RECIENTES EN ISYMCP")
                            .font(OCTypography.sectionLabel)
                            .foregroundColor(OCColor.textFaint)
                        ForEach(Array(isymcp.recentTasks.prefix(3).enumerated()), id: \.offset) { _, task in
                            let title = (task["title"] as? String) ?? (task["prompt"] as? String) ?? (task["id"] as? String) ?? "Tarea"
                            let status = (task["status"] as? String) ?? "pendiente"
                            HStack {
                                Text(title)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Spacer()
                                Text(status)
                                    .font(OCTypography.metaMono)
                                    .foregroundColor(OCColor.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button("Actualizar estado de ISyMCP") {
                    Task { await isymcp.refresh() }
                }
                .disabled(isymcp.isRefreshing)

                Button("Desemparejar ISyMCP", role: .destructive) {
                    isymcp.unpair()
                }
            } else {
                TextField("IP de Tailscale de tu PC (ej. 100.x.x.x:8797)", text: $isymcpServerInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13.5, design: .monospaced))

                TextField("Código de 6 caracteres (isymcp phone pair)", text: $isymcpCodeInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))

                Button {
                    Task { await isymcp.pair(rawServer: isymcpServerInput, code: isymcpCodeInput) }
                } label: {
                    HStack {
                        Label("Emparejar ISyMCP con Face ID", systemImage: "faceid")
                        if isymcp.isBusy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isymcp.isBusy || isymcpServerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isymcpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let err = isymcp.errorMessage {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.danger)
            }
        } header: {
            Text("ISyMCP en tu PC (Tailscale + Face ID)")
        } footer: {
            Text("Conecta con `isymcp` en tu computadora por Tailscale (:8797) usando llaves ECDSA en el Secure Enclave para autorizar shell, consolas y tareas pesadas con Face ID.")
        }
    }

    private var vaultAndRecorderSection: some View {
        Section {
            LabeledContent("Credenciales en Llavero", value: "\(vault.entries.count) guardadas")
            Button {
                router.openSecretVault()
            } label: {
                Label("Administrar Llavero (Keychain + Face ID)", systemImage: "key.fill")
            }

            LabeledContent("Acciones aprendidas", value: "\(recorder.savedSessions.count) flujos")
            Button {
                router.openLearnAction()
            } label: {
                Label("Aprender acción nueva (WDA polling)", systemImage: "record.circle")
            }
        } header: {
            Text("Llavero y Automatización visual")
        } footer: {
            Text("Las contraseñas del Llavero nunca viajan al modelo ni se exportan en `.isyagent.json`. Solo se inyectan con tu confirmación y Face ID.")
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

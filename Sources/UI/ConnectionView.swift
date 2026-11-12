import SwiftUI

public struct ConnectionView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var pairingLink = ""
    @State private var showReconnectSheet = false
    @State private var showSandboxSheet = false
    @State private var showDesktopLink = false
    @FocusState private var fieldFocused: Bool
    
    public init() {}
    
    public var body: some View {
        ZStack {
            OCColor.bgDeep.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 36)
                
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(IysThemePreferences.active.accent)
                        .overlay {
                            Text("IS")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .foregroundColor(OCColor.onAccent)
                        }
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ISYCODE")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .tracking(1.6)
                            .foregroundColor(OCColor.textPrimary)
                        Text("Móvil · el escritorio en el bolsillo")
                            .font(.system(size: 12))
                            .foregroundColor(OCColor.textSecondary)
                    }
                }
                
                Spacer().frame(height: 22)

                door(
                    icon: "desktopcomputer",
                    title: "Ver el agente de mi computadora",
                    subtitle: "Pega el enlace de OpenCode. La terminal de la computadora se queda abierta."
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { showDesktopLink.toggle() }
                }

                if showDesktopLink {
                    VStack(alignment: .leading, spacing: 0) {
                
                // Stored pairing section
                if store.backendMode == .unconfigured {
                    StoredPairingSection(showReconnectSheet: $showReconnectSheet)
                        .padding(.bottom, 24)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Abre la terminal en la carpeta del proyecto.")
                    step(2, "Hace falta Node.js y OpenCode. Deja esa ventana abierta.")
                    step(3, "Pega este comando.")
                    step(4, "Copia el enlace que imprima y pégalo aquí. No lo reenvíes: lleva la contraseña.")
                }
                .padding(.bottom, 14)

                HStack {
                    label("COMANDO")
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "npx --yes github:DannyBaanks/IysCodeMovil link"
                    } label: {
                        Text("Copiar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(OCColor.borderBase, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                commandBox("npx --yes github:DannyBaanks/IysCodeMovil link")
                
                Spacer().frame(height: 24)
                
                HStack {
                    label("ENLACE DE CONEXIÓN")
                    Spacer()
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            pairingLink = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text("Pegar")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                TextField("iyscodemovil://pair?...", text: $pairingLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .scrollDismissesKeyboard(.interactively)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r10).stroke(OCColor.borderBase, lineWidth: 1))
                
                Button { connect() } label: {
                    HStack {
                        Text(store.isConnecting ? "Conectando…" : "Revisar enlace")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                }
                .buttonStyle(.plain)
                .disabled(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .padding(.top, 10)
                
                ConnectionStatusLine(status: store.connectionStatus)
                    }
                    .padding(14)
                    .background(OCColor.bgBase.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                door(
                    icon: "iphone",
                    title: "Hablar con GUS aquí",
                    subtitle: "Sin internet. El modelo vive en este iPhone."
                ) {
                    showSandboxSheet = true
                }
                .padding(.top, 12)

                Text("El PIN del host de iSyCode ya funciona. Las conversaciones llegan con el escritorio.")
                    .font(.system(size: 13))
                    .foregroundColor(OCColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                    .padding(.bottom, 10)

                MobileHostPairingSection()
                
                Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = false }
        .task {
            if await store.hasStoredPairing() {
                showDesktopLink = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { fieldFocused = false }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
        }
        .sheet(isPresented: $showReconnectSheet) {
            ReconnectSheet(isPresented: $showReconnectSheet)
        }
        .sheet(isPresented: $showSandboxSheet) {
            SandboxKeySheet(initialProviderID: "gus-local")
        }
    }
    
    private func connect() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !store.isConnecting else { return }
        fieldFocused = false
        store.offeredPairingLink = link
    }

    private func door(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(IysThemePreferences.active.accent.opacity(0.14))
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(IysThemePreferences.active.accent)
                    )
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(OCColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(14)
            .background(OCColor.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
            .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderBase, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(OCColor.onAccent)
                .frame(width: 22, height: 22)
                .background(IysThemePreferences.active.accent)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundColor(Color.white.opacity(0.42))
            .padding(.bottom, 8)
    }
    
    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .foregroundColor(Color.white.opacity(0.38))
            Text(command)
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(12)
        .background(OCColor.bgBase)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}

struct StoredPairingSection: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var showReconnectSheet: Bool
    @State private var hasStored = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasStored {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Volver a conectar")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Hay un equipo guardado en este iPhone")
                            .font(.system(size: 13))
                            .foregroundColor(OCColor.textSecondary)
                    }
                    Spacer()
                    Button("Conectar") {
                        Task { await store.reconnectStoredPairing() }
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(IysThemePreferences.active.accent)
                    .cornerRadius(OCRadius.r8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(OCColor.bgBase)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderMuted, lineWidth: 1))
                
                HStack {
                    Button("Olvidar") {
                        Task {
                            await store.forgetPairing()
                            hasStored = false
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.4))
                    Spacer()
                    Button("Usar otro enlace") {
                        showReconnectSheet = true
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(OCColor.agentBuild)
                }
                .padding(.horizontal, 12)
            }
        }
        .onAppear {
            Task { hasStored = await store.hasStoredPairing() }
        }
    }
}

struct ReconnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var isPresented: Bool
    @State private var pairingLink = ""
    @FocusState private var fieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 36)
                
                Text("Otro equipo")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                
                Spacer().frame(height: 24)
                
                HStack {
                    label("COMANDO")
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "npx --yes github:DannyBaanks/IysCodeMovil link"
                    } label: {
                        Text("Copiar")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                commandBox("npx --yes github:DannyBaanks/IysCodeMovil link")
                
                Text("Corre el comando en la carpeta del proyecto. Hace falta Node.js y OpenCode, y la terminal tiene que quedarse abierta. Pega aquí el enlace completo. No lo reenvíes: lleva la contraseña.")
                    .font(.system(size: 14))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                
                Spacer().frame(height: 24)
                
                HStack {
                    label("ENLACE")
                    Spacer()
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            pairingLink = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text("Pegar")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                TextField("iyscodemovil://pair?...", text: $pairingLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .scrollDismissesKeyboard(.interactively)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                
                Button { connect() } label: {
                    HStack {
                        Text(store.isConnecting ? "Conectando…" : "Revisar enlace")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                }
                .buttonStyle(.plain)
                .disabled(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .padding(.top, 10)
                
                ConnectionStatusLine(status: store.connectionStatus)
                
                Spacer()
            }
            .padding(.horizontal, 18)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private func connect() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !store.isConnecting else { return }
        fieldFocused = false
        store.offeredPairingLink = link
        dismiss()
    }
    
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundColor(Color.white.opacity(0.42))
            .padding(.bottom, 8)
    }
    
    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .foregroundColor(Color.white.opacity(0.38))
            Text(command)
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(12)
        .background(OCColor.bgBase)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}

struct SandboxKeySheet: View {
    var initialProviderID: String = "gus-local"
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var key = ""
    @State private var hasKey = false
    @State private var isStarting = false
    @State private var selectedProviderID = "gus-local"
    @State private var showProviderDirectory = false
    @StateObject private var gusModelManager = GUSModelDownloadManager.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 28)
                Text("GUS en este iPhone")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Text("GUS trabaja sin internet. Si eliges un proveedor en la nube, la clave se guarda en el llavero y lo que escribas sale hacia ese proveedor.")
                    .font(.system(size: 15))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                Spacer().frame(height: 24)
                HStack {
                    Text("PROVEEDOR")
                    Spacer()
                    Button { showProviderDirectory = true } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 18))
                            .foregroundColor(IysThemePreferences.active.accent)
                    }
                    .accessibilityLabel("Ver proveedores compatibles")
                }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(Color.white.opacity(0.42))
                    .padding(.bottom, 8)

                Picker("Proveedor", selection: $selectedProviderID) {
                    ForEach(SandboxModelProvider.sandboxOptions) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .tint(IysThemePreferences.active.accent)
                .padding(.bottom, 12)

                if selectedProviderID == "gus-local" {
                    GUSModelDownloadView(manager: gusModelManager)
                } else if let provider = SandboxModelProvider.provider(id: selectedProviderID) {
                    Text(provider.description)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                    SecureField(hasKey ? "clave guardada; pega otra para reemplazarla" : provider.keyPlaceholder, text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .padding(12)
                    .background(OCColor.bgBase)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))

                    Link(destination: provider.apiKeyURL) {
                        Label("Obtener clave de \(provider.name)", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(IysThemePreferences.active.accent)
                            .padding(.top, 10)
                    }
                }

                Button {
                    fieldFocused = false
                    let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    isStarting = true
                    store.sandboxSetupError = nil
                    Task {
                        let started = await store.startSandbox(
                            providerID: selectedProviderID,
                            apiKey: typed.isEmpty ? nil : typed
                        )
                        isStarting = false
                        if started { dismiss() }
                    }
                } label: {
                    HStack {
                        Text(isStarting ? "Abriendo…" : (selectedProviderID == "gus-local"
                            ? "Usar GUS"
                            : (hasKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Entrar con la clave guardada" : "Guardar y entrar")))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                }
                .buttonStyle(.plain)
                .disabled(!canStartSandbox)
                .opacity(canStartSandbox || isStarting ? 1 : 0.5)
                .padding(.top, 12)

                if let error = store.sandboxSetupError {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                Button {
                    isStarting = true
                    store.sandboxSetupError = nil
                    Task {
                        await store.useNativeDemoRuntime()
                        isStarting = false
                        if store.backendMode == .native, store.connectionHealth == .connected {
                            dismiss()
                        } else {
                            store.sandboxSetupError = store.connectionStatus.isEmpty
                                ? "No pude iniciar el sandbox. Inténtalo de nuevo."
                                : store.connectionStatus
                        }
                    }
                } label: {
                    Text("Ver el guion de demo")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }
                .buttonStyle(.plain)

                Spacer()
            }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .font(.system(size: 14))
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showProviderDirectory) { ProviderDirectoryView() }
        .onAppear {
            selectedProviderID = initialProviderID
            store.sandboxSetupError = nil
            refreshProviderKeyState()
        }
        .onChange(of: selectedProviderID) { _ in refreshProviderKeyState() }
    }

    private func refreshProviderKeyState() {
        guard selectedProviderID != "gus-local" else { hasKey = false; return }
        Task {
            if let persistence = try? IOSPersistence() {
                let saved = try? await persistence.loadAPIKey(provider: selectedProviderID)
                hasKey = !(saved ?? "").isEmpty
            }
        }
    }

    private var canStartSandbox: Bool {
        guard !isStarting else { return false }
        if selectedProviderID == "gus-local" { return gusModelManager.installedModelURL != nil }
        return hasKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ConnectionStatusHint {
    static func nextStep(for status: String) -> String? {
        let text = status.lowercased()
        if text.contains("127.0.0.1") || text.contains("localhost") {
            return "Esa dirección es la computadora misma. En el iPhone usa la IP de tu Wi-Fi o la de Tailscale."
        }
        if text.contains("401") || text.contains("unauthorized") {
            return "Ese enlace ya no sirve. Vuelve a correr el comando en la computadora y pega el nuevo."
        }
        if text.contains("timed out") || text.contains("timeout") || text.contains("could not connect")
            || text.contains("connection refused") || text.contains("network connection") {
            return "Deja abierta la terminal del comando, y pon el iPhone en la misma red o en Tailscale."
        }
        if text.contains("invalid") || text.contains("missing required") || text.contains("pairing") {
            return "Copia la línea completa que empieza por iyscodemovil://, codex:// o grok://."
        }
        return nil
    }
}

struct ConnectionStatusLine: View {
    let status: String

    var body: some View {
        if !status.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(status)
                    .font(.system(size: 14))
                    .foregroundColor(looksLikeError ? OCColor.danger : OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = ConnectionStatusHint.nextStep(for: status) {
                    Text(hint)
                        .font(.system(size: 14))
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
        }
    }

    private var looksLikeError: Bool {
        let text = status.lowercased()
        return text.hasPrefix("error") || text.contains("failed") || text.contains("invalid")
    }
}

struct PairingOfferSummary {
    let kind: String
    let hostLine: String
    let directory: String
    let notice: String

    init(link: String) throws {
        let (type, pairing) = try WorkbenchBackendFactory.parsePairingURL(link)
        switch pairing {
        case .openCode(let value):
            kind = type.displayName
            hostLine = "\(value.scheme)://\(value.host):\(value.port)"
            directory = value.directory
            notice = value.scheme == "http"
                ? "Este enlace va por HTTP. Úsalo solo en tu Wi-Fi o en una VPN. No lo reenvíes: incluye la contraseña."
                : "La conexión va cifrada. No reenvíes el enlace: incluye la contraseña."
        case .codex(let value):
            kind = "Codex"
            hostLine = "\(value.host):\(value.port)"
            directory = value.directory
            notice = "Codex usa la dirección de Tailscale. No reenvíes el enlace: incluye un token."
        case .grok(let value):
            kind = "Grok"
            hostLine = "\(value.host):\(value.port)"
            directory = value.directory
            notice = "Grok se queda en la computadora. El iPhone entra por Tailscale. No reenvíes el enlace: incluye un token."
        case .remote(let value):
            kind = value.type.displayName
            hostLine = "\(value.scheme)://\(value.host):\(value.port)"
            directory = value.directory
            notice = value.scheme == "http"
                ? "Este enlace va por HTTP. Úsalo solo en tu Wi-Fi o en una VPN. No lo reenvíes."
                : "Revisa el equipo antes de continuar. No reenvíes el enlace."
        }
    }
}

public struct PairingConfirmSheet: View {
    public let link: String
    @EnvironmentObject private var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var summary: PairingOfferSummary?
    @State private var parseError: String?

    public init(link: String) {
        self.link = link
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("¿Conectar este equipo?")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                if let parseError {
                    Text(parseError)
                        .font(.system(size: 15))
                        .foregroundColor(OCColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = ConnectionStatusHint.nextStep(for: parseError) {
                        Text(hint)
                            .font(.system(size: 15))
                            .foregroundColor(OCColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let summary {
                    offerRow("Tipo", summary.kind)
                    offerRow("Equipo", summary.hostLine)
                    offerRow("Carpeta", summary.directory.isEmpty ? "La carpeta donde corriste el comando" : summary.directory)
                    Text(summary.notice)
                        .font(.system(size: 15))
                        .foregroundColor(OCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        let pending = link
                        store.offeredPairingLink = nil
                        Task { await store.connectRemote(pending) }
                    } label: {
                        Text("Conectar")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OCColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(IysThemePreferences.active.accent)
                            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isConnecting)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        store.offeredPairingLink = nil
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: parse)
    }

    private func offerRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OCColor.textFaint)
            Text(value)
                .font(.system(size: 15))
                .foregroundColor(OCColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func parse() {
        do {
            summary = try PairingOfferSummary(link: link)
        } catch {
            parseError = error.localizedDescription
        }
    }
}

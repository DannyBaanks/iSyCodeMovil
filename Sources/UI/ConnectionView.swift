import SwiftUI

public struct ConnectionView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var pairingLink = ""
    @State private var showReconnectSheet = false
    @State private var showSandboxSheet = false
    @State private var showLegacyBridge = false
    @FocusState private var fieldFocused: Bool
    
    public init() {}
    
    public var body: some View {
        ZStack {
            OCColor.bgDeep.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 36)
                
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(IysThemePreferences.active.accent.opacity(0.14))
                        .overlay {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(IysThemePreferences.active.accent)
                        }
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("iSyCode Móvil")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Text("Tu miniagente de desarrollo")
                            .font(.system(size: 11))
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                
                Spacer().frame(height: 24)

                MobileHostPairingSection()
                    .padding(.bottom, 24)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showLegacyBridge.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text("Más opciones de conexión")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showLegacyBridge ? 180 : 0))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OCColor.textSecondary)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showLegacyBridge {
                    VStack(alignment: .leading, spacing: 0) {
                
                // Stored pairing section
                if store.backendMode == .unconfigured {
                    StoredPairingSection(showReconnectSheet: $showReconnectSheet)
                        .padding(.bottom, 24)
                }
                
                HStack {
                    label("CONECTAR CON BRIDGE ANTERIOR")
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
                
                Text("Ejecuta este comando en la carpeta del proyecto, en el equipo donde ya tienes ISyCode. Después pega aquí el enlace que aparezca.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                
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
                        Text(store.isConnecting ? "Conectando…" : "Conectar")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.bgDeep)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                }
                .buttonStyle(.plain)
                .disabled(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .padding(.top, 10)
                
                if !store.connectionStatus.isEmpty {
                    Text(store.connectionStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(store.connectionStatus.lowercased().hasPrefix("error") ? .red : Color.white.opacity(0.5))
                        .padding(.top, 10)
                }
                    }
                    .padding(14)
                    .background(OCColor.bgBase.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                HStack(spacing: 12) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    Text("O")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                }
                .padding(.vertical, 26)
                
                Button {
                    showSandboxSheet = true
                } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(IysThemePreferences.active.accent.opacity(0.12))
                            .overlay(Image(systemName: "cube.transparent").foregroundColor(IysThemePreferences.active.accent))
                            .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Probar en este iPhone")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(OCColor.textPrimary)
                            Text("Configura un modelo de prueba sin conectar tu equipo")
                                .font(.system(size: 10))
                                .foregroundColor(OCColor.textFaint)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(OCColor.textFaint)
                    }
                    .padding(12)
                    .background(OCColor.bgBase)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r14))
                    .overlay(RoundedRectangle(cornerRadius: OCRadius.r14).stroke(OCColor.borderMuted, lineWidth: 1))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                    Text("La conexión usa tu equipo. El entorno de prueba usa un modelo y archivos de este iPhone.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.28))
                    .padding(.bottom, 8)
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
        }
        .sheet(isPresented: $showReconnectSheet) {
            ReconnectSheet(isPresented: $showReconnectSheet)
        }
        .sheet(isPresented: $showSandboxSheet) {
            SandboxKeySheet()
        }
    }
    
    private func connect() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !store.isConnecting else { return }
        fieldFocused = false
        Task { await store.connectRemote(link) }
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
        .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1))
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
                        Text("reconnect to desktop")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.5))
                        Text("paired workspace")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.7))
                    }
                    Spacer()
                    Button("reconnect") {
                        Task { await store.reconnectStoredPairing() }
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(OCColor.bgDeep)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(IysThemePreferences.active.accent)
                    .cornerRadius(OCRadius.r8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(OCColor.bgBase)
                .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
                
                HStack {
                    Button("forget connection") {
                        Task {
                            await store.forgetPairing()
                            hasStored = false
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.4))
                    Spacer()
                    Button("link another desktop") {
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
                
                Text("link another desktop")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                
                Spacer().frame(height: 24)
                
                HStack {
                    label("LINK DESKTOP")
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "npx --yes github:DannyBaanks/IysCodeMovil link"
                    } label: {
                        Text("copy")
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
                
                Text("Run it in the project directory on the computer that already has IysCode installed. Paste the pairing link printed by the command.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                
                Spacer().frame(height: 24)
                
                HStack {
                    label("PAIRING LINK")
                    Spacer()
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            pairingLink = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text("paste")
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
                        Text(store.isConnecting ? "connecting..." : "connect")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.bgDeep)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
                }
                .buttonStyle(.plain)
                .disabled(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(store.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .padding(.top, 10)
                
                if !store.connectionStatus.isEmpty {
                    Text(store.connectionStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(store.connectionStatus.lowercased().hasPrefix("error") ? .red : Color.white.opacity(0.5))
                        .padding(.top, 10)
                }
                
                Spacer()
            }
            .padding(.horizontal, 18)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private func connect() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !store.isConnecting else { return }
        fieldFocused = false
        Task { await store.connectRemote(link) }
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
        .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

struct SandboxKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var key = ""
    @State private var hasKey = false
    @State private var isStarting = false
    @State private var selectedProviderID = "nvidia"
    @State private var showProviderDirectory = false
    @StateObject private var gusModelManager = GUSModelDownloadManager.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 28)
                Text("sandbox")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text("Elige un proveedor para el modelo del sandbox. Las claves se guardan en el llavero de iOS.")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
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
                        Text(isStarting ? "abriendo sandbox..." : (selectedProviderID == "gus-local"
                            ? "usar GUS local"
                            : (hasKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "entrar con la clave guardada" : "guardar y entrar")))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(OCColor.bgDeep)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(IysThemePreferences.active.accent)
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
                    Text("ver el guion de demo")
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
                    Button("cancel") { dismiss() }
                        .font(.system(size: 14, design: .monospaced))
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showProviderDirectory) { ProviderDirectoryView() }
        .onAppear {
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

import SwiftUI

public struct MobileHostPairingSection: View {
    @EnvironmentObject private var hostStore: MobileHostStore
    @State private var hostURL = ""
    @State private var pairingCode = ""
    @State private var enteringNewCode = false

    public init() {}

    private var accent: Color { IysThemePreferences.active.accent }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(accent.opacity(0.14))
                    Image(systemName: hostStore.credential == nil ? "link" : "checkmark.shield.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(accent)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(hostStore.credential == nil ? "Conectar mi equipo" : "Equipo conectado")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.textPrimary)
                    Text(hostStore.credential == nil ? "Usa la dirección del host y el PIN" : "ISYCODE HOST")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(OCColor.textFaint)
                }
                Spacer()
                if hostStore.credential != nil {
                    statusBadge(heartbeatLabel)
                }
            }

            if let credential = hostStore.credential, !enteringNewCode {
                pairedCard(credential)
            } else {
                pairingForm
            }

            if let message = hostStore.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(OCColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: OCRadius.r18)
                .fill(LinearGradient(
                    colors: [OCColor.bgBase, accent.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        }
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r18).stroke(OCColor.borderBase, lineWidth: 1))
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pega la dirección del host y el PIN de seis dígitos para comenzar.")
                .font(.system(size: 12))
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            inputField(icon: "network") {
                TextField("https://host/isycode", text: $hostURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(OCColor.textPrimary)
            }

            inputField(icon: "number") {
                TextField("Código de emparejamiento", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(OCColor.textPrimary)
                    .onChange(of: pairingCode) { value in
                        pairingCode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    }
            }

            Button {
                Task { await hostStore.pair(baseURL: hostURL, code: pairingCode) }
            } label: {
                HStack(spacing: 8) {
                    if hostStore.isPairing {
                        ProgressView().tint(OCColor.bgDeep)
                    } else {
                        Text("Conectar")
                        Image(systemName: "arrow.right")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OCColor.bgDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(accent.gradient)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
            }
            .buttonStyle(.plain)
            .disabled(hostStore.isPairing || pairingCode.count != 6 || hostURL.isEmpty)
            .opacity(hostStore.isPairing || pairingCode.count != 6 || hostURL.isEmpty ? 0.55 : 1)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lock.shield")
                    .foregroundColor(accent)
                Text("Puedes incluir una ruta base como /isycode. Los hosts remotos requieren HTTPS de confianza.")
                    .foregroundColor(OCColor.textFaint)
            }
            .font(.system(size: 10, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)

            if enteringNewCode {
                Button("Cancelar") { enteringNewCode = false }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(OCColor.textSecondary)
            }
        }
    }

    private func inputField<Field: View>(icon: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OCColor.textFaint)
                .frame(width: 18)
            field()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(OCColor.bgDeep.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
        .overlay(RoundedRectangle(cornerRadius: OCRadius.r10).stroke(OCColor.borderMuted, lineWidth: 1))
    }

    private func pairedCard(_ credential: MobileHostCredential) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            connectionRow("Host", value: hostStore.hostLiveness.rawValue.capitalized, icon: "desktopcomputer")
            connectionRow("Este iPhone", value: heartbeatLabel.capitalized, icon: "iphone")
            connectionRow("Transporte", value: URLComponents(string: credential.baseURL)?.scheme?.uppercased() ?? "HTTPS", icon: "lock.fill")
            connectionRow("Key ID", value: credential.keyID, icon: "key.fill")
            connectionRow("Vence", value: credential.expirationDate?.formatted(date: .abbreviated, time: .shortened) ?? credential.expiresAt, icon: "clock")

            Label("Sesiones y ejecución remota: próximamente", systemImage: "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(OCColor.textFaint)
                .padding(.top, 2)

            HStack {
                Button("Olvidar en este iPhone", role: .destructive) {
                    Task { await hostStore.forgetCredential() }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(OCColor.danger)
                Spacer()
                Button("Cambiar PIN") {
                    hostURL = credential.baseURL
                    enteringNewCode = true
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(OCColor.textSecondary)
            }
            .padding(.top, 2)
        }
    }

    private func connectionRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(OCColor.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(OCColor.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func statusBadge(_ rawValue: String) -> some View {
        Text(rawValue.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundColor(rawValue == MobileHeartbeatState.connected.rawValue ? OCColor.success : OCColor.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(OCColor.bgLayer1)
            .clipShape(Capsule())
    }

    private var heartbeatLabel: String {
        switch hostStore.heartbeatState {
        case .notPaired: return "sin emparejar"
        case .connecting: return "conectando"
        case .connected: return "conectado"
        case .paused: return "en pausa"
        case .unavailable: return "sin conexión"
        case .credentialRejected: return "credencial rechazada"
        case .expired: return "credencial vencida"
        }
    }
}

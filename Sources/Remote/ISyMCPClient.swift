import CryptoKit
import Foundation
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum ISyMCPKeyKind: String, Sendable {
    case read
    case approve
}

public struct ISyMCPAPIError: LocalizedError, Sendable, Equatable {
    public let code: String
    public let detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var errorDescription: String? {
        let friendly: [String: String] = [
            "not_tailscale": "Conéctate a Tailscale en el iPhone para hablar con ISyMCP en tu PC.",
            "unknown_device": "Este iPhone ya no está emparejado con ISyMCP. Empareja de nuevo con isymcp phone pair.",
            "wrong_node": "La llave pertenece a otro nodo de Tailscale.",
            "stale_request": "La hora del iPhone no coincide con la de tu computadora.",
            "approve_required": "Esta acción requiere confirmación biométrica (Face ID).",
            "no_pairing": "No hay código activo en tu PC: ejecuta `isymcp phone pair`.",
            "expired": "El código de emparejamiento caducó: genera uno nuevo con `isymcp phone pair`.",
            "too_many_attempts": "Demasiados intentos: genera otro código en tu PC.",
            "bad_code": "El código de emparejamiento no coincide.",
            "not_paired": "ISyMCP (PC) no está conectado todavía. Para compilar código nativo, usar shell o correr procesos pesados, empareja tu PC en Conexiones → ISyMCP."
        ]
        return friendly[code] ?? (detail.map { "\(code): \($0)" } ?? code)
    }
}

/// Manages the two P-256 device keys (`read` and Face ID-protected `approve`) in Secure Enclave,
/// falling back to Keychain-stored P256 software keys only when Secure Enclave hardware is unavailable (Simulator/tests).
public final class ISyMCPDeviceKeys: @unchecked Sendable {
    public static let shared = ISyMCPDeviceKeys()
    private let service = "com.isyco.iyscodemovil.isymcp.keys"

    public init() {}

    public func publicKeyBase64(_ kind: ISyMCPKeyKind) throws -> String {
        if SecureEnclave.isAvailable {
            return try seKey(kind).publicKey.x963Representation.base64EncodedString()
        }
        return try softwareKey(kind).publicKey.x963Representation.base64EncodedString()
    }

    /// Signs `message` using ECDSA P-256/SHA-256 raw representation (64-byte r||s).
    public func sign(_ message: String, with kind: ISyMCPKeyKind, reason: String = "Aprobar acción en ISyMCP") throws -> String {
        let payload = Data(message.utf8)
        if SecureEnclave.isAvailable {
            #if canImport(LocalAuthentication)
            let ctx = LAContext()
            ctx.localizedReason = reason
            let k = try seKey(kind, context: ctx)
            return try k.signature(for: payload).rawRepresentation.base64EncodedString()
            #else
            let k = try seKey(kind)
            return try k.signature(for: payload).rawRepresentation.base64EncodedString()
            #endif
        }
        let k = try softwareKey(kind)
        return try k.signature(for: payload).rawRepresentation.base64EncodedString()
    }

    public func reset() {
        for account in ["read", "approve", "sw.read", "sw.approve"] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(q as CFDictionary)
        }
    }

    #if canImport(LocalAuthentication)
    private func seKey(_ kind: ISyMCPKeyKind, context: LAContext? = nil) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = try load(account: kind.rawValue) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context)
        }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if kind == .approve {
            flags.insert(.biometryCurrentSet)
        }
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw ISyMCPAPIError(code: "access_control", detail: "No se pudo crear el control de acceso del Secure Enclave.")
        }
        let k = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac, authenticationContext: context)
        try store(account: kind.rawValue, data: k.dataRepresentation)
        return k
    }
    #else
    private func seKey(_ kind: ISyMCPKeyKind) throws -> SecureEnclave.P256.Signing.PrivateKey {
        throw ISyMCPAPIError(code: "no_secure_enclave")
    }
    #endif

    private func softwareKey(_ kind: ISyMCPKeyKind) throws -> P256.Signing.PrivateKey {
        let account = "sw.\(kind.rawValue)"
        if let data = try load(account: account) {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let k = P256.Signing.PrivateKey()
        try store(account: account, data: k.rawRepresentation)
        return k
    }

    private func load(account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ISyMCPAPIError(code: "keychain_\(status)")
        }
        return out as? Data
    }

    private func store(account: String, data: Data) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ISyMCPAPIError(code: "keychain_\(status)")
        }
    }
}

/// Canonical `ISY1` signed HTTP client for ISyMCP's Tailscale Phone API (`:8797`).
public final class ISyMCPClient: @unchecked Sendable {
    public let baseURL: URL
    public let deviceID: String
    private let session: URLSession

    public init(baseURL: URL, deviceID: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public static func normalizePairingCode(_ code: String) -> String {
        code.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
    }

    public static func pairProofMessage(code: String, readKey: String, approveKey: String) -> String {
        "ISY1-PAIR\n\(normalizePairingCode(code))\n\(readKey)\n\(approveKey)"
    }

    public static func canonicalString(method: String, path: String, ts: String, nonce: String, body: Data, key: ISyMCPKeyKind) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "ISY1\n\(method.uppercased())\n\(path)\n\(ts)\n\(nonce)\n\(hash)\n\(key.rawValue)"
    }

    public static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        key: ISyMCPKeyKind = .read,
        reason: String = "Aprobar en ISyMCP"
    ) async throws -> [String: Any] {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = Self.generateNonce()
        let msg = Self.canonicalString(method: method, path: path, ts: ts, nonce: nonce, body: data, key: key)
        let sig = try await Task.detached {
            try ISyMCPDeviceKeys.shared.sign(msg, with: key, reason: reason)
        }.value
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ISyMCPAPIError(code: "bad_url", detail: path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if method != "GET" {
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        req.setValue(deviceID, forHTTPHeaderField: "x-isy-device")
        req.setValue(ts, forHTTPHeaderField: "x-isy-ts")
        req.setValue(nonce, forHTTPHeaderField: "x-isy-nonce")
        req.setValue(key.rawValue, forHTTPHeaderField: "x-isy-key")
        req.setValue(sig, forHTTPHeaderField: "x-isy-sig")
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 || (obj["ok"] as? Bool) == false {
            throw ISyMCPAPIError(
                code: obj["error"] as? String ?? "http_\(status)",
                detail: obj["detail"] as? String
            )
        }
        return obj
    }

    public static func hello(baseURL: URL) async throws -> [String: Any] {
        let client = ISyMCPClient(baseURL: baseURL, deviceID: "")
        return try await client.send(URLRequest(url: baseURL.appendingPathComponent("v1/hello")))
    }

    public static func pair(baseURL: URL, code: String, name: String) async throws -> String {
        let keys = ISyMCPDeviceKeys.shared
        keys.reset()
        let readKey = try keys.publicKeyBase64(.read)
        let approveKey = try keys.publicKeyBase64(.approve)
        let msg = pairProofMessage(code: code, readKey: readKey, approveKey: approveKey)
        let (readProof, approveProof) = try await Task.detached {
            (
                try keys.sign(msg, with: .read),
                try keys.sign(msg, with: .approve, reason: "Emparejar este iPhone con ISyMCP")
            )
        }.value
        let body: [String: Any] = [
            "code": code,
            "name": name,
            "read_key": readKey,
            "approve_key": approveKey,
            "read_proof": readProof,
            "approve_proof": approveProof
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/pair"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let client = ISyMCPClient(baseURL: baseURL, deviceID: "")
        let obj = try await client.send(req)
        guard let id = obj["device_id"] as? String, !id.isEmpty else {
            throw ISyMCPAPIError(code: "bad_response", detail: "El servidor no devolvió device_id.")
        }
        return id
    }
}

/// Observable store for ISyMCP Phone API pairing, status, permission gates, and tasks.
@MainActor
public final class ISyMCPStore: ObservableObject {
    public static let shared = ISyMCPStore()

    private nonisolated static let serverKey = "isymcp.phone.server"
    private nonisolated static let deviceIDKey = "isymcp.phone.deviceID"

    @Published public var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverKey) }
    }
    @Published public var deviceID: String {
        didSet { UserDefaults.standard.set(deviceID, forKey: Self.deviceIDKey) }
    }

    @Published public private(set) var isBusy = false
    @Published public private(set) var isRefreshing = false
    @Published public var errorMessage: String?
    @Published public var statusSummary: String?
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var pendingGatesCount: Int = 0
    @Published public private(set) var taintSummary: String?
    @Published public private(set) var recentTasks: [[String: Any]] = []
    @Published public private(set) var activeConsoles: [[String: Any]] = []
    @Published public private(set) var shellGateOpen: Bool = false
    @Published public private(set) var agentsGateOpen: Bool = false

    public init() {
        self.serverURLString = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
        self.deviceID = UserDefaults.standard.string(forKey: Self.deviceIDKey) ?? ""
    }

    public var isPaired: Bool {
        !deviceID.isEmpty && URL(string: serverURLString) != nil
    }

    public nonisolated static var currentClient: ISyMCPClient? {
        let server = UserDefaults.standard.string(forKey: serverKey) ?? ""
        let devID = UserDefaults.standard.string(forKey: deviceIDKey) ?? ""
        guard !devID.isEmpty, let url = URL(string: server) else { return nil }
        return ISyMCPClient(baseURL: url, deviceID: devID)
    }

    public func pair(rawServer: String, code: String) async {
        var normalized = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "http://\(normalized)"
        }
        if let parsed = URL(string: normalized), parsed.port == nil {
            normalized += ":8797"
        }
        guard let url = URL(string: normalized) else {
            errorMessage = "Dirección de servidor inválida (usa la IP de Tailscale de tu PC)."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await ISyMCPClient.hello(baseURL: url)
            #if canImport(UIKit)
            let deviceName = UIDevice.current.name
            #else
            let deviceName = "iSyCode iPhone"
            #endif
            let pairedID = try await ISyMCPClient.pair(baseURL: url, code: code, name: deviceName)
            serverURLString = normalized
            deviceID = pairedID
            errorMessage = nil
            statusSummary = "Emparejado con ISyMCP en \(url.host ?? normalized)"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func unpair() {
        ISyMCPDeviceKeys.shared.reset()
        deviceID = ""
        statusSummary = nil
        errorMessage = nil
        pendingGatesCount = 0
        taintSummary = nil
        recentTasks = []
        activeConsoles = []
        shellGateOpen = false
        agentsGateOpen = false
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        guard let client = Self.currentClient else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let st = client.request("GET", "/v1/status")
            async let ta = client.request("GET", "/v1/tasks?limit=15")
            async let co = client.request("GET", "/v1/consoles")
            let (statusObj, tasksObj, consolesObj) = try await (st, ta, co)

            let gates = statusObj["gates"] as? [String: Any] ?? [:]
            let pending = gates["pending"] as? [[String: Any]] ?? []
            pendingGatesCount = pending.count

            if let taint = gates["taint"] as? [String: Any] {
                taintSummary = taint["summary"] as? String
            } else {
                taintSummary = nil
            }

            if let caps = gates["caps"] as? [[String: Any]] {
                for cap in caps {
                    let name = cap["cap"] as? String ?? ""
                    let source = cap["source"] as? String
                    let once = (cap["once_pending"] as? NSNumber)?.intValue ?? 0
                    let active = (source != nil && !(source?.isEmpty ?? true)) || once > 0
                    if name == "host_shell" { shellGateOpen = active }
                    if name == "agent_spawn" { agentsGateOpen = active }
                }
            }

            recentTasks = tasksObj["tasks"] as? [[String: Any]] ?? []
            activeConsoles = consolesObj["consoles"] as? [[String: Any]] ?? []
            lastRefresh = Date()
            statusSummary = "Conectado · \(activeConsoles.count) consola(s) · \(recentTasks.count) tarea(s)"
            errorMessage = nil
        } catch {
            // Preserve previous state on transient network failure (Section 4.5)
            errorMessage = error.localizedDescription
        }
    }

    public func grantOnce(capability: String, uses: Int = 1) async {
        guard let client = Self.currentClient else {
            errorMessage = ISyMCPAPIError(code: "not_paired").localizedDescription
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let label = capability == "shell" ? "shell en tu PC" : "consolas de agentes"
            _ = try await client.request(
                "POST",
                "/v1/grant",
                body: ["cap": capability, "uses": uses, "minutes": 10],
                key: .approve,
                reason: "Autorizar \(uses) uso(s) de \(label) en ISyMCP"
            )
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearTaint() async {
        guard let client = Self.currentClient else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await client.request(
                "POST",
                "/v1/taint/clear",
                body: [:],
                key: .approve,
                reason: "Limpiar marca de contenido externo (taint) en ISyMCP"
            )
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

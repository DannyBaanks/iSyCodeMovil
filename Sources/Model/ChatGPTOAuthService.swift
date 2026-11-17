import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

public struct ChatGPTOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, accountID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }
}

public enum ChatGPTOAuthError: LocalizedError {
    case notSignedIn
    case serverError(String)
    case invalidResponse
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "No hay sesión OAuth de ChatGPT iniciada."
        case .serverError(let msg): return msg
        case .invalidResponse: return "Respuesta inválida del servidor OAuth de OpenAI."
        case .timedOut: return "El código expiró antes de confirmarse. Inténtalo de nuevo."
        }
    }
}

/// Manages ChatGPT Plus/Pro OAuth (Device Code flow) and Keychain token storage.
@MainActor
public final class ChatGPTOAuthStore: ObservableObject {
    public static let shared = ChatGPTOAuthStore()

    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let userCodeEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let oauthTokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let deviceCallbackURI = "https://auth.openai.com/deviceauth/callback"
    private static let keychainAccount = "isycode.chatgpt.oauth.tokens"

    @Published public private(set) var isSignedIn = false
    @Published public private(set) var accountID: String?
    @Published public private(set) var userCode: String?
    @Published public private(set) var isPolling = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var cachedModels: [String] = []

    private static let cachedModelsKey = "isycode.chatgpt.oauth.cachedModels"

    private var pollingTask: Task<Void, Never>?

    private init() {
        if let tokens = Self.loadTokens() {
            isSignedIn = true
            accountID = tokens.accountID
        }
        cachedModels = UserDefaults.standard.stringArray(forKey: Self.cachedModelsKey) ?? []
    }

    public static func updateCachedModels(_ models: [String]) {
        shared.cachedModels = models
        UserDefaults.standard.set(models, forKey: cachedModelsKey)
    }

    public nonisolated static func storedModelIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: cachedModelsKey) ?? []
    }

    public nonisolated static func hasStoredTokens() -> Bool {
        loadTokens() != nil
    }

    public func startDeviceLogin() {
        pollingTask?.cancel()
        errorMessage = nil
        statusMessage = "Solicitando código de acceso a OpenAI…"
        isPolling = true
        userCode = nil

        pollingTask = Task {
            #if canImport(UIKit)
            let bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "ChatGPTOAuthPoll")
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
            #endif
            do {
                let codeResp = try await Self.requestUserCode()
                guard !Task.isCancelled else { return }
                self.userCode = codeResp.userCode
                #if canImport(UIKit)
                UIPasteboard.general.string = codeResp.userCode
                #endif
                await Self.notifyDeviceCode(codeResp.userCode)
                self.statusMessage = "Código \(codeResp.userCode) copiado. Pégalo en Safari (auth.openai.com/codex/device)."

                let tokens = try await Self.pollForTokens(
                    deviceAuthID: codeResp.deviceAuthID,
                    userCode: codeResp.userCode,
                    intervalSeconds: codeResp.intervalSeconds
                )
                guard !Task.isCancelled else { return }
                try Self.saveTokens(tokens)
                self.isSignedIn = true
                self.accountID = tokens.accountID
                self.userCode = nil
                self.isPolling = false
                self.statusMessage = "ChatGPT Plus/Pro conectado por OAuth."
            } catch is CancellationError {
                self.isPolling = false
            } catch {
                self.isPolling = false
                self.errorMessage = error.localizedDescription
                self.statusMessage = nil
            }
        }
    }

    public func cancelLogin() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
        userCode = nil
        statusMessage = nil
    }

    public func signOut() {
        cancelLogin()
        Self.deleteTokens()
        isSignedIn = false
        accountID = nil
        statusMessage = "Sesión OAuth de ChatGPT cerrada."
        errorMessage = nil
    }

    /// Returns a fresh access token and account ID, refreshing via `refresh_token` if close to expiry.
    public nonisolated static func validCredentials() async throws -> (accessToken: String, accountID: String) {
        guard let tokens = loadTokens() else {
            throw ChatGPTOAuthError.notSignedIn
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return (tokens.accessToken, tokens.accountID)
        }
        let refreshed = try await refresh(tokens: tokens)
        try saveTokens(refreshed)
        return (refreshed.accessToken, refreshed.accountID)
    }

    private static func notifyDeviceCode(_ code: String) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "Código ChatGPT OAuth: \(code)"
        content.body = "Ya se copió al portapapeles. Pégalo en Safari para autorizar tu cuenta."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "chatgpt-oauth-code-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        )
        try? await center.add(req)
        #endif
    }

    // MARK: - Network

    private struct UserCodeResponse {
        let deviceAuthID: String
        let userCode: String
        let intervalSeconds: Int
    }

    private nonisolated static func requestUserCode() async throws -> UserCodeResponse {
        var req = URLRequest(url: userCodeEndpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthID = json["device_auth_id"] as? String,
              let userCode = json["user_code"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? "Error \( (resp as? HTTPURLResponse)?.statusCode ?? 0 )"
            throw ChatGPTOAuthError.serverError(msg)
        }
        let interval: Int
        if let intVal = json["interval"] as? Int {
            interval = max(2, intVal)
        } else if let strVal = json["interval"] as? String, let parsed = Int(strVal) {
            interval = max(2, parsed)
        } else {
            interval = 5
        }
        return UserCodeResponse(deviceAuthID: deviceAuthID, userCode: userCode, intervalSeconds: interval)
    }

    private nonisolated static func pollForTokens(deviceAuthID: String, userCode: String, intervalSeconds: Int) async throws -> ChatGPTOAuthTokens {
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()

            var req = URLRequest(url: deviceTokenEndpoint, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthID,
                "user_code": userCode
            ])

            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await URLSession.shared.data(for: req)
            } catch let urlErr as URLError where !Task.isCancelled && (
                urlErr.code == .cancelled ||
                urlErr.code == .networkConnectionLost ||
                urlErr.code == .notConnectedToInternet ||
                urlErr.code == .timedOut
            ) {
                // iOS cancels in-flight URLSession sockets when backgrounded in Safari; keep polling on resume.
                try await Task.sleep(for: .seconds(1))
                continue
            } catch let nsErr as NSError where !Task.isCancelled && nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                try await Task.sleep(for: .seconds(1))
                continue
            }

            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let authCode = json["authorization_code"] as? String,
               let codeVerifier = json["code_verifier"] as? String {
                return try await exchangeCode(authCode: authCode, codeVerifier: codeVerifier)
            }
            if status == 403 || status == 404 || status == 429 {
                try await Task.sleep(for: .seconds(intervalSeconds))
                continue
            }
            if status >= 400 {
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("authorization_pending") || body.contains("slow_down") {
                    try await Task.sleep(for: .seconds(intervalSeconds))
                    continue
                }
                throw ChatGPTOAuthError.serverError("OpenAI OAuth (\(status)): \(body)")
            }
            try await Task.sleep(for: .seconds(intervalSeconds))
        }
        throw ChatGPTOAuthError.timedOut
    }

    private nonisolated static func exchangeCode(authCode: String, codeVerifier: String) async throws -> ChatGPTOAuthTokens {
        var req = URLRequest(url: oauthTokenEndpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let pairs = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": authCode,
            "code_verifier": codeVerifier,
            "redirect_uri": deviceCallbackURI
        ]
        req.httpBody = formEncoded(pairs)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? "Error al canjear código OAuth."
            throw ChatGPTOAuthError.serverError(msg)
        }
        let refresh = (json["refresh_token"] as? String) ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let idToken = json["id_token"] as? String
        let accountID = extractAccountID(fromJWT: access) ?? idToken.flatMap(extractAccountID(fromJWT:)) ?? ""
        return ChatGPTOAuthTokens(
            accessToken: access,
            refreshToken: refresh,
            accountID: accountID,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private nonisolated static func refresh(tokens: ChatGPTOAuthTokens) async throws -> ChatGPTOAuthTokens {
        guard !tokens.refreshToken.isEmpty else {
            throw ChatGPTOAuthError.notSignedIn
        }
        var req = URLRequest(url: oauthTokenEndpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": tokens.refreshToken
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw ChatGPTOAuthError.notSignedIn
        }
        let newRefresh = (json["refresh_token"] as? String) ?? tokens.refreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let accountID = extractAccountID(fromJWT: access) ?? tokens.accountID
        return ChatGPTOAuthTokens(
            accessToken: access,
            refreshToken: newRefresh,
            accountID: accountID,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private nonisolated static func formEncoded(_ params: [String: String]) -> Data? {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.percentEncodedQuery?.data(using: .utf8)
    }

    private nonisolated static func extractAccountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any],
              let acct = auth["chatgpt_account_id"] as? String, !acct.isEmpty else {
            return nil
        }
        return acct
    }

    // MARK: - Keychain

    private nonisolated static func saveTokens(_ tokens: ChatGPTOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        deleteTokens()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ChatGPTOAuthError.serverError("Keychain error (\(status))")
        }
    }

    private nonisolated static func loadTokens() -> ChatGPTOAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ChatGPTOAuthTokens.self, from: data)
    }

    private nonisolated static func deleteTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

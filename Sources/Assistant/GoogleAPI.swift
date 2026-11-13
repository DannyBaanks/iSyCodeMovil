import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Inicio de sesión con Google sin SDK: OAuth 2.0 para apps instaladas con PKCE
// y llamadas REST con el token del propio usuario. Misma lógica que
// android/.../assistant/GoogleModels.kt y GoogleClient.kt.

public struct GoogleToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: Set<String>
    public var email: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date = .distantPast,
                scopes: Set<String> = [], email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.email = email
    }

    public func isFresh(at now: Date) -> Bool { !accessToken.isEmpty && now < expiresAt.addingTimeInterval(-60) }
}

public struct GoogleAPIError: Error, LocalizedError, Equatable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
}

public enum GoogleOAuth {
    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let clientSuffix = ".apps.googleusercontent.com"
    private static let baseScopes = ["openid", "email"]

    public static func isPlausibleClientId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(clientSuffix) && trimmed.count > clientSuffix.count && !trimmed.contains(" ")
    }

    /// iOS clients redirect to the reversed client ID; that scheme must be in Info.plist.
    public static func redirectScheme(clientId: String) -> String? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleClientId(trimmed) else { return nil }
        return "com.googleusercontent.apps." + String(trimmed.dropLast(clientSuffix.count))
    }

    public static func redirectURI(clientId: String) -> String? {
        redirectScheme(clientId: clientId).map { $0 + ":/oauth2redirect" }
    }

    public static func scopes(_ services: [GoogleService]) -> [String] {
        var result: [String] = []
        for scope in baseScopes + services.flatMap(\.scopes) where !result.contains(scope) { result.append(scope) }
        return result
    }

    public static func newVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return AssistantCatalog.base64URL(Data(bytes))
    }

    public static func challenge(_ verifier: String) -> String {
        #if canImport(CryptoKit)
        return AssistantCatalog.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #else
        return verifier
        #endif
    }

    public static func authURL(clientId: String, redirectURI: String, scopes: [String], challenge: String, state: String) -> URL? {
        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            .init(name: "client_id", value: clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    /// The e-mail inside an ID token. Display only: the token came straight from Google over TLS.
    public static func email(fromIdToken idToken: String?) -> String? {
        guard let parts = idToken?.split(separator: "."), parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }

    /// Parses a token response; a refresh keeps the previous refresh token, scopes and e-mail.
    public static func parseToken(_ data: Data, now: Date, previous: GoogleToken? = nil) throws -> GoogleToken {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError(status: 400, message: "Google respondió algo que no entiendo.")
        }
        if let error = object["error"] as? String {
            throw GoogleAPIError(status: 400, message: (object["error_description"] as? String) ?? error)
        }
        guard let access = object["access_token"] as? String else {
            throw GoogleAPIError(status: 400, message: "Google no devolvió un token de acceso.")
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (object["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) }
        return GoogleToken(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            scopes: scopes ?? previous?.scopes ?? [],
            email: email(fromIdToken: object["id_token"] as? String) ?? previous?.email
        )
    }

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    public static func exchange(code: String, verifier: String, clientId: String, redirectURI: String,
                                session: URLSession = .shared) async throws -> GoogleToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([("client_id", clientId.trimmingCharacters(in: .whitespacesAndNewlines)), ("code", code),
                                 ("code_verifier", verifier), ("grant_type", "authorization_code"), ("redirect_uri", redirectURI)])
        let (data, _) = try await session.data(for: request)
        return try parseToken(data, now: Date())
    }

    public static func refresh(_ token: GoogleToken, clientId: String, session: URLSession = .shared) async throws -> GoogleToken {
        guard let refresh = token.refreshToken else {
            throw GoogleAPIError(status: 401, message: "Vuelve a conectar tu cuenta de Google.")
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([("client_id", clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
                                 ("refresh_token", refresh), ("grant_type", "refresh_token")])
        let (data, _) = try await session.data(for: request)
        return try parseToken(data, now: Date(), previous: token)
    }

    public static func revoke(_ token: GoogleToken, session: URLSession = .shared) async {
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([("token", token.refreshToken ?? token.accessToken)])
        _ = try? await session.data(for: request)
    }
}

// MARK: - Session (token in the Keychain, shared by the UI and the agent tools)

/// Keeps the Google token in the Keychain and refreshes it when it expires.
public actor GoogleSession {
    public static let shared = GoogleSession()
    static let keychainKey = "google.oauth.token"
    public static let clientIdKey = "assistant.google.clientId"

    private var cached: GoogleToken?
    private var loaded = false

    public func token() async -> GoogleToken? {
        if !loaded {
            loaded = true
            if let json = try? await KeychainHelper.shared.load(key: Self.keychainKey), let data = json.data(using: .utf8) {
                cached = try? JSONDecoder().decode(GoogleToken.self, from: data)
            }
        }
        return cached
    }

    public func store(_ token: GoogleToken?) async {
        cached = token
        loaded = true
        if let token, let data = try? JSONEncoder().encode(token), let json = String(data: data, encoding: .utf8) {
            try? await KeychainHelper.shared.save(key: Self.keychainKey, value: json)
        } else {
            try? await KeychainHelper.shared.delete(key: Self.keychainKey)
        }
    }

    public func grantedScopes() async -> Set<String> { await token()?.scopes ?? [] }

    /// A usable access token, refreshing it if needed.
    public func accessToken() async throws -> String {
        guard let current = await token() else {
            throw GoogleAPIError(status: 401, message: "Conecta tu cuenta de Google primero.")
        }
        if current.isFresh(at: Date()) { return current.accessToken }
        let clientId = UserDefaults.standard.string(forKey: Self.clientIdKey) ?? ""
        let refreshed = try await GoogleOAuth.refresh(current, clientId: clientId)
        await store(refreshed)
        return refreshed.accessToken
    }
}

// MARK: - Models and parsers

public struct MailSummary: Identifiable, Sendable { public let id, from, subject, date, snippet: String }
public struct EventSummary: Identifiable, Sendable { public let id, title, start, end, location, link: String }
public struct TaskItem: Identifiable, Sendable { public let id, title, notes, due: String }
public struct DriveFile: Identifiable, Sendable { public let id, name, mimeType, modified, link: String }
public struct ContactItem: Identifiable, Sendable {
    public let name, email, organization: String
    public var id: String { name + email }
}
public struct CourseItem: Identifiable, Sendable { public let id, name, section: String }
public struct SheetData: Sendable {
    public let tab: String
    public let rows: [[String]]
}

/// Turns Google's JSON into the few fields the app shows. Missing fields become empty strings.
public enum GoogleParsers {
    typealias JSON = [String: Any]

    static func root(_ data: Data) -> JSON { (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:] }
    static func string(_ object: JSON?, _ key: String) -> String { (object?[key] as? String) ?? "" }
    static func objects(_ object: JSON?, _ key: String) -> [JSON] { (object?[key] as? [Any])?.compactMap { $0 as? JSON } ?? [] }

    public static func messageIds(_ data: Data) -> [String] { objects(root(data), "messages").map { string($0, "id") }.filter { !$0.isEmpty } }

    public static func message(_ data: Data) -> MailSummary {
        let object = root(data)
        let headers = objects(object["payload"] as? JSON, "headers")
        func header(_ name: String) -> String {
            headers.first { string($0, "name").caseInsensitiveCompare(name) == .orderedSame }.map { string($0, "value") } ?? ""
        }
        let subject = header("Subject")
        return MailSummary(id: string(object, "id"), from: header("From"), subject: subject.isEmpty ? "(sin asunto)" : subject,
                           date: header("Date"), snippet: string(object, "snippet"))
    }

    public static func events(_ data: Data) -> [EventSummary] { events(objects(root(data), "items")) }

    static func events(_ items: [JSON]) -> [EventSummary] {
        items.map { item in
            func time(_ key: String) -> String {
                let value = item[key] as? JSON
                let dateTime = string(value, "dateTime")
                return dateTime.isEmpty ? string(value, "date") : dateTime
            }
            let title = string(item, "summary")
            return EventSummary(id: string(item, "id"), title: title.isEmpty ? "(sin título)" : title, start: time("start"),
                                end: time("end"), location: string(item, "location"), link: string(item, "htmlLink"))
        }
    }

    public static func tasks(_ data: Data) -> [TaskItem] {
        objects(root(data), "items")
            .map { TaskItem(id: string($0, "id"), title: string($0, "title"), notes: string($0, "notes"), due: string($0, "due")) }
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static func files(_ data: Data) -> [DriveFile] {
        objects(root(data), "files").map {
            DriveFile(id: string($0, "id"), name: string($0, "name"), mimeType: string($0, "mimeType"),
                      modified: string($0, "modifiedTime"), link: string($0, "webViewLink"))
        }
    }

    public static func contacts(_ data: Data) -> [ContactItem] {
        objects(root(data), "connections").map { person in
            ContactItem(name: string(objects(person, "names").first, "displayName"),
                        email: string(objects(person, "emailAddresses").first, "value"),
                        organization: string(objects(person, "organizations").first, "name"))
        }.filter { !$0.name.isEmpty || !$0.email.isEmpty }
    }

    public static func courses(_ data: Data) -> [CourseItem] {
        objects(root(data), "courses").map { CourseItem(id: string($0, "id"), name: string($0, "name"), section: string($0, "section")) }
    }

    public static func firstSheetTitle(_ data: Data) -> String {
        string(objects(root(data), "sheets").first?["properties"] as? JSON, "title")
    }

    public static func sheetRows(_ data: Data) -> [[String]] {
        ((root(data)["values"] as? [Any]) ?? []).map { row in
            ((row as? [Any]) ?? []).map { value in (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
        }
    }

    public static func documentId(_ data: Data) -> String { string(root(data), "documentId") }

    /// Google's own explanation of a failed call, when the body carries one.
    public static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        if let error = object["error"] as? JSON, let message = error["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String { return (object["error_description"] as? String) ?? error }
        return nil
    }

    /// A spreadsheet ID from either the bare ID or a full docs.google.com link.
    public static func spreadsheetId(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"/spreadsheets/d/[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return String(trimmed[range].dropFirst("/spreadsheets/d/".count))
        }
        return trimmed
    }
}

// MARK: - REST client

/// Calls Google's REST APIs with the user's own token. Every write method is
/// only reached after a confirmation (dialog in the app, approval in the agent).
public struct GoogleClient: Sendable {
    let tokenProvider: @Sendable () async throws -> String
    let session: URLSession
    let baseOverride: String?

    public init(session: URLSession = .shared, baseOverride: String? = nil,
                tokenProvider: @escaping @Sendable () async throws -> String = { try await GoogleSession.shared.accessToken() }) {
        self.session = session
        self.baseOverride = baseOverride
        self.tokenProvider = tokenProvider
    }

    func url(_ host: String, _ path: String, _ query: [(String, String)] = []) throws -> URL {
        let base = (baseOverride ?? "https://\(host)").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + path) else {
            throw GoogleAPIError(status: 0, message: "Dirección inválida.")
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // URLComponents leaves "+" alone, but Google reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw GoogleAPIError(status: 0, message: "Dirección inválida.") }
        return url
    }

    @discardableResult
    func call(_ url: URL, method: String = "GET", json: Any? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = GoogleParsers.errorMessage(data) ?? "HTTP \(status)"
            switch status {
            case 401: throw GoogleAPIError(status: 401, message: "Tu sesión de Google expiró. Vuelve a conectar tu cuenta.")
            case 403: throw GoogleAPIError(status: 403, message: "Google rechazó el permiso: \(reason). Revisa que la API esté habilitada y que diste acceso.")
            default: throw GoogleAPIError(status: status, message: reason)
            }
        }
        return data
    }

    // Gmail
    public func recentMail(max: Int = 6, query: String = "in:inbox") async throws -> [MailSummary] {
        let list = try await call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages", [("maxResults", "\(max)"), ("q", query)]))
        var result: [MailSummary] = []
        for id in GoogleParsers.messageIds(list) {
            let data = try await call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages/\(id)", [
                ("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Subject"), ("metadataHeaders", "Date")]))
            result.append(GoogleParsers.message(data))
        }
        return result
    }

    public func sendMail(to: String, subject: String, body: String) async throws {
        try await call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages/send"), method: "POST",
                       json: ["raw": AssistantCatalog.encodeGmailRaw(to: to, subject: subject, body: body)])
    }

    // Calendar
    public func upcomingEvents(from now: Date = Date(), max: Int = 8) async throws -> [EventSummary] {
        let iso = ISO8601DateFormatter().string(from: now)
        return GoogleParsers.events(try await call(url("www.googleapis.com", "/calendar/v3/calendars/primary/events", [
            ("timeMin", iso), ("maxResults", "\(max)"), ("singleEvents", "true"), ("orderBy", "startTime")])))
    }

    public func createEvent(title: String, start: Date, end: Date, location: String,
                            timeZone: TimeZone = .current) async throws -> EventSummary {
        let format = ISO8601DateFormatter()
        format.timeZone = timeZone
        var payload: [String: Any] = [
            "summary": title,
            "start": ["dateTime": format.string(from: start), "timeZone": timeZone.identifier],
            "end": ["dateTime": format.string(from: end), "timeZone": timeZone.identifier],
        ]
        if !location.isEmpty { payload["location"] = location }
        let data = try await call(url("www.googleapis.com", "/calendar/v3/calendars/primary/events"), method: "POST", json: payload)
        return GoogleParsers.events([GoogleParsers.root(data)]).first!
    }

    // Tasks
    public func openTasks(max: Int = 20) async throws -> [TaskItem] {
        GoogleParsers.tasks(try await call(url("tasks.googleapis.com", "/tasks/v1/lists/@default/tasks",
                                               [("maxResults", "\(max)"), ("showCompleted", "false")])))
    }

    public func createTask(title: String, notes: String) async throws {
        var payload: [String: Any] = ["title": title]
        if !notes.isEmpty { payload["notes"] = notes }
        try await call(url("tasks.googleapis.com", "/tasks/v1/lists/@default/tasks"), method: "POST", json: payload)
    }

    // Drive / Docs
    public func recentFiles(max: Int = 8) async throws -> [DriveFile] {
        GoogleParsers.files(try await call(url("www.googleapis.com", "/drive/v3/files", [
            ("pageSize", "\(max)"), ("orderBy", "modifiedTime desc"), ("q", "trashed = false"),
            ("fields", "files(id,name,mimeType,modifiedTime,webViewLink)")])))
    }

    public func createDoc(title: String, text: String) async throws -> String {
        let id = GoogleParsers.documentId(try await call(url("docs.googleapis.com", "/v1/documents"), method: "POST", json: ["title": title]))
        if !text.isEmpty {
            try await call(url("docs.googleapis.com", "/v1/documents/\(id):batchUpdate"), method: "POST",
                           json: ["requests": [["insertText": ["location": ["index": 1], "text": text]]]])
        }
        return id
    }

    // Contacts / Classroom / Sheets
    public func contacts(max: Int = 20) async throws -> [ContactItem] {
        GoogleParsers.contacts(try await call(url("people.googleapis.com", "/v1/people/me/connections", [
            ("pageSize", "\(max)"), ("personFields", "names,emailAddresses,organizations"), ("sortOrder", "LAST_MODIFIED_DESCENDING")])))
    }

    public func courses() async throws -> [CourseItem] {
        GoogleParsers.courses(try await call(url("classroom.googleapis.com", "/v1/courses", [("courseStates", "ACTIVE"), ("pageSize", "10")])))
    }

    public func postAnnouncement(courseId: String, text: String) async throws {
        try await call(url("classroom.googleapis.com", "/v1/courses/\(courseId)/announcements"), method: "POST",
                       json: ["text": text, "state": "PUBLISHED"])
    }

    static func a1(_ tab: String, _ range: String) -> String {
        let quoted = "'" + tab.replacingOccurrences(of: "'", with: "''") + "'!" + range
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return quoted.addingPercentEncoding(withAllowedCharacters: allowed) ?? quoted
    }

    private func firstTab(_ id: String) async throws -> String {
        let title = GoogleParsers.firstSheetTitle(try await call(url("sheets.googleapis.com", "/v4/spreadsheets/\(id)",
                                                                     [("fields", "sheets.properties.title")])))
        return title.isEmpty ? "Sheet1" : title
    }

    /// Reads the first rows of the first tab. The tab name comes from the file, not a guess.
    public func readSheet(_ spreadsheet: String, range: String = "A1:E15") async throws -> SheetData {
        let id = GoogleParsers.spreadsheetId(spreadsheet)
        let tab = try await firstTab(id)
        let rows = GoogleParsers.sheetRows(try await call(url("sheets.googleapis.com", "/v4/spreadsheets/\(id)/values/\(Self.a1(tab, range))")))
        return SheetData(tab: tab, rows: rows)
    }

    /// RAW, no USER_ENTERED: un valor que empiece con "=" (por ejemplo del contenido de un correo) no debe
    /// convertirse en fórmula; `=IMPORTDATA(...)` podría sacar datos de la hoja hacia un servidor ajeno.
    public func appendRow(_ spreadsheet: String, values: [String]) async throws {
        let id = GoogleParsers.spreadsheetId(spreadsheet)
        let tab = try await firstTab(id)
        try await call(url("sheets.googleapis.com", "/v4/spreadsheets/\(id)/values/\(Self.a1(tab, "A1")):append",
                           [("valueInputOption", "RAW")]), method: "POST", json: ["values": [values]])
    }
}

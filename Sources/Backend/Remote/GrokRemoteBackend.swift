import Foundation

/// Experimental Grok ACP adapter. The phone talks to the Bridge proxy on
/// Tailscale. Grok itself stays on 127.0.0.1. Only the operations checked
/// against Grok 1.0.50 are enabled. A full model turn was not part of that check.
@MainActor
public final class GrokRemoteBackend: WorkbenchBackend, RemoteBackend {
    public var mode: BackendMode { .remote }
    public let remoteType: RemoteBackendType = .grok
    public var baseURL: URL { URL(string: "ws://\(pairing?.host ?? "127.0.0.1"):\(pairing?.port ?? 1)")! }
    public var authHeaders: [String: String] { [:] }
    public let eventStream: AsyncStream<WorkbenchEvent>
    private var continuation: AsyncStream<WorkbenchEvent>.Continuation?
    private var pairing: GrokPairing?
    private var client: GrokACPClient?
    private var eventTask: Task<Void, Never>?
    private var sessions: [Session] = []
    private var selectedSessionID: String?
    private var loadedSessionIDs: Set<String> = []
    private var pendingApprovals: [String: (CodexAppServerRequestID, [String: String])] = [:]

    public init() {
        var c: AsyncStream<WorkbenchEvent>.Continuation?
        eventStream = AsyncStream { c = $0 }
        continuation = c
    }

    public var connectionStatus: String { get async { "Grok ACP · Experimental · Tailscale/VPN" } }
    public var currentSessionID: String? { get async { selectedSessionID } }

    public func connectRemote(pairing: BackendPairing) async throws {
        guard case .grok(let value) = pairing else { throw Self.unsupported }
        eventTask?.cancel()
        eventTask = nil
        await client?.disconnect(reason: "reconnecting")
        let client = try GrokACPClient(pairing: value)
        try await client.connect()
        self.pairing = value
        self.client = client
        try await startEventStream()
        continuation?.yield(.connected)
    }

    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await client?.disconnect()
        client = nil
        pairing = nil
        selectedSessionID = nil
        loadedSessionIDs.removeAll()
        continuation?.yield(.disconnected("Grok desconectado"))
    }

    public func useNativeRuntime() async throws { throw Self.unsupported }
    public func listProjects() async throws -> [Project] {
        guard let pairing else { throw Self.unsupported }
        return [Project(id: projectID, name: "Grok @ \(pairing.host)", path: pairing.directory, avatarColor: .white)]
    }

    public func listSessions(projectID: String) async throws -> [Session] {
        guard let client, let pairing else { throw Self.unsupported }
        guard pairing.profile.sessionList else {
            return sessions
        }
        let result = try await client.request(method: "session/list")
        guard let rows = result.grokObject?["sessions"]?.grokArray else { throw GrokACPError.invalidMessage }
        let directory = pairing.directory
        sessions = rows.compactMap { row in
            guard let object = row.grokObject,
                  let id = object["sessionId"]?.grokString,
                  Self.sameDirectory(object["cwd"]?.grokString ?? "", directory) else { return nil }
            let title = Self.displayTitle(object["title"]?.grokString)
            return Session(id: id, projectId: projectID, title: title, timestamp: Self.date(object["updatedAt"]?.grokString))
        }
        return sessions
    }

    public func createSession(projectID: String, title: String) async throws -> Session {
        guard let client, let pairing, pairing.profile.sessionNew else { throw Self.unsupported }
        let result = try await client.request(method: "session/new", params: .object([
            "cwd": .string(pairing.directory),
            "mcpServers": .array([])
        ]), timeout: 30)
        guard let id = result.grokObject?["sessionId"]?.grokString else { throw GrokACPError.invalidMessage }
        let session = Session(id: id, projectId: projectID, title: title.isEmpty ? "Nueva conversación" : title)
        sessions.insert(session, at: 0)
        selectedSessionID = id
        loadedSessionIDs.insert(id)
        return session
    }

    public func renameSession(sessionID: String, title: String) async throws { throw Self.unsupported }
    public func deleteSession(sessionID: String) async throws { throw Self.unsupported }

    public func selectSession(_ sessionID: String) async throws {
        guard sessions.contains(where: { $0.id == sessionID }) else { throw Self.unsupported }
        if !loadedSessionIDs.contains(sessionID) {
            guard let client, let pairing else { throw Self.unsupported }
            _ = try await client.request(method: "session/load", params: .object([
                "sessionId": .string(sessionID),
                "cwd": .string(pairing.directory),
                "mcpServers": .array([])
            ]), timeout: 30)
            loadedSessionIDs.insert(sessionID)
        }
        selectedSessionID = sessionID
    }

    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        guard let client, let pairing, pairing.profile.sessionPrompt, pairing.profile.textStreaming,
              let selectedSessionID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.unsupported }
        let result = try await client.request(method: "session/prompt", params: .object([
            "sessionId": .string(selectedSessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]), timeout: nil)
        if result.grokObject?["stopReason"]?.grokString == "refusal" {
            continuation?.yield(.sessionError("Grok detuvo el turno."))
        }
        continuation?.yield(.sessionIdle(sessionID: selectedSessionID))
    }

    public func abort() async throws {
        guard let client, let pairing, pairing.profile.sessionCancel, let selectedSessionID else { return }
        try await client.notify(method: "session/cancel", params: .object(["sessionId": .string(selectedSessionID)]))
    }

    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        guard let client, let pending = pendingApprovals[requestID] else { throw Self.unsupported }
        let (rpcID, options) = pending
        if decision == .cancel {
            try await client.respond(id: rpcID, result: .object([
                "outcome": .object(["outcome": .string("cancelled")])
            ]))
            pendingApprovals.removeValue(forKey: requestID)
            return
        }
        let kind: String
        switch decision {
        case .allowOnce: kind = "allow_once"
        case .allowAlways: kind = "allow_always"
        case .decline, .deny: kind = "reject_once"
        case .cancel: kind = ""
        }
        guard let optionID = options[kind] else { throw Self.unsupported }
        try await client.respond(id: rpcID, result: .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionID)
            ])
        ]))
        pendingApprovals.removeValue(forKey: requestID)
    }

    public func loadHistory(sessionID: String) async throws -> [TimelineEvent] { [] }
    public func startEventStream() async throws {
        guard eventTask == nil, let client else { return }
        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(event)
            }
        }
    }
    public func stopEventStream() async { eventTask?.cancel(); eventTask = nil }

    private func consume(_ event: GrokACPEvent) {
        switch event {
        case .notification(let method, let params):
            guard method == "session/update" else { return }
            guard let update = params.grokObject?["update"]?.grokObject else { return }
            let kind = update["sessionUpdate"]?.grokString ?? ""
            if kind == "agent_message_chunk" {
                let text = update["content"]?.grokObject?["text"]?.grokString ?? update["content"]?.grokString ?? ""
                guard !text.isEmpty else { return }
                let partID = update["messageId"]?.grokString ?? selectedSessionID ?? "grok-text"
                continuation?.yield(.partDelta(partID: partID, delta: text))
            } else if kind == "tool_call" || kind == "tool_call_update" {
                let id = update["toolCallId"]?.grokString ?? UUID().uuidString
                let title = update["title"]?.grokString ?? update["kind"]?.grokString ?? "herramienta"
                let raw = update["status"]?.grokString ?? "pending"
                let status = (raw == "completed") ? "completed" : (raw == "failed" ? "error" : "running")
                continuation?.yield(.partUpdated(partID: id, kind: "tool", text: nil, tool: title, callID: id, status: status, input: [:], output: nil, error: nil))
            }
        case .request(let id, let method, let params):
            guard method == "session/request_permission", pairing?.profile.permission == true else {
                Task { try? await client?.respondError(id: id, code: -32601, message: "ISyCodeMovil does not implement \(method).") }
                continuation?.yield(.sessionError("Grok pidió \(method), y esta app no lo hace. La petición se rechazó."))
                return
            }
            let object = params.grokObject ?? [:]
            let tool = object["toolCall"]?.grokObject
            let title = tool?["title"]?.grokString ?? tool?["kind"]?.grokString ?? "herramienta"
            var options: [String: String] = [:]
            for option in object["options"]?.grokArray ?? [] {
                guard let row = option.grokObject,
                      let optionID = row["optionId"]?.grokString,
                      let kind = row["kind"]?.grokString else { continue }
                options[kind] = optionID
            }
            guard options["allow_once"] != nil, options["reject_once"] != nil else {
                Task { try? await client?.respondError(id: id, code: -32000, message: "Permission options are not representable.") }
                continuation?.yield(.sessionError("Grok pidió un permiso con opciones que esta app no puede mostrar. La petición se rechazó."))
                return
            }
            let requestID = requestKey(id)
            pendingApprovals[requestID] = (id, options)
            continuation?.yield(.permissionAsked(
                requestID: requestID,
                sessionID: object["sessionId"]?.grokString ?? selectedSessionID ?? "",
                tool: "Grok · \(title)",
                command: title,
                explanation: "Grok pide permiso para usar esta herramienta en tu computadora."
            ))
        case .disconnected(let reason):
            continuation?.yield(.disconnected(reason))
        }
    }

    private var projectID: String { "grok:\(pairing?.host ?? ""):\(pairing?.port ?? 0)" }

    private func requestKey(_ id: CodexAppServerRequestID) -> String {
        switch id { case .string(let value): return value; case .integer(let value): return String(value) }
    }

    private static func displayTitle(_ title: String?) -> String {
        let candidate = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (candidate?.isEmpty == false ? candidate! : "Nueva conversación")
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > 64 else { return compact }
        return String(compact.prefix(61)) + "…"
    }

    private static func sameDirectory(_ left: String, _ right: String) -> Bool {
        func norm(_ value: String) -> String {
            var text = value
            if text.count > 1, text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return norm(left) == norm(right)
    }

    private static func date(_ value: String?) -> Date {
        guard let value else { return Date() }
        return ISO8601DateFormatter().date(from: value) ?? Date()
    }

    private static let unsupported = RemoteBackendError.unsupportedFeature("Esta operación no está en el adaptador de Grok.")
    public func configure(with pairing: RemotePairing) async throws { throw Self.unsupported }
    public func healthCheck() async throws -> RemoteHealth {
        RemoteHealth(healthy: client != nil, version: pairing?.grokVersion ?? "unknown", backendType: .grok)
    }
    public func listSessions() async throws -> [RemoteSession] {
        try await listSessions(projectID: projectID).map {
            RemoteSession(id: $0.id, title: $0.title, directory: pairing?.directory ?? "", updatedAt: $0.timestamp, backendType: .grok)
        }
    }
    public func createSession(title: String) async throws -> RemoteSession {
        let session = try await createSession(projectID: projectID, title: title)
        return RemoteSession(id: session.id, title: session.title, directory: pairing?.directory ?? "", updatedAt: session.timestamp, backendType: .grok)
    }
    public func sendPrompt(sessionID: String, text: String, agent: String?, modelProvider: String?, modelID: String?) async throws {
        try await selectSession(sessionID)
        try await sendPrompt(text, agent: nil, model: nil)
    }
    public func abort(sessionID: String) async throws { try await abort() }
    public func replyPermission(sessionID: String, permissionID: String, response: String) async throws { throw Self.unsupported }
    public func messages(sessionID: String) async throws -> [RemoteMessage] { throw Self.unsupported }
    public func events() -> AsyncThrowingStream<RemoteEvent, Error> { AsyncThrowingStream { $0.finish(throwing: Self.unsupported) } }
    public func listFiles(path: String) async throws -> [RemoteFileNode] { throw Self.unsupported }
    public func fileContent(path: String) async throws -> RemoteFileContent { throw Self.unsupported }
    public func runShell(sessionID: String, command: String, agent: String?, workdir: String?) async throws -> ShellResult { throw Self.unsupported }
    public func sessionDiff(sessionID: String) async throws -> [SessionDiff] { throw Self.unsupported }
    public func providers() async throws -> ProviderListResult { throw Self.unsupported }
    public func config() async throws -> ConfigInfo { throw Self.unsupported }
    public func commands() async throws -> [CommandInfo] { [] }
    public func getPath() async throws -> String { pairing?.directory ?? "" }
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] { throw Self.unsupported }
    public func fileContent(path: String) async throws -> WorkbenchFileContent { throw Self.unsupported }
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] { throw Self.unsupported }
    public func runShell(command: String, agent: String?) async throws -> ShellResult { throw Self.unsupported }
    public func availableProviders() async throws -> ProviderListResult {
        ProviderListResult(all: [ProviderInfo(id: "grok", name: "Grok", models: [:])], connected: ["grok"], defaultProvider: "grok")
    }
    public func availableCommands() async throws -> [CommandInfo] { [] }
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {}
}

private extension CodexJSONValue {
    var grokObject: [String: CodexJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var grokArray: [CodexJSONValue]? { if case .array(let value) = self { value } else { nil } }
    var grokString: String? { if case .string(let value) = self { value } else { nil } }
}

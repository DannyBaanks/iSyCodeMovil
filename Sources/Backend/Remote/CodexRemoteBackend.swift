import Foundation

/// Experimental Codex App Server adapter. Only the operations declared in the
/// pairing profile and represented by this adapter are enabled.
@MainActor
public final class CodexRemoteBackend: WorkbenchBackend, RemoteBackend {
    public var mode: BackendMode { .remote }
    public let remoteType: RemoteBackendType = .codex
    public var baseURL: URL { URL(string: "ws://\(pairing?.host ?? "127.0.0.1"):\(pairing?.port ?? 1)")! }
    public var authHeaders: [String: String] { [:] }
    public let eventStream: AsyncStream<WorkbenchEvent>
    private var continuation: AsyncStream<WorkbenchEvent>.Continuation?
    private var pairing: CodexPairing?
    private var client: CodexAppServerClient?
    private var eventTask: Task<Void, Never>?
    private var sessions: [Session] = []
    private var selectedSessionID: String?
    private var activeTurn = false
    private var pendingApprovals: [String: (CodexAppServerRequestID, String, [String])] = [:]
    private var commandOutput: [String: String] = [:]

    public init() {
        var c: AsyncStream<WorkbenchEvent>.Continuation?
        eventStream = AsyncStream { c = $0 }
        continuation = c
    }

    public var connectionStatus: String { get async { "Codex App Server · Experimental · Tailscale/VPN" } }
    public var currentSessionID: String? { get async { selectedSessionID } }

    public func connectRemote(pairing: BackendPairing) async throws {
        guard case .codex(let value) = pairing else { throw Self.unsupported }
        eventTask?.cancel()
        eventTask = nil
        await client?.disconnect(reason: "reconnecting")
        let client = try CodexAppServerClient(pairing: value)
        try await client.connect()
        self.pairing = value
        self.client = client
        try await startEventStream()
        continuation?.yield(.connected)
    }

    public func disconnect() async {
        eventTask?.cancel(); eventTask = nil
        await client?.disconnect()
        client = nil; pairing = nil; selectedSessionID = nil; activeTurn = false
        continuation?.yield(.disconnected("Codex App Server disconnected"))
    }

    public func useNativeRuntime() async throws { throw Self.unsupported }
    public func listProjects() async throws -> [Project] {
        guard let pairing else { throw Self.unsupported }
        return [Project(id: projectID, name: "Codex @ \(pairing.host)", path: pairing.directory, avatarColor: .white)]
    }
    public func listSessions(projectID: String) async throws -> [Session] {
        guard let client, let pairing, pairing.profile.threadList else { throw Self.unsupported }
        let response = try await client.request(method: "thread/list", params: .object([
            "cwd": .string(pairing.directory), "limit": .integer(100), "sortKey": .string("updated_at")
        ]))
        guard let data = response.object?["data"]?.array else { throw CodexAppServerError.invalidMessage }
        sessions = data.compactMap { value in
            guard let obj = value.object, let id = obj["id"]?.string else { return nil }
            let title = Self.displayTitle(name: obj["name"]?.string, preview: obj["preview"]?.string)
            let timestamp = Date(timeIntervalSince1970: Double(obj["updatedAt"]?.integer ?? obj["createdAt"]?.integer ?? 0))
            return Session(id: id, projectId: projectID, title: title, lastEventSummary: obj["preview"]?.string, timestamp: timestamp)
        }
        return sessions
    }

    /// Codex may return the first user prompt as `preview` when a thread has no
    /// generated name. Keep that useful context, but never use an entire prompt
    /// as a navigation title or confirmation-dialog message.
    private static func displayTitle(name: String?, preview: String?) -> String {
        let candidate = [name, preview]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Codex session"
        let firstLine = candidate.components(separatedBy: .newlines).first ?? candidate
        let compact = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > 64 else { return compact }
        return String(compact.prefix(61)) + "…"
    }

    public func createSession(projectID: String, title: String) async throws -> Session {
        guard let client, let pairing, pairing.profile.threadStart else { throw Self.unsupported }
        let result = try await client.request(method: "thread/start", params: .object(["cwd": .string(pairing.directory)]))
        guard let thread = result.object?["thread"]?.object, let id = thread["id"]?.string else { throw CodexAppServerError.invalidMessage }
        let session = Session(id: id, projectId: projectID, title: thread["name"]?.string ?? title)
        sessions.insert(session, at: 0)
        selectedSessionID = id
        return session
    }
    public func renameSession(sessionID: String, title: String) async throws { throw Self.unsupported }
    public func deleteSession(sessionID: String) async throws { throw Self.unsupported }
    public func selectSession(_ sessionID: String) async throws {
        guard let client, let pairing, pairing.profile.threadResume,
              sessions.contains(where: { $0.id == sessionID }) else { throw Self.unsupported }
        _ = try await client.request(method: "thread/resume", params: .object(["threadId": .string(sessionID)]))
        selectedSessionID = sessionID
    }
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        guard let id = selectedSessionID else { throw Self.unsupported }
        try await sendPrompt(sessionID: id, text: text, agent: agent, modelProvider: model?.route, modelID: model?.apiModelId)
    }
    public func abort() async throws {
        guard let client, let pairing, pairing.profile.turnInterrupt, let selectedSessionID, activeTurn else { return }
        _ = try await client.request(method: "turn/interrupt", params: .object(["threadId": .string(selectedSessionID)]))
    }
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        guard let client, let pending = pendingApprovals[requestID] else { throw Self.unsupported }
        let (rpcID, _, choices) = pending
        let selected: String
        switch decision {
        case .allowOnce, .allowSequence: selected = "accept"
        case .allowAlways: selected = "acceptForSession"
        case .decline: selected = "decline"
        case .cancel: selected = "cancel"
        case .deny: throw Self.unsupported
        }
        guard choices.contains(selected) else { throw Self.unsupported }
        try await client.respond(id: rpcID, result: .object(["decision": .string(selected)]))
        pendingApprovals.removeValue(forKey: requestID)
    }
    public func loadHistory(sessionID: String) async throws -> [TimelineEvent] {
        guard let client, let pairing, pairing.profile.threadRead else { throw Self.unsupported }
        let result = try await client.request(method: "thread/read", params: .object(["threadId": .string(sessionID), "includeTurns": .bool(true)]))
        guard let thread = result.object?["thread"]?.object else { throw CodexAppServerError.invalidMessage }
        var events: [TimelineEvent] = []
        for turn in thread["turns"]?.array ?? [] {
            for item in turn.object?["items"]?.array ?? [] {
                guard let item = item.object else { continue }
                let type = item["type"]?.string ?? ""
                let itemID = item["id"]?.string ?? UUID().uuidString
                if type == "userMessage", let content = item["content"]?.array {
                    let text = content.compactMap { $0.object?["text"]?.string }.joined()
                    if !text.isEmpty {
                        var event = TimelineEvent(id: itemID, kind: .userPrompt, agentMode: .build)
                        event.promptText = text
                        events.append(event)
                    }
                } else if type == "agentMessage", let text = item["text"]?.string {
                    var event = TimelineEvent(id: itemID, kind: .assistantText, agentMode: .build)
                    event.assistantText = text
                    events.append(event)
                } else if type == "commandExecution" {
                    events.append(Self.commandEvent(item, id: itemID, fallbackState: "completed"))
                } else if type == "fileChange" {
                    events.append(Self.fileChangeEvent(item, id: itemID))
                }
            }
        }
        return events
    }
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

    private func consume(_ event: CodexAppServerEvent) {
        switch event {
        case .notification(let method, let params):
            let p = params.object ?? [:]
            if method == "item/agentMessage/delta", let itemID = p["itemId"]?.string, let delta = p["delta"]?.string {
                continuation?.yield(.partDelta(partID: itemID, delta: delta))
            } else if method == "item/started", let item = p["item"]?.object,
                      item["type"]?.string == "commandExecution" {
                let id = item["id"]?.string ?? UUID().uuidString
                commandOutput[id] = ""
                let event = Self.commandEvent(item, id: id, fallbackState: "running")
                continuation?.yield(.partUpdated(partID: id, kind: "tool", text: nil, tool: event.toolName, callID: id, status: "running", input: event.toolArguments ?? [:], output: nil, error: nil))
            } else if method == "item/completed", let item = p["item"]?.object {
                let id = item["id"]?.string ?? UUID().uuidString
                if item["type"]?.string == "commandExecution" {
                    let event = Self.commandEvent(item, id: id, fallbackState: "completed")
                    continuation?.yield(.partUpdated(partID: id, kind: "tool", text: nil, tool: event.toolName, callID: id, status: event.toolState == .failed ? "error" : "completed", input: event.toolArguments ?? [:], output: event.toolOutput, error: nil))
                    commandOutput.removeValue(forKey: id)
                } else if item["type"]?.string == "fileChange" {
                    let event = Self.fileChangeEvent(item, id: id)
                    continuation?.yield(.partUpdated(partID: id, kind: "tool", text: nil, tool: event.toolName, callID: id, status: "completed", input: event.toolArguments ?? [:], output: event.toolOutput, error: nil))
                }
            } else if method == "item/commandExecution/outputDelta",
                      let itemID = p["itemId"]?.string, let delta = p["delta"]?.string {
                let accumulated = (commandOutput[itemID] ?? "") + delta
                commandOutput[itemID] = accumulated
                continuation?.yield(.partUpdated(partID: itemID, kind: "tool", text: nil, tool: "bash", callID: itemID, status: "running", input: [:], output: accumulated, error: nil))
            } else if method == "turn/completed" {
                activeTurn = false
                if let id = p["threadId"]?.string {
                    if p["turn"]?.object?["status"]?.string == "failed" {
                        continuation?.yield(.sessionError("Codex turn failed."))
                    } else {
                        continuation?.yield(.sessionIdle(sessionID: id))
                    }
                }
            }
        case .request(let id, let method, let params):
            guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" else {
                continuation?.yield(.sessionError("Codex sent an unsupported server request (\(method)); it was left unanswered."))
                return
            }
            let p = params.object ?? [:]
            if method == "item/commandExecution/requestApproval" && pairing?.profile.commandApproval != true {
                continuation?.yield(.sessionError("Codex sent command approval outside the declared pairing profile; it was left unanswered."))
                return
            }
            if method == "item/fileChange/requestApproval" && pairing?.profile.fileApproval != true {
                continuation?.yield(.sessionError("Codex sent file approval outside the declared pairing profile; it was left unanswered."))
                return
            }
            let itemID = p["itemId"]?.string ?? "approval"
            let command = p["command"]?.string ?? ""
            let reason = p["reason"]?.string ?? (method == "item/fileChange/requestApproval" ? "Codex solicita permiso para modificar archivos" : "Codex solicita ejecutar un comando")
            let offeredValues = p["availableDecisions"]?.array
            let validChoices: [String]
            if method == "item/commandExecution/requestApproval" {
                guard p["kind"]?.string != "writeStdin",
                      p["proposedExecpolicyAmendment"] == nil || p["proposedExecpolicyAmendment"] == .null,
                      p["proposedNetworkPolicyAmendments"] == nil || p["proposedNetworkPolicyAmendments"] == .null,
                      p["additionalPermissions"] == nil || p["additionalPermissions"] == .null,
                      p["networkApprovalContext"] == nil || p["networkApprovalContext"] == .null,
                      let offeredValues,
                      offeredValues.allSatisfy({ $0.string != nil }) else {
                    continuation?.yield(.sessionError("Codex requested command approval with options this app cannot represent; the request remains pending."))
                    return
                }
                validChoices = offeredValues.compactMap(\.string)
                guard Set(validChoices).isSubset(of: Set(["accept", "acceptForSession", "decline", "cancel"])) else {
                    continuation?.yield(.sessionError("Codex offered command approval options this app cannot represent; the request remains pending."))
                    return
                }
            } else {
                guard p["grantRoot"] == nil || p["grantRoot"] == .null else {
                    continuation?.yield(.sessionError("Codex requested a file approval with a workspace grant this app cannot represent; the request remains pending."))
                    return
                }
                validChoices = ["accept", "acceptForSession", "decline", "cancel"]
            }
            guard validChoices.contains("accept"), validChoices.contains("acceptForSession"), validChoices.contains("decline"), validChoices.contains("cancel") else {
                continuation?.yield(.sessionError("Codex approval choices do not match the available controls; the request remains pending."))
                return
            }
            let requestID = requestKey(id)
            pendingApprovals[requestID] = (id, method, validChoices)
            continuation?.yield(.permissionAsked(requestID: requestID, sessionID: p["threadId"]?.string ?? selectedSessionID ?? "", tool: method == "item/fileChange/requestApproval" ? "Codex file change" : "Codex command", command: command.isEmpty ? itemID : command, explanation: reason))
        case .disconnected(let reason):
            continuation?.yield(.disconnected(reason))
        }
    }

    private var projectID: String { "codex:\(pairing?.host ?? ""):\(pairing?.port ?? 0)" }

    private static func commandEvent(_ item: [String: CodexJSONValue], id: String, fallbackState: String) -> TimelineEvent {
        let command = item["command"]?.string ?? ""
        let cwd = item["cwd"]?.string ?? ""
        let rawStatus = item["status"]?.string ?? fallbackState
        let state: ToolCallState = rawStatus == "inProgress" || rawStatus == "running" ? .running : (rawStatus == "failed" ? .failed : .success)
        var event = TimelineEvent.toolCall(id: id, name: "bash", arguments: ["command": command, "cwd": cwd], state: state, agentMode: .build)
        event.toolOutput = item["aggregatedOutput"]?.string
        event.toolDuration = item["durationMs"]?.integer.map { Double($0) / 1_000 }
        return event
    }

    private static func fileChangeEvent(_ item: [String: CodexJSONValue], id: String) -> TimelineEvent {
        let changes = item["changes"]?.array ?? []
        let paths = changes.compactMap { $0.object?["path"]?.string }
        let diff = changes.compactMap { change -> String? in
            guard let object = change.object else { return nil }
            let path = object["path"]?.string ?? "file"
            let body = object["diff"]?.string ?? ""
            return body.isEmpty ? nil : "--- \(path)\n\(body)"
        }.joined(separator: "\n")
        var event = TimelineEvent.toolCall(id: id, name: "file_change", arguments: ["files": paths.joined(separator: ", ")], state: .success, agentMode: .build)
        event.toolOutput = diff.isEmpty ? "Updated \(paths.joined(separator: ", "))" : diff
        return event
    }

    private func requestKey(_ id: CodexAppServerRequestID) -> String {
        switch id { case .string(let value): return value; case .integer(let value): return String(value) }
    }

    private static let unsupported = RemoteBackendError.unsupportedFeature("This operation is not supported by the Codex v1 adapter")
    public func configure(with pairing: RemotePairing) async throws { throw Self.unsupported }
    public func healthCheck() async throws -> RemoteHealth { RemoteHealth(healthy: client != nil, version: pairing?.codexVersion ?? "unknown", backendType: .codex) }
    public func listSessions() async throws -> [RemoteSession] { try await listSessions(projectID: projectID).map { RemoteSession(id: $0.id, title: $0.title, directory: pairing?.directory ?? "", updatedAt: $0.timestamp, backendType: .codex) } }
    public func createSession(title: String) async throws -> RemoteSession { let s = try await createSession(projectID: projectID, title: title); return RemoteSession(id: s.id, title: s.title, directory: pairing?.directory ?? "", updatedAt: s.timestamp, backendType: .codex) }
    public func sendPrompt(sessionID: String, text: String, agent: String?, modelProvider: String?, modelID: String?) async throws {
        guard let client, let pairing, pairing.profile.turnStart, pairing.profile.textStreaming,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.unsupported }
        var params: [String: CodexJSONValue] = [
            "threadId": .string(sessionID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]
        if modelProvider == "codex", let modelID {
            params["model"] = .string(modelID)
        }
        _ = try await client.request(method: "turn/start", params: .object(params))
        activeTurn = true
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
        guard let client, pairing?.profile.modelList == true else { throw Self.unsupported }
        var cursor: String?
        var models: [String: [String: Any]] = [:]
        var pageCount = 0
        repeat {
            pageCount += 1
            var params: [String: CodexJSONValue] = ["limit": .integer(100), "includeHidden": .bool(false)]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await client.request(method: "model/list", params: .object(params))
            guard let result = response.object, let entries = result["data"]?.array else { throw CodexAppServerError.invalidMessage }
            for entry in entries {
                guard let object = entry.object,
                      let id = object["model"]?.string ?? object["id"]?.string else { continue }
                models[id] = ["displayName": object["displayName"]?.string ?? id]
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil && pageCount < 20
        return ProviderListResult(
            all: [ProviderInfo(id: "codex", name: "Codex", models: models)],
            connected: ["codex"],
            defaultProvider: "codex"
        )
    }
    public func availableCommands() async throws -> [CommandInfo] { [] }
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {}
}

private extension CodexJSONValue {
    var object: [String: CodexJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [CodexJSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
}

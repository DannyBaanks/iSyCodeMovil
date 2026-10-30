import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GrokACPEvent: Sendable {
    case notification(method: String, params: CodexJSONValue)
    case request(id: CodexAppServerRequestID, method: String, params: CodexJSONValue)
    case disconnected(String?)
}

public enum GrokACPError: Error, LocalizedError, Sendable {
    case invalidPairing
    case notConnected
    case notInitialized
    case authenticationFailed
    case protocolMismatch(expected: Int, received: String)
    case requestTimedOut(String)
    case requestFailed(Int, String)
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .invalidPairing: return "Invalid Grok pairing link or unsupported ACP profile."
        case .notConnected: return "Grok agent server is disconnected."
        case .notInitialized: return "Grok agent server has not completed initialize."
        case .authenticationFailed: return "Grok bridge rejected the pairing token."
        case .protocolMismatch(let expected, let received): return "Grok ACP protocol mismatch (expected \(expected), received \(received))."
        case .requestTimedOut(let method): return "Grok request timed out: \(method)."
        case .requestFailed(let code, let message): return "Grok request failed (\(code)): \(message)"
        case .invalidMessage: return "Grok sent an invalid JSON-RPC message."
        }
    }
}

private struct GrokRPCInbound: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let code: Int
        let message: String
    }

    let id: CodexAppServerRequestID?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: Failure?
}

private struct GrokRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexJSONValue
}

private struct GrokRPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: CodexJSONValue
}

private struct GrokRPCResponse: Encodable {
    let jsonrpc = "2.0"
    let id: CodexAppServerRequestID
    let result: CodexJSONValue
}

private struct GrokRPCErrorResponse: Encodable {
    struct Body: Encodable, Sendable {
        let code: Int
        let message: String
    }

    let jsonrpc = "2.0"
    let id: CodexAppServerRequestID
    let error: Body
}

public actor GrokACPClient {
    public let events: AsyncStream<GrokACPEvent>

    private let endpoint: URL
    private let token: String
    private let profile: GrokCapabilityProfile
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var readTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<GrokACPEvent>.Continuation?
    private var pending: [CodexAppServerRequestID: CheckedContinuation<CodexJSONValue, Error>] = [:]
    private var timeouts: [CodexAppServerRequestID: Task<Void, Never>] = [:]
    private var nextID: Int64 = 1
    private var isInitialized = false

    public init(pairing: GrokPairing) throws {
        guard pairing.profile.supportsCoreConversation,
              let endpoint = URL(string: "ws://\(pairing.host):\(pairing.port)") else {
            throw GrokACPError.invalidPairing
        }
        self.endpoint = endpoint
        self.token = pairing.token
        self.profile = pairing.profile
        self.urlSession = URLSession(configuration: .ephemeral)
        var continuation: AsyncStream<GrokACPEvent>.Continuation?
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func connect() async throws {
        guard profile.supportsCoreConversation, endpoint.scheme == "ws", endpoint.host != nil else {
            throw GrokACPError.invalidPairing
        }
        guard socket == nil else { return }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        do {
            let result = try await sendRequest(method: "initialize", params: .object([
                "protocolVersion": .integer(Int64(profile.protocolVersion)),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("ISyCodeMovil"),
                    "version": .string("0.1.0")
                ])
            ]), timeout: 15)
            guard Self.protocolVersion(result) == profile.protocolVersion else {
                throw GrokACPError.protocolMismatch(expected: profile.protocolVersion, received: String(describing: result))
            }
            isInitialized = true
        } catch {
            await disconnect(reason: "initialize failed")
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse {
                throw GrokACPError.authenticationFailed
            }
            throw error
        }
    }

    public func request(method: String, params: CodexJSONValue = .object([:]), timeout: TimeInterval? = 30) async throws -> CodexJSONValue {
        guard isInitialized else { throw GrokACPError.notInitialized }
        return try await sendRequest(method: method, params: params, timeout: timeout)
    }

    public func notify(method: String, params: CodexJSONValue) async throws {
        guard isInitialized else { throw GrokACPError.notInitialized }
        try await send(GrokRPCNotification(method: method, params: params))
    }

    public func respond(id: CodexAppServerRequestID, result: CodexJSONValue) async throws {
        guard socket != nil else { throw GrokACPError.notConnected }
        try await send(GrokRPCResponse(id: id, result: result))
    }

    public func respondError(id: CodexAppServerRequestID, code: Int, message: String) async throws {
        guard socket != nil else { throw GrokACPError.notConnected }
        try await send(GrokRPCErrorResponse(id: id, error: .init(code: code, message: message)))
    }

    public func disconnect(reason: String? = nil) async {
        isInitialized = false
        readTask?.cancel()
        readTask = nil
        let socket = self.socket
        self.socket = nil
        socket?.cancel(with: .goingAway, reason: nil)
        failPending(GrokACPError.notConnected)
        eventContinuation?.yield(.disconnected(reason))
        eventContinuation?.finish()
    }

    private func sendRequest(method: String, params: CodexJSONValue, timeout: TimeInterval?) async throws -> CodexJSONValue {
        guard socket != nil else { throw GrokACPError.notConnected }
        let id = CodexAppServerRequestID.integer(nextID)
        nextID += 1
        let payload = try JSONEncoder().encode(GrokRPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if let timeout {
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.timeout(id: id, method: method)
                }
            }
            Task { [weak self] in await self?.sendPending(payload, id: id) }
        }
    }

    private func sendPending(_ data: Data, id: CodexAppServerRequestID) async {
        do {
            guard let socket else { throw GrokACPError.notConnected }
            guard let message = String(data: data, encoding: .utf8) else { throw GrokACPError.invalidMessage }
            try await socket.send(.string(message))
        } catch {
            timeouts.removeValue(forKey: id)?.cancel()
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func send<T: Encodable>(_ value: T) async throws {
        guard let socket else { throw GrokACPError.notConnected }
        let data = try JSONEncoder().encode(value)
        guard let message = String(data: data, encoding: .utf8) else { throw GrokACPError.invalidMessage }
        try await socket.send(.string(message))
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let socket else { return }
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let received): data = received
                case .string(let received): data = Data(received.utf8)
                @unknown default: throw GrokACPError.invalidMessage
                }
                try route(try JSONDecoder().decode(GrokRPCInbound.self, from: data))
            }
        } catch is CancellationError {
            return
        } catch {
            failPending(error)
            let failedSocket = socket
            socket = nil
            isInitialized = false
            failedSocket?.cancel(with: .abnormalClosure, reason: nil)
            eventContinuation?.yield(.disconnected(error.localizedDescription))
            eventContinuation?.finish()
        }
    }

    private func route(_ frame: GrokRPCInbound) throws {
        if let method = frame.method {
            guard !method.isEmpty, frame.result == nil, frame.error == nil else {
                throw GrokACPError.invalidMessage
            }
            let params = frame.params ?? .object([:])
            if let id = frame.id {
                eventContinuation?.yield(.request(id: id, method: method, params: params))
            } else {
                eventContinuation?.yield(.notification(method: method, params: params))
            }
            return
        }
        guard frame.id != nil, frame.params == nil,
              (frame.result == nil) != (frame.error == nil) else {
            throw GrokACPError.invalidMessage
        }
        guard let id = frame.id, let continuation = pending.removeValue(forKey: id) else {
            throw GrokACPError.invalidMessage
        }
        timeouts.removeValue(forKey: id)?.cancel()
        if let error = frame.error {
            continuation.resume(throwing: GrokACPError.requestFailed(error.code, error.message))
        } else if let result = frame.result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: GrokACPError.invalidMessage)
        }
    }

    private func timeout(id: CodexAppServerRequestID, method: String) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: GrokACPError.requestTimedOut(method))
    }

    private func failPending(_ error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        let tasks = Array(timeouts.values)
        timeouts.removeAll()
        for task in tasks { task.cancel() }
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func protocolVersion(_ value: CodexJSONValue) -> Int? {
        guard case .object(let fields) = value else { return nil }
        switch fields["protocolVersion"] {
        case .integer(let number): return Int(number)
        case .number(let number): return Int(number)
        default: return nil
        }
    }
}

import Foundation

/// What the computer says about the folder it was linked from.
public struct SandboxBridgeInfo: Equatable, Sendable {
    public let projectName: String
    /// `owner/name` when the folder has a github.com remote.
    public let repo: String?
    public let defaultBranch: String?
    /// Whether the computer holds a GitHub token. The token itself never travels here.
    public let hasGitHubAccount: Bool
}

public struct SandboxStatus: Equatable, Sendable {
    public let id: String
    public let phase: String
    public let remainingMs: Double
    public let explanation: String

    public var isUsable: Bool { phase != "destroyed" }
}

public struct SandboxTransferReport: Equatable, Sendable {
    public let files: Int
    public let excluded: [String]
}

public struct SandboxPullRequest: Equatable, Sendable {
    public let url: String
    public let branch: String
    public let number: Int?
}

public enum SandboxHostError: Error, LocalizedError, Sendable {
    case unauthorized
    case refused(String)
    case unreachable(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "La computadora rechazó el enlace del sandbox. Vuelve a ejecutar el comando y pega el enlace nuevo."
        case .refused(let reason):
            return reason
        case .unreachable(let reason):
            return "No se pudo hablar con el sandbox de tu computadora: \(reason)"
        case .invalidResponse:
            return "La computadora devolvió una respuesta que la app no entiende."
        }
    }
}

/// HTTP client for the sandbox orchestrator behind the Bridge gateway.
///
/// Every call carries the bearer token from the pairing. Nothing here holds a GitHub
/// credential: cloning private repositories and opening pull requests are requests the
/// computer carries out with its own token.
public struct SandboxHostClient: Sendable {
    public let pairing: SandboxPairing
    private let session: URLSession

    public init(pairing: SandboxPairing, session: URLSession = .shared) {
        self.pairing = pairing
        self.session = session
    }

    // MARK: - Routes

    public func bridgeInfo() async throws -> SandboxBridgeInfo {
        let json = try await object("GET", "api/bridge")
        let project = json["project"] as? [String: Any] ?? [:]
        return SandboxBridgeInfo(
            projectName: project["name"] as? String ?? pairing.projectName,
            repo: project["repo"] as? String,
            defaultBranch: project["defaultBranch"] as? String,
            hasGitHubAccount: json["github"] as? Bool ?? false
        )
    }

    public func listSandboxes() async throws -> [SandboxStatus] {
        let json = try await object("GET", "api/sandboxes")
        let items = json["sandboxes"] as? [[String: Any]] ?? []
        return items.compactMap(Self.status(from:))
    }

    /// `repo` is remembered by the computer as the pull request target.
    public func createSandbox(ttlMinutes: Int, repo: String?) async throws -> String {
        var body: [String: Any] = ["ttlMinutes": ttlMinutes]
        if let repo, !repo.isEmpty { body["repo"] = repo }
        let json = try await object("POST", "api/sandboxes", body: body)
        guard let id = json["id"] as? String else { throw SandboxHostError.invalidResponse }
        return id
    }

    public func status(id: String) async throws -> SandboxStatus {
        let json = try await object("GET", "api/sandboxes/\(id)")
        guard let status = Self.status(from: json) else { throw SandboxHostError.invalidResponse }
        return status
    }

    /// Resets the countdown and wakes a suspended sandbox.
    public func touch(id: String) async throws {
        _ = try await object("POST", "api/sandboxes/\(id)")
    }

    /// Copies the linked folder into the sandbox. The computer decides which folder: the
    /// one the link was started from, never one named by the phone.
    public func sendProjectFolder(id: String) async throws -> SandboxTransferReport {
        let json = try await object("POST", "api/sandboxes/\(id)/folder", body: [:], timeout: 300)
        return SandboxTransferReport(
            files: (json["files"] as? NSNumber)?.intValue ?? 0,
            excluded: json["excluded"] as? [String] ?? []
        )
    }

    public func destroy(id: String) async throws {
        var components = URLComponents(url: url("api/sandboxes/\(id)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "force", value: "1")]
        guard let target = components?.url else { throw SandboxHostError.invalidResponse }
        _ = try await send(request("DELETE", target, body: nil, timeout: 60))
    }

    /// One tool call inside the sandbox. `arguments` must be JSON-encodable.
    public func tool(id: String, name: String, arguments: [String: Any], timeout: TimeInterval = 150) async throws -> [String: Any] {
        let json = try await object("POST", "api/sandboxes/\(id)/tool", body: ["name": name, "args": arguments], timeout: timeout)
        return json["result"] as? [String: Any] ?? [:]
    }

    /// The computer pushes the work to a `movilclaw/<task>` branch and opens the pull
    /// request with its own token. It never pushes to the base branch and never merges.
    public func openPullRequest(id: String, task: String, title: String, body: String, baseBranch: String?) async throws -> SandboxPullRequest {
        var payload: [String: Any] = ["task": task, "title": title, "body": body]
        if let baseBranch, !baseBranch.isEmpty { payload["baseBranch"] = baseBranch }
        let json = try await object("POST", "api/sandboxes/\(id)/pr", body: payload, timeout: 420)
        guard let link = json["pullRequest"] as? String else { throw SandboxHostError.invalidResponse }
        return SandboxPullRequest(
            url: link,
            branch: json["branch"] as? String ?? "",
            number: (json["number"] as? NSNumber)?.intValue
        )
    }

    /// The sandbox's working tree as a `.tar.gz`, to keep or hand to someone else.
    public func downloadWork(id: String) async throws -> Data {
        try await send(request("GET", url("api/sandboxes/\(id)/work"), body: nil, timeout: 300))
    }

    // MARK: - Transport

    private static func status(from json: [String: Any]) -> SandboxStatus? {
        guard let id = json["id"] as? String, let phase = json["phase"] as? String else { return nil }
        return SandboxStatus(
            id: id,
            phase: phase,
            remainingMs: (json["remainingMs"] as? NSNumber)?.doubleValue ?? 0,
            explanation: json["explanation"] as? String ?? ""
        )
    }

    private func url(_ path: String) -> URL {
        pairing.baseURL.appendingPathComponent(path)
    }

    private func request(_ method: String, _ target: URL, body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func object(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> [String: Any] {
        let data = try await send(request(method, url(path), body: body, timeout: timeout))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SandboxHostError.invalidResponse
        }
        return json
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SandboxHostError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SandboxHostError.invalidResponse }
        if (200..<300).contains(http.statusCode) { return data }
        if http.statusCode == 401 { throw SandboxHostError.unauthorized }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw SandboxHostError.refused(json?["error"] as? String ?? "La computadora respondió con el código \(http.statusCode).")
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Monitor tipo raw.github: el daemon de iSyCode / IsyMCP en tu PC publica un
// manifiesto JSON (en raw.githubusercontent.com o en tu red local) y el
// teléfono lo consulta con ETag. Formato en docs/GOOGLE_ASSISTANT.md.

public struct DaemonTask: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let source: String
    public let status: String
    public let createdAt: String
}

public enum ManifestPoll: Equatable, Sendable {
    case changed([DaemonTask], etag: String?)
    case notModified
}

public enum DaemonManifest {
    public static let maxTasks = 50

    /// Accepts `{"tasks":[…]}` or a bare array. Entries without id or title are skipped.
    public static func parse(_ data: Data) -> [DaemonTask] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let items = (root as? [Any]) ?? ((root as? [String: Any])?["tasks"] as? [Any]) ?? []
        let tasks: [DaemonTask] = items.compactMap { element in
            guard let object = element as? [String: Any] else { return nil }
            func field(_ key: String) -> String {
                ((object[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let id = field("id"), title = field("title")
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let body = field("body").isEmpty ? field("summary") : field("body")
            return DaemonTask(id: String(id.prefix(120)), title: String(title.prefix(200)), body: String(body.prefix(1000)),
                              source: String((field("source").isEmpty ? "pc" : field("source")).prefix(40)),
                              status: String((field("status").isEmpty ? "completed" : field("status")).prefix(40)),
                              createdAt: String(field("createdAt").prefix(40)))
        }
        return Array(tasks.prefix(maxTasks))
    }

    public static func newTasks(seen: Set<String>, incoming: [DaemonTask]) -> [DaemonTask] {
        incoming.filter { !seen.contains($0.id) }
    }

    /// Only https, or http inside the local network where the PC daemon usually lives.
    public static func isAllowedURL(_ value: String) -> Bool {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("https://") { return url.count > "https://".count + 3 }
        guard url.hasPrefix("http://") else { return false }
        let host = String(url.dropFirst("http://".count).split(separator: "/").first ?? "").split(separator: ":").first.map(String.init) ?? ""
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        return host.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
    }

    public static func poll(_ urlString: String, etag: String?, session: URLSession = .shared) async throws -> ManifestPoll {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GoogleAPIError(status: 0, message: "Dirección inválida.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 304: return .notModified
        case 200..<300: return .changed(parse(data), etag: http?.value(forHTTPHeaderField: "ETag"))
        case let status: throw GoogleAPIError(status: status, message: "El manifiesto respondió HTTP \(status).")
        }
    }
}

/// The user's semantic memory, in one private JSON file. Shared by the
/// assistant screens and by the agent's memory tools.
public enum AssistantMemoryFile {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("assistant", isDirectory: true).appendingPathComponent("memory.json")
    }

    public static func load(from url: URL = url) -> [ContextNode] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ContextNode].self, from: data)) ?? []
    }

    public static func save(_ nodes: [ContextNode], to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(nodes).write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Builds a node with a clean three-level path and appends it, newest first.
    @discardableResult
    public static func append(title: String, summary: String, path: [String], priority: ContextPriority,
                              source: String, to url: URL = url, now: Date = Date()) throws -> ContextNode {
        let cleanSummary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = ContextNode(id: "ctx_" + UUID().uuidString.prefix(8).lowercased(),
                               title: String((cleanTitle.isEmpty ? String(cleanSummary.prefix(60)) : cleanTitle).prefix(120)),
                               summary: cleanSummary, path: SemanticContext.cleanPath(path),
                               priority: priority, source: source, createdAt: now)
        try save([node] + load(from: url), to: url)
        return node
    }
}

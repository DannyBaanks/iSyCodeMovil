import Foundation

/// One private folder per conversation, `Application Support/IysCodeMovil/sandbox-<id>`.
///
/// Two conversations can then run at the same time without touching each other's files,
/// and Ajustes can measure and clean them. A folder is a few KB until the agent writes to
/// it. When the person picked a folder in Files, every conversation keeps sharing that
/// folder instead: it is their explicit choice.
public enum ConversationSandboxes {
    public static let prefix = "sandbox-"

    public struct Entry: Identifiable, Equatable, Sendable {
        /// `sandbox-<id>`; also the key used to match a live conversation.
        public let folderName: String
        public let url: URL
        public let byteCount: Int64
        public var id: String { folderName }
    }

    public struct CleanupResult: Equatable, Sendable {
        public let removedFolders: Int
        public let freedBytes: Int64
        /// Folders left in place because their conversation is running right now.
        public let skippedRunning: Int
    }

    /// Folder name for a conversation id. Only `[A-Za-z0-9_-]` survives, so the name is
    /// always one path component inside the app's private directory.
    public static func folderName(for conversationID: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(String.UnicodeScalarView(conversationID.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        let body = cleaned.isEmpty ? "default" : String(cleaned.prefix(96))
        return prefix + body
    }

    /// UserDefaults key for the conversation's active cloned project.
    public static func activeProjectKey(for conversationID: String) -> String {
        SimpleWorkspaceToolExecutor.activeProjectKey + "." + folderName(for: conversationID)
    }

    public static func baseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IysCodeMovil", isDirectory: true)
    }

    /// Every conversation folder under `base`, with its size on disk.
    public static func list(in base: URL = baseDirectory(), fileManager: FileManager = .default) -> [Entry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().compactMap { name -> Entry? in
            guard name.hasPrefix(prefix) else { return nil }
            let url = base.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return Entry(folderName: name, url: url, byteCount: size(of: url, fileManager: fileManager))
        }
    }

    /// Folders whose conversation no longer exists.
    public static func orphans(_ entries: [Entry], liveConversationIDs: Set<String>) -> [Entry] {
        let live = Set(liveConversationIDs.map(folderName(for:)))
        return entries.filter { !live.contains($0.folderName) }
    }

    /// Deletes `entries`, except the folders of conversations in `running`. Each path is
    /// re-checked to be a `sandbox-` folder directly inside `base` before it is removed.
    public static func remove(
        _ entries: [Entry],
        keepingRunning running: Set<String>,
        in base: URL = baseDirectory(),
        fileManager: FileManager = .default
    ) -> CleanupResult {
        let runningFolders = Set(running.map(folderName(for:)))
        let basePath = base.standardizedFileURL.path
        var removed = 0
        var freed: Int64 = 0
        var skipped = 0
        for entry in entries {
            if runningFolders.contains(entry.folderName) {
                skipped += 1
                continue
            }
            let target = entry.url.standardizedFileURL
            guard entry.folderName.hasPrefix(prefix),
                  target.lastPathComponent == entry.folderName,
                  target.deletingLastPathComponent().path == basePath else { continue }
            do {
                try fileManager.removeItem(at: target)
                removed += 1
                freed += entry.byteCount
            } catch {
                continue
            }
        }
        return CleanupResult(removedFolders: removed, freedBytes: freed, skippedRunning: skipped)
    }

    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

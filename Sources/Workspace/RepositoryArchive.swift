import Foundation

/// A public GitHub repository named by the user or the model.
public struct GitHubRepositoryReference: Equatable, Sendable {
    public let owner: String
    public let name: String
    /// Branch, tag or commit; nil means the default branch.
    public let ref: String?

    /// Accepts `owner/name`, `owner/name@ref`, and github.com URLs with an optional
    /// `/tree/<ref>` suffix. Anything else is refused: the sandbox is not a general
    /// downloader.
    public static func parse(_ raw: String) -> GitHubRepositoryReference? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var ref: String?
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if let at = text.lastIndex(of: "@") {
            ref = String(text[text.index(after: at)...])
            text = String(text[..<at])
        }
        var parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4, parts[2] == "tree" {
            ref = parts[3...].joined(separator: "/")
            parts = Array(parts.prefix(2))
        }
        guard parts.count == 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard isSafe(parts[0]), isSafe(name), ref.map(isSafeRef) ?? true else { return nil }
        return GitHubRepositoryReference(owner: parts[0], name: name, ref: ref)
    }

    public var fullName: String { "\(owner)/\(name)" }

    /// Folder for the clone, relative to the workspace root.
    public var directory: String { "repos/\(owner)-\(name)" }

    /// GitHub answers this with a redirect to the archive of the ref (or default branch).
    public var tarballURL: URL? {
        var path = "https://api.github.com/repos/\(owner)/\(name)/tarball"
        if let ref, let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            path += "/" + encoded
        }
        return URL(string: path)
    }

    private static func isSafe(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 100, component != ".", component != ".." else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == ".")
        }
    }

    private static func isSafeRef(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 200, !ref.contains(".."), !ref.hasPrefix("/"), !ref.hasPrefix("-") else { return false }
        return ref.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_./".unicodeScalars.contains(scalar))
        }
    }
}

public enum RepositoryArchiveError: Error, LocalizedError, Equatable, Sendable {
    case notGzip
    case corrupt(String)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .notGzip: return "La descarga no es un archivo .tar.gz."
        case .corrupt(let detail): return "El archivo del repositorio está dañado: \(detail)"
        case .tooLarge(let detail): return "El repositorio es demasiado grande para este iPhone: \(detail)"
        }
    }
}

/// Reads the `.tar.gz` GitHub serves for a repository, without git.
///
/// Pure data in, entries out: nothing here touches the disk, so the caller decides
/// where files land and the path rules can be tested on their own.
public enum RepositoryArchive {
    public struct Entry: Equatable, Sendable {
        /// Path inside the repository, with the archive's top folder removed.
        public let path: String
        public let isDirectory: Bool
        public let data: Data
    }

    public struct Contents: Equatable, Sendable {
        public var entries: [Entry]
        /// Entries left out: links, oversized files and anything with an unsafe path.
        public var skipped: [String]
    }

    public static let maximumArchiveBytes = 40 * 1024 * 1024
    public static let maximumExpandedBytes = 200 * 1024 * 1024
    public static let maximumFileBytes = 5 * 1024 * 1024
    public static let maximumEntries = 8_000

    public static func read(gzip archive: Data) throws -> Contents {
        guard archive.count <= maximumArchiveBytes else {
            throw RepositoryArchiveError.tooLarge("la descarga supera \(maximumArchiveBytes / 1_048_576) MB")
        }
        return try read(tar: try gunzip(archive))
    }

    /// Removes the gzip wrapper and inflates the raw DEFLATE stream inside it.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw RepositoryArchiveError.notGzip
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw RepositoryArchiveError.corrupt("cabecera gzip incompleta") }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw RepositoryArchiveError.corrupt("cabecera gzip incompleta") }
        let payload = Data(bytes[offset..<(bytes.count - 8)])
        guard let inflated = try? (payload as NSData).decompressed(using: .zlib) as Data, !inflated.isEmpty else {
            throw RepositoryArchiveError.corrupt("no se pudo descomprimir")
        }
        guard inflated.count <= maximumExpandedBytes else {
            throw RepositoryArchiveError.tooLarge("ocupa más de \(maximumExpandedBytes / 1_048_576) MB al descomprimir")
        }
        return inflated
    }

    static func read(tar data: Data) throws -> Contents {
        let bytes = [UInt8](data)
        var contents = Contents(entries: [], skipped: [])
        var offset = 0
        var pendingPath: String?

        while offset + 512 <= bytes.count {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { break }
            guard let size = octal(header, at: 124, length: 12) else {
                throw RepositoryArchiveError.corrupt("tamaño ilegible en una entrada")
            }
            let bodyStart = offset + 512
            guard size >= 0, bodyStart + size <= bytes.count else {
                throw RepositoryArchiveError.corrupt("una entrada termina fuera del archivo")
            }
            let type = header[header.startIndex + 156]
            let body = bytes[bodyStart..<(bodyStart + size)]
            offset = bodyStart + (size + 511) / 512 * 512

            switch type {
            case UInt8(ascii: "g"):
                continue // global pax header: repository metadata, not a file
            case UInt8(ascii: "x"):
                pendingPath = paxPath(body)
                continue
            case UInt8(ascii: "L"):
                pendingPath = string(body)
                continue
            default:
                break
            }

            let headerName = string(header, at: 0, length: 100)
            let headerPrefix = string(header, at: 345, length: 155)
            let rawPath = pendingPath ?? (headerPrefix.isEmpty ? headerName : headerPrefix + "/" + headerName)
            pendingPath = nil

            let isDirectory = type == UInt8(ascii: "5")
            let isFile = type == UInt8(ascii: "0") || type == 0
            guard let path = repositoryPath(rawPath) else {
                // The top folder itself has no path left once it is stripped.
                if !(isDirectory && strippedIsEmpty(rawPath)) { contents.skipped.append(rawPath) }
                continue
            }
            guard isDirectory || isFile else {
                contents.skipped.append(path) // symlinks, hard links, devices
                continue
            }
            guard size <= maximumFileBytes else {
                contents.skipped.append(path)
                continue
            }
            contents.entries.append(Entry(path: path, isDirectory: isDirectory, data: isDirectory ? Data() : Data(body)))
            guard contents.entries.count <= maximumEntries else {
                throw RepositoryArchiveError.tooLarge("tiene más de \(maximumEntries) archivos")
            }
        }
        return contents
    }

    /// Drops the archive's top folder (`owner-name-sha/`) and refuses anything that
    /// could land outside the clone.
    static func repositoryPath(_ raw: String) -> String? {
        guard !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains("\0") else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    private static func strippedIsEmpty(_ raw: String) -> Bool {
        raw.split(separator: "/", omittingEmptySubsequences: true).count <= 1
    }

    private static func string(_ bytes: ArraySlice<UInt8>, at start: Int, length: Int) -> String {
        let begin = bytes.startIndex + start
        return string(bytes[begin..<(begin + length)])
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }

    private static func octal(_ bytes: ArraySlice<UInt8>, at start: Int, length: Int) -> Int? {
        let text = string(bytes, at: start, length: length).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? 0 : Int(text, radix: 8)
    }

    /// The `path=` record of a pax extended header, if it has one.
    private static func paxPath(_ body: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        for record in text.split(separator: "\n") {
            // "<length> path=<value>"
            guard let space = record.firstIndex(of: " ") else { continue }
            let field = record[record.index(after: space)...]
            if field.hasPrefix("path=") { return String(field.dropFirst(5)) }
        }
        return nil
    }
}

/// Downloads a repository archive and writes it into the workspace as a disposable clone.
public struct RepositoryCloner: Sendable {
    public struct Report: Equatable, Sendable {
        public let repository: String
        public let directory: String
        public let files: Int
        public let skipped: Int
    }

    public enum CloneError: Error, LocalizedError, Equatable, Sendable {
        case invalidReference
        case alreadyExists(String)
        case notFound(String)
        case rateLimited
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .invalidReference:
                return "Escribe el repositorio como dueño/nombre, por ejemplo octocat/Hello-World."
            case .alreadyExists(let directory):
                return "Ese repositorio ya está clonado en \(directory). Ábrelo o bórralo antes de clonarlo de nuevo."
            case .notFound(let repository):
                return "No encontré \(repository) en GitHub. Solo se pueden clonar repositorios públicos."
            case .rateLimited:
                return "GitHub limitó las descargas sin cuenta desde esta red. Inténtalo de nuevo en unos minutos."
            case .network(let detail):
                return "No se pudo descargar el repositorio: \(detail)"
            }
        }
    }

    private let fetch: @Sendable (URL) async throws -> (Data, Int)

    /// `fetch` returns the body and the HTTP status; tests replace it.
    public init(fetch: (@Sendable (URL) async throws -> (Data, Int))? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            self.fetch = { url in
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    public func clone(_ raw: String, into workspace: any Workspace) async throws -> Report {
        guard let reference = GitHubRepositoryReference.parse(raw), let url = reference.tarballURL else {
            throw CloneError.invalidReference
        }
        // Never replace a clone that may hold work: re-cloning is an explicit delete first.
        guard !(await workspace.fileExists(at: reference.directory)) else {
            throw CloneError.alreadyExists(reference.directory)
        }
        let archive: Data
        let status: Int
        do {
            (archive, status) = try await fetch(url)
        } catch {
            throw CloneError.network(error.localizedDescription)
        }
        switch status {
        case 200..<300: break
        case 404: throw CloneError.notFound(reference.fullName)
        case 403, 429: throw CloneError.rateLimited
        default: throw CloneError.network("GitHub respondió con el código \(status)")
        }

        let contents = try RepositoryArchive.read(gzip: archive)
        try await workspace.createDirectory(at: reference.directory)
        var files = 0
        for entry in contents.entries {
            let target = reference.directory + "/" + entry.path
            if entry.isDirectory {
                try await workspace.createDirectory(at: target)
            } else {
                try await workspace.writeFile(at: target, data: entry.data)
                files += 1
            }
        }
        return Report(repository: reference.fullName, directory: reference.directory, files: files, skipped: contents.skipped.count)
    }
}

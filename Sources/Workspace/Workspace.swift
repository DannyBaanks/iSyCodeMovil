import Foundation

/// Capabilities que el workspace declara explícitamente.
/// Cada capability documenta si es posible, restringida, o imposible en iOS.
public struct WorkspaceCapabilities: Codable, Sendable {
    public let listDirectory: Bool
    public let readFile: Bool
    public let writeFile: Bool
    public let createDirectory: Bool
    public let moveFile: Bool
    public let deleteFile: Bool
    public let watchChanges: Bool      // Requires DispatchSource, limited
    public let securityScopedBookmarks: Bool // Requires a user-selected document provider URL
    public let arbitraryPaths: Bool    // Sandbox restricts to app containers

    public let restrictions: [String]

    public init(
        listDirectory: Bool = true,
        readFile: Bool = true,
        writeFile: Bool = true,
        createDirectory: Bool = true,
        moveFile: Bool = true,
        deleteFile: Bool = true,
        watchChanges: Bool = false,
        securityScopedBookmarks: Bool = false,
        arbitraryPaths: Bool = false,
        restrictions: [String] = [
            "Sandbox: only App Support, Documents, tmp, and bundle (read-only)",
            "No access to system directories, other apps' data, or user home outside picker",
            "File watching limited to directories app owns"
        ]
    ) {
        self.listDirectory = listDirectory
        self.readFile = readFile
        self.writeFile = writeFile
        self.createDirectory = createDirectory
        self.moveFile = moveFile
        self.deleteFile = deleteFile
        self.watchChanges = watchChanges
        self.securityScopedBookmarks = securityScopedBookmarks
        self.arbitraryPaths = arbitraryPaths
        self.restrictions = restrictions
    }
}

/// Errores específicos del workspace
public enum WorkspaceError: Error, LocalizedError, Sendable {
    case pathNotInSandbox(String)
    case permissionDenied(String)
    case notFound(String)
    case alreadyExists(String)
    case invalidPath(String)
    case watchFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .pathNotInSandbox(let p): return "Path outside sandbox: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .notFound(let p): return "Not found: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .invalidPath(let p): return "Invalid path: \(p)"
        case .watchFailed(let p): return "Watch failed: \(p)"
        }
    }
}

/// Protocolo para abstracción de workspace.
/// Permite testing y futuras implementaciones (ej. remote workspace).
public protocol Workspace: Sendable {
    var rootURL: URL { get }
    var capabilities: WorkspaceCapabilities { get }
    
    func listDirectory(at path: String) async throws -> [FileInfo]
    func readFile(at path: String) async throws -> Data
    func writeFile(at path: String, data: Data) async throws
    func replaceText(at path: String, oldText: String, with newText: String) async throws -> Int
    func createDirectory(at path: String) async throws
    func moveFile(from: String, to: String) async throws
    func deleteFile(at path: String) async throws
    func fileExists(at path: String) async -> Bool
    func fileInfo(at path: String) async throws -> FileInfo
}

/// Información de un archivo/directorio
public struct FileInfo: Codable, Sendable, Hashable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let isReadable: Bool
    public let isWritable: Bool
}

/// Implementación nativa iOS usando FileManager
/// Respeta el sandbox: solo directorios accesibles por la app.
public actor IOSWorkspace: Workspace {
    public let rootURL: URL
    public let capabilities: WorkspaceCapabilities
    
    private let fileManager = FileManager.default
    private let securityScopeLease: SecurityScopedDirectoryLease?
    
    public init(rootName: String = "workspace") throws {
        // Directorio base en Application Support (persistente, privado a la app)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("IysCodeMovil", isDirectory: true)

        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let normalizedBase = baseDir.standardizedFileURL
        let workspaceURL = normalizedBase.appendingPathComponent(rootName, isDirectory: true).standardizedFileURL
        guard workspaceURL.deletingLastPathComponent().path == normalizedBase.path else {
            throw WorkspaceError.pathNotInSandbox("Workspace name must be a single directory name")
        }
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBase = normalizedBase.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedWorkspace.deletingLastPathComponent().path == resolvedBase.path else {
            throw WorkspaceError.pathNotInSandbox("Workspace root resolves outside Application Support")
        }
        self.rootURL = resolvedWorkspace
        self.capabilities = WorkspaceCapabilities()
        self.securityScopeLease = nil
    }

    /// Opens the exact directory the user selected in Apple's Files picker.
    /// The bookmark is an OS-issued grant, not a filesystem path supplied by a model.
    public init(securityScopedBookmark: Data) throws {
        var isStale = false
        let selectedURL = try URL(
            resolvingBookmarkData: securityScopedBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw WorkspaceError.permissionDenied("The selected folder permission expired. Choose it again in Files.")
        }
        let lease = try SecurityScopedDirectoryLease(url: selectedURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.notFound(selectedURL.lastPathComponent)
        }
        self.rootURL = selectedURL.standardizedFileURL
        self.capabilities = WorkspaceCapabilities(
            watchChanges: false,
            securityScopedBookmarks: true,
            arbitraryPaths: false,
            restrictions: [
                "Access is limited to the directory selected by the user in Files",
                "Writes and deletes are subject to the app's per-action approval flow",
                "The system can revoke this permission; reselect the folder if access expires",
                "No access to other apps' private data or the rest of the iPhone"
            ]
        )
        self.securityScopeLease = lease
    }
    
    /// Verifica que una ruta relativa está dentro de las raíces permitidas
    private func resolveAndValidate(_ relativePath: String) throws -> URL {
        let cleaned = relativePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .joined(separator: "/")
        
        // Construir la ruta desde la raíz y rechazar symlinks en cualquier
        // componente. Canonicalizar solo después de detectar enlaces evita
        // que un enlace dentro del workspace apunte a Documents/tmp u otra
        // carpeta del contenedor de la app.
        var url = rootURL
        for component in cleaned.split(separator: "/") {
            if component == ".." {
                throw WorkspaceError.pathNotInSandbox("Path traversal not allowed: \(relativePath)")
            }
            url.appendPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw WorkspaceError.pathNotInSandbox("Symbolic links are not allowed: \(relativePath)")
            }
        }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let resolvedPath = resolved.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw WorkspaceError.pathNotInSandbox("Path not in allowed roots: \(url.path)")
        }

        return url
    }

    private func coordinateRead<T>(at url: URL, _ operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WorkspaceError.permissionDenied("The Files provider did not grant read access.") }
        return try result.get()
    }

    private func coordinateWrite<T>(at url: URL, options: NSFileCoordinator.WritingOptions = .forReplacing, _ operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WorkspaceError.permissionDenied("The Files provider did not grant write access.") }
        return try result.get()
    }
    
    public func listDirectory(at path: String) async throws -> [FileInfo] {
        let url = try resolveAndValidate(path)
        return try coordinateRead(at: url) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else {
                throw WorkspaceError.notFound(path)
            }
            let contents = try fileManager.contentsOfDirectory(at: coordinatedURL, includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
            ], options: [.skipsHiddenFiles])
            return contents.map { fileURL in
                let values = try? fileURL.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
                ])
                return FileInfo(
                    path: fileURL.path.replacingOccurrences(of: coordinatedURL.path + "/", with: ""),
                    name: fileURL.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modificationDate: values?.contentModificationDate ?? Date(),
                    isReadable: values?.isReadable ?? false,
                    isWritable: values?.isWritable ?? false
                )
            }
        }
    }
    
    public func readFile(at path: String) async throws -> Data {
        let url = try resolveAndValidate(path)
        return try coordinateRead(at: url) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else {
                throw WorkspaceError.notFound(path)
            }
            guard fileManager.isReadableFile(atPath: coordinatedURL.path) else {
                throw WorkspaceError.permissionDenied(path)
            }
            return try Data(contentsOf: coordinatedURL)
        }
    }
    
    public func writeFile(at path: String, data: Data) async throws {
        let url = try resolveAndValidate(path)
        try coordinateWrite(at: rootURL, options: .forMerging) { coordinatedRoot in
            let relativePath = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let coordinatedTarget = coordinatedRoot.appendingPathComponent(relativePath)
            let parent = coordinatedTarget.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try data.write(to: coordinatedTarget, options: .atomic)
        }
    }

    /// Replaces one unique UTF-8 snippet while holding the Files-provider write
    /// coordination, so an external edit cannot be silently overwritten between
    /// the agent's read and write steps.
    public func replaceText(at path: String, oldText: String, with newText: String) async throws -> Int {
        guard !oldText.isEmpty else { throw WorkspaceError.invalidPath("old_text must not be empty") }
        let url = try resolveAndValidate(path)
        return try coordinateWrite(at: url, options: .forReplacing) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else { throw WorkspaceError.notFound(path) }
            guard fileManager.isReadableFile(atPath: coordinatedURL.path) else { throw WorkspaceError.permissionDenied(path) }
            let originalData = try Data(contentsOf: coordinatedURL)
            guard originalData.count <= 10_000_000,
                  let original = String(data: originalData, encoding: .utf8) else {
                throw WorkspaceError.invalidPath("edit_file accepts UTF-8 text files up to 10MB")
            }
            guard let match = original.range(of: oldText) else {
                throw WorkspaceError.invalidPath("old_text was not found; read the file again before editing")
            }
            guard original.range(of: oldText, range: match.upperBound..<original.endIndex) == nil else {
                throw WorkspaceError.invalidPath("old_text occurs more than once; provide a longer exact snippet so only one occurrence matches")
            }
            let edited = original.replacingCharacters(in: match, with: newText)
            let data = Data(edited.utf8)
            guard data.count <= 10_000_000 else {
                throw WorkspaceError.invalidPath("Edited file would exceed 10MB")
            }
            try data.write(to: coordinatedURL, options: .atomic)
            return data.count
        }
    }
    
    public func createDirectory(at path: String) async throws {
        let url = try resolveAndValidate(path)
        try coordinateWrite(at: rootURL, options: .forMerging) { coordinatedRoot in
            let relativePath = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try fileManager.createDirectory(at: coordinatedRoot.appendingPathComponent(relativePath), withIntermediateDirectories: true)
        }
    }
    
    public func moveFile(from: String, to: String) async throws {
        let fromURL = try resolveAndValidate(from)
        let toURL = try resolveAndValidate(to)
        guard fromURL.standardizedFileURL.path != rootURL.standardizedFileURL.path else {
            throw WorkspaceError.invalidPath("The workspace root cannot be moved")
        }
        guard fileManager.fileExists(atPath: fromURL.path) else { throw WorkspaceError.notFound(from) }
        if fileManager.fileExists(atPath: toURL.path) { throw WorkspaceError.alreadyExists(to) }
        try coordinateWrite(at: rootURL, options: .forMerging) { coordinatedRoot in
            let relativeTarget = String(toURL.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try fileManager.createDirectory(at: coordinatedRoot.appendingPathComponent(relativeTarget).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var didCoordinate = false
        coordinator.coordinate(
            writingItemAt: fromURL,
            options: .forMoving,
            writingItemAt: toURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedFrom, coordinatedTo in
            didCoordinate = true
            do { try fileManager.moveItem(at: coordinatedFrom, to: coordinatedTo) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        guard didCoordinate else { throw WorkspaceError.permissionDenied("The Files provider did not grant move access.") }
        if let operationError { throw operationError }
    }
    
    public func deleteFile(at path: String) async throws {
        let url = try resolveAndValidate(path)
        guard url.standardizedFileURL.path != rootURL.standardizedFileURL.path else {
            throw WorkspaceError.invalidPath("The workspace root cannot be deleted")
        }
        try coordinateWrite(at: url, options: .forDeleting) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else { throw WorkspaceError.notFound(path) }
            try fileManager.removeItem(at: coordinatedURL)
        }
    }
    
    public func fileExists(at path: String) async -> Bool {
        do {
            let url = try resolveAndValidate(path)
            return try coordinateRead(at: url) { fileManager.fileExists(atPath: $0.path) }
        } catch {
            return false
        }
    }
    
    public func fileInfo(at path: String) async throws -> FileInfo {
        let url = try resolveAndValidate(path)
        return try coordinateRead(at: url) { coordinatedURL in
            let values = try coordinatedURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
            ])
            return FileInfo(
                path: path,
                name: coordinatedURL.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? Date(),
                isReadable: values.isReadable ?? false,
                isWritable: values.isWritable ?? false
            )
        }
    }
}

/// Holds a Files-provider security scope for the lifetime of the native workspace.
/// The actor owns this lease and releases it when the workspace is discarded.
private final class SecurityScopedDirectoryLease: @unchecked Sendable {
    let url: URL

    init(url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.permissionDenied("iOS could not grant access to \(url.lastPathComponent). Choose the folder again in Files.")
        }
        self.url = url
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}

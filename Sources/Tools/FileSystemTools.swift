import Foundation

/// Implementación concreta de herramientas de filesystem para iOS
/// Cada herramienta declara explícitamente sus capacidades y restricciones
public actor FileSystemToolExecutor: @preconcurrency ToolExecutor {
    private let workspace: any Workspace

    static let readOutputLimit = 60_000
    public static let toolNames: Set<String> = [
        "read_file", "write_file", "list_directory", "search_files",
        "file_info", "create_directory", "delete_file", "move_file", "edit_file"
    ]
    
    public init(workspace: any Workspace) {
        self.workspace = workspace
    }
    
    public var availableTools: [AgentTool] {
        [
            readFileTool,
            writeFileTool,
            listDirectoryTool,
            searchFilesTool,
            fileInfoTool,
            createDirectoryTool,
            deleteFileTool,
            moveFileTool,
            editFileTool
        ]
    }
    
    public func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
        let startTime = Date()
        
        do {
            switch invocation.name {
            case "read_file":
                return try await executeReadFile(invocation, startTime: startTime)
            case "write_file":
                return try await executeWriteFile(invocation, startTime: startTime)
            case "list_directory":
                return try await executeListDirectory(invocation, startTime: startTime)
            case "search_files":
                return try await executeSearchFiles(invocation, startTime: startTime)
            case "file_info":
                return try await executeFileInfo(invocation, startTime: startTime)
            case "create_directory":
                return try await executeCreateDirectory(invocation, startTime: startTime)
            case "delete_file":
                return try await executeDeleteFile(invocation, startTime: startTime)
            case "move_file":
                return try await executeMoveFile(invocation, startTime: startTime)
            case "edit_file":
                return try await executeEditFile(invocation, startTime: startTime)
            default:
                return ToolExecutionResult(
                    toolCallId: invocation.id,
                    output: "",
                    error: "Unknown tool: \(invocation.name)",
                    duration: Date().timeIntervalSince(startTime)
                )
            }
        } catch {
            return ToolExecutionResult(
                toolCallId: invocation.id,
                output: "",
                error: error.localizedDescription,
                duration: Date().timeIntervalSince(startTime)
            )
        }
    }
    
    // MARK: - Tool Definitions
    
    private var readFileTool: AgentTool {
        AgentTool(
            name: "read_file",
            description: "Read the contents of a file in the workspace",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative path to the file from workspace root",
                    enumValues: nil
                ),
                "encoding": AgentTool.PropertySchema(
                    type: "string",
                    description: "Text encoding (default: utf-8)",
                    enumValues: ["utf-8", "utf-16", "ascii", "latin1"]
                )
            ],
            required: ["path"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                restrictions: ["Sandbox: only files within workspace", "Max file size: 10MB"]
            )
        )
    }
    
    private var writeFileTool: AgentTool {
        AgentTool(
            name: "write_file",
            description: "Write content to a file in the workspace (creates or overwrites)",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative path to the file from workspace root",
                    enumValues: nil
                ),
                "content": AgentTool.PropertySchema(
                    type: "string",
                    description: "Content to write",
                    enumValues: nil
                ),
                "encoding": AgentTool.PropertySchema(
                    type: "string",
                    description: "Text encoding (default: utf-8)",
                    enumValues: ["utf-8", "utf-16", "ascii", "latin1"]
                )
            ],
            required: ["path", "content"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                isDestructive: true,
                restrictions: ["Sandbox: only within workspace", "Overwrites existing files", "Max file size: 10MB"]
            )
        )
    }
    
    private var listDirectoryTool: AgentTool {
        AgentTool(
            name: "list_directory",
            description: "List files and directories in a workspace path",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative directory path (default: workspace root)",
                    enumValues: nil
                ),
                "recursive": AgentTool.PropertySchema(
                    type: "boolean",
                    description: "List recursively (default: false)",
                    enumValues: nil
                )
            ],
            required: [],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                restrictions: ["Sandbox: only within workspace", "Hidden files skipped by default"]
            )
        )
    }
    
    private var searchFilesTool: AgentTool {
        AgentTool(
            name: "search_files",
            description: "Search for files matching a pattern in the workspace",
            properties: [
                "pattern": AgentTool.PropertySchema(
                    type: "string",
                    description: "Glob pattern (e.g., *.swift, **/*.json)",
                    enumValues: nil
                ),
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Base directory to search (default: workspace root)",
                    enumValues: nil
                ),
                "content": AgentTool.PropertySchema(
                    type: "string",
                    description: "Optional text content to search within files",
                    enumValues: nil
                )
            ],
            required: ["pattern"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                restrictions: ["Sandbox: only within workspace", "No regex, glob patterns only", "Content search limited to text files < 1MB"]
            )
        )
    }
    
    private var fileInfoTool: AgentTool {
        AgentTool(
            name: "file_info",
            description: "Get metadata about a file or directory",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative path to the file or directory",
                    enumValues: nil
                )
            ],
            required: ["path"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                restrictions: ["Sandbox: only within workspace"]
            )
        )
    }
    
    private var createDirectoryTool: AgentTool {
        AgentTool(
            name: "create_directory",
            description: "Create a directory (including parent directories)",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative path of directory to create",
                    enumValues: nil
                )
            ],
            required: ["path"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                isDestructive: false,
                restrictions: ["Sandbox: only within workspace"]
            )
        )
    }
    
    private var deleteFileTool: AgentTool {
        AgentTool(
            name: "delete_file",
            description: "Delete a file or empty directory",
            properties: [
                "path": AgentTool.PropertySchema(
                    type: "string",
                    description: "Relative path to delete",
                    enumValues: nil
                ),
                "recursive": AgentTool.PropertySchema(
                    type: "boolean",
                    description: "Delete non-empty directories recursively (default: false)",
                    enumValues: nil
                )
            ],
            required: ["path"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                isDestructive: true,
                restrictions: ["Sandbox: only within workspace", "Irreversible operation", "Recursive delete can remove many files"]
            )
        )
    }
    
    private var moveFileTool: AgentTool {
        AgentTool(
            name: "move_file",
            description: "Move or rename a file or directory",
            properties: [
                "from": AgentTool.PropertySchema(
                    type: "string",
                    description: "Source relative path",
                    enumValues: nil
                ),
                "to": AgentTool.PropertySchema(
                    type: "string",
                    description: "Destination relative path",
                    enumValues: nil
                )
            ],
            required: ["from", "to"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                isDestructive: true,
                restrictions: ["Sandbox: both paths must be within workspace", "Destination must not exist"]
            )
        )
    }

    private var editFileTool: AgentTool {
        AgentTool(
            name: "edit_file",
            description: "Replace one exact text occurrence in a UTF-8 file. Fails if old_text is missing or appears more than once; use read_file first to inspect the current content.",
            properties: [
                "path": AgentTool.PropertySchema(type: "string", description: "Relative file path from workspace root", enumValues: nil),
                "old_text": AgentTool.PropertySchema(type: "string", description: "Exact text to find; must occur exactly once", enumValues: nil),
                "new_text": AgentTool.PropertySchema(type: "string", description: "Replacement text", enumValues: nil)
            ],
            required: ["path", "old_text", "new_text"],
            capabilities: AgentTool.ToolCapabilities(
                requiresFileSystem: true,
                isDestructive: true,
                approvalReason: "¿Apruebas reemplazar el texto exacto mostrado en este archivo?",
                requiresApprovalEveryTime: true,
                restrictions: ["Sandbox: only within workspace", "UTF-8 text files only", "The exact old_text must occur once"]
            )
        )
    }
    
    // MARK: - Tool Implementations
    
    private func executeReadFile(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        let encoding = invocation.arguments["encoding"] ?? "utf-8"
        
        guard !path.isEmpty else {
            throw WorkspaceError.invalidPath("path is required")
        }
        let data = try await workspace.readFile(at: path)
        
        // Check size limit (10MB)
        if data.count > 10_000_000 {
            throw WorkspaceError.invalidPath("File too large: \(data.count) bytes (max 10MB)")
        }
        
        let stringEncoding: String.Encoding
        switch encoding.lowercased() {
        case "utf-16": stringEncoding = .utf16
        case "ascii": stringEncoding = .ascii
        case "latin1": stringEncoding = .isoLatin1
        default: stringEncoding = .utf8
        }
        
        var content = String(data: data, encoding: stringEncoding) ?? "<binary data: \(data.count) bytes>"
        // The result is stored in the conversation and sent to the model; a
        // multi-megabyte file would blow any provider's token limit.
        if content.count > Self.readOutputLimit {
            content = String(content.prefix(Self.readOutputLimit))
                + "\n[truncated: the file has \(data.count) bytes; showing the first \(Self.readOutputLimit) characters]"
        }
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: content,
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeWriteFile(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        let content = invocation.arguments["content"] ?? ""
        let encoding = invocation.arguments["encoding"] ?? "utf-8"
        
        guard !path.isEmpty else {
            throw WorkspaceError.invalidPath("path is required")
        }
        
        let stringEncoding: String.Encoding
        switch encoding.lowercased() {
        case "utf-16": stringEncoding = .utf16
        case "ascii": stringEncoding = .ascii
        case "latin1": stringEncoding = .isoLatin1
        default: stringEncoding = .utf8
        }
        
        guard let data = content.data(using: stringEncoding) else {
            throw WorkspaceError.invalidPath("Failed to encode content")
        }
        
        if data.count > 10_000_000 {
            throw WorkspaceError.invalidPath("Content too large: \(data.count) bytes (max 10MB)")
        }
        
        try await workspace.writeFile(at: path, data: data)
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: "File written: \(path) (\(data.count) bytes)",
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeListDirectory(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        let recursive = (invocation.arguments["recursive"] ?? "false").lowercased() == "true"
        
        var results: [FileInfo] = []
        
        func listRecursive(_ dirPath: String, depth: Int) async throws {
            let items = try await workspace.listDirectory(at: dirPath)
            results.append(contentsOf: items)
            
            if recursive {
                for item in items where item.isDirectory {
                    let subPath = dirPath.isEmpty ? item.name : "\(dirPath)/\(item.name)"
                    try await listRecursive(subPath, depth: depth + 1)
                }
            }
        }
        
        try await listRecursive(path, depth: 0)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(results)
        let output = String(data: data, encoding: .utf8) ?? "[]"
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: output,
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeSearchFiles(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let pattern = invocation.arguments["pattern"] ?? ""
        let basePath = invocation.arguments["path"] ?? ""
        let contentQuery = invocation.arguments["content"]
        
        guard !pattern.isEmpty else {
            throw WorkspaceError.invalidPath("pattern is required")
        }
        
        var matches: [FileInfo] = []
        
        func searchRecursive(_ dirPath: String) async throws {
            let items = try await workspace.listDirectory(at: dirPath)
            
            for item in items {
                let relativePath = dirPath.isEmpty ? item.name : "\(dirPath)/\(item.name)"
                
                // Match filename against glob pattern
                if GlobMatcher.match(pattern, relativePath) {
                    matches.append(item)
                }
                
                // Content search
                if let contentQuery = contentQuery, !item.isDirectory {
                    if let fileContent = try? await workspace.readFile(at: relativePath),
                       let text = String(data: fileContent, encoding: .utf8),
                       text.localizedCaseInsensitiveContains(contentQuery) {
                        if !matches.contains(where: { $0.path == item.path }) {
                            matches.append(item)
                        }
                    }
                }
                
                if item.isDirectory {
                    try await searchRecursive(relativePath)
                }
            }
        }
        
        try await searchRecursive(basePath)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(matches)
        let output = String(data: data, encoding: .utf8) ?? "[]"
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: output,
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeFileInfo(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        
        guard !path.isEmpty else {
            throw WorkspaceError.invalidPath("path is required")
        }
        
        let info = try await workspace.fileInfo(at: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(info)
        let output = String(data: data, encoding: .utf8) ?? "{}"
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: output,
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeCreateDirectory(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        
        guard !path.isEmpty else {
            throw WorkspaceError.invalidPath("path is required")
        }
        
        try await workspace.createDirectory(at: path)
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: "Directory created: \(path)",
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    private func executeDeleteFile(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        let recursive = (invocation.arguments["recursive"] ?? "false").lowercased() == "true"
        
        guard !path.isEmpty else {
            throw WorkspaceError.invalidPath("path is required")
        }
        guard !isWorkspaceRootPath(path) else {
            throw WorkspaceError.invalidPath("The workspace root cannot be deleted")
        }
        
        if recursive {
            // Truly recursive delete: delete all contents first (depth-first)
            try await deleteRecursive(at: path)
        }
        
        try await workspace.deleteFile(at: path)
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: "Deleted: \(path)\(recursive ? " (recursive)" : "")",
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }
    
    /// Recursively deletes a directory and all its contents
    private func deleteRecursive(at path: String) async throws {
        let items = try await workspace.listDirectory(at: path)
        for item in items {
            let itemPath = path.isEmpty ? item.name : "\(path)/\(item.name)"
            if item.isDirectory {
                // Recursively delete subdirectory contents first
                try await deleteRecursive(at: itemPath)
            }
            // Delete the item itself (file or now-empty directory)
            try await workspace.deleteFile(at: itemPath)
        }
    }
    
    private func executeMoveFile(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let from = invocation.arguments["from"] ?? ""
        let to = invocation.arguments["to"] ?? ""
        
        guard !from.isEmpty, !to.isEmpty else {
            throw WorkspaceError.invalidPath("from and to are required")
        }
        
        try await workspace.moveFile(from: from, to: to)
        
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: "Moved: \(from) → \(to)",
            error: nil,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    private func executeEditFile(_ invocation: ToolInvocation, startTime: Date) async throws -> ToolExecutionResult {
        let path = invocation.arguments["path"] ?? ""
        let oldText = invocation.arguments["old_text"] ?? ""
        let newText = invocation.arguments["new_text"] ?? ""
        guard !path.isEmpty else { throw WorkspaceError.invalidPath("path is required") }
        let byteCount = try await workspace.replaceText(at: path, oldText: oldText, with: newText)
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: "Edited exactly one occurrence in \(path) (\(byteCount) bytes)",
            duration: Date().timeIntervalSince(startTime)
        )
    }

    private func isWorkspaceRootPath(_ path: String) -> Bool {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .allSatisfy { $0 == "." }
    }
    
    // MARK: - Glob matching (delegado a GlobMatcher público para testabilidad)
}

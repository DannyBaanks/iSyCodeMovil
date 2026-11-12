import Foundation

/// A small tool surface a weak on-device model can actually drive.
///
/// The full miniagent catalog has fourteen tools with up to four arguments each; a
/// 0.5B model loses the thread long before it picks the right one. This surface has
/// seven tools with at most three flat string arguments, answers in short Spanish text
/// that says what to do next, and forgives the mistakes small models make most
/// (whitespace and indentation in `edit`).
///
/// Scope and approval follow one rule:
/// - With an **active project** (a repository cloned under `repos/`), every path is
///   relative to that clone. It is a disposable copy, so edits apply without asking and
///   each one can be reverted with `undo`.
/// - Without one, paths are relative to the workspace root (the app's private space or
///   the folder the user picked in Files) and every change still needs approval.
public actor SimpleWorkspaceToolExecutor {
    public static let toolNames: Set<String> = ["clone", "list", "read", "find", "edit", "write", "undo"]
    public static let activeProjectKey = "sandbox.activeProject"

    static let readWindow = 80
    static let maximumLineCharacters = 300
    static let maximumMatches = 30
    static let maximumListEntries = 200
    static let maximumUndoSteps = 50
    private static let maximumTextBytes = 1_000_000
    private static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "Pods", "DerivedData"]

    private struct Checkpoint {
        let path: String
        /// nil when the file did not exist before the change.
        let previous: Data?
    }

    private let workspace: any Workspace
    private let defaults: UserDefaults
    private let cloner: RepositoryCloner
    private var undoStack: [Checkpoint] = []

    public init(workspace: any Workspace, defaults: UserDefaults = .standard, cloner: RepositoryCloner = RepositoryCloner()) {
        self.workspace = workspace
        self.defaults = defaults
        self.cloner = cloner
    }

    // MARK: - Active project

    /// The cloned repository the tools are scoped to, if it still exists.
    public func activeProject() async -> String? {
        guard let stored = defaults.string(forKey: Self.activeProjectKey), !stored.isEmpty else { return nil }
        guard await workspace.fileExists(at: stored) else {
            defaults.removeObject(forKey: Self.activeProjectKey)
            return nil
        }
        return stored
    }

    public func setActiveProject(_ directory: String?) {
        if let directory, !directory.isEmpty {
            defaults.set(directory, forKey: Self.activeProjectKey)
        } else {
            defaults.removeObject(forKey: Self.activeProjectKey)
        }
        undoStack.removeAll()
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// One line for the prompt so the model knows where it is working.
    public func projectNote() async -> String? {
        guard let project = await activeProject() else { return nil }
        return """
        PROYECTO ACTIVO: \(project) (copia desechable de un repositorio). Las rutas de las herramientas son relativas a esa carpeta. \
        En este proyecto edit y write se aplican sin pedir aprobación y se revierten con undo.
        """
    }

    // MARK: - Tool catalog

    public func tools() async -> [AgentTool] {
        let project = await activeProject()
        return Self.tools(disposable: project != nil)
    }

    static func tools(disposable: Bool) -> [AgentTool] {
        let readOnly = AgentTool.ToolCapabilities(requiresFileSystem: true)
        func change(_ reason: String) -> AgentTool.ToolCapabilities {
            if disposable { return AgentTool.ToolCapabilities(requiresFileSystem: true) }
            return AgentTool.ToolCapabilities(requiresFileSystem: true, isDestructive: true,
                                              approvalReason: reason, requiresApprovalEveryTime: true)
        }
        return [
            cloneTool,
            AgentTool(name: "list", description: "Lista los archivos y carpetas de una carpeta.", properties: [
                "path": .init(type: "string", description: "Carpeta. Vacío = raíz.")
            ], capabilities: readOnly),
            AgentTool(name: "read", description: "Lee un archivo de texto con sus números de línea, en tramos de \(readWindow) líneas.", properties: [
                "path": .init(type: "string", description: "Archivo."),
                "from_line": .init(type: "integer", description: "Primera línea a mostrar. Por defecto 1.")
            ], required: ["path"], capabilities: readOnly),
            AgentTool(name: "find", description: "Busca un texto en todos los archivos y devuelve archivo, línea y contenido.", properties: [
                "text": .init(type: "string", description: "Texto a buscar.")
            ], required: ["text"], capabilities: readOnly),
            AgentTool(name: "edit", description: "Cambia un fragmento de un archivo: old_text por new_text. Copia old_text tal como aparece en read, sin los números de línea.", properties: [
                "path": .init(type: "string", description: "Archivo."),
                "old_text": .init(type: "string", description: "Texto actual que se va a reemplazar."),
                "new_text": .init(type: "string", description: "Texto nuevo.")
            ], required: ["path", "old_text", "new_text"], capabilities: change("¿Aplicar este cambio al archivo?")),
            AgentTool(name: "write", description: "Crea un archivo nuevo o reemplaza uno completo.", properties: [
                "path": .init(type: "string", description: "Archivo."),
                "content": .init(type: "string", description: "Contenido completo.")
            ], required: ["path", "content"], capabilities: change("¿Escribir este archivo con el contenido mostrado?")),
            AgentTool(name: "undo", description: "Deshace el último edit o write.", properties: [:],
                      capabilities: change("¿Deshacer el último cambio?"))
        ]
    }

    /// Also offered to cloud models next to the full catalog.
    static let cloneTool = AgentTool(
        name: "clone",
        description: "Descarga un repositorio público de GitHub en una carpeta desechable del iPhone.",
        properties: ["repo": .init(type: "string", description: "dueño/nombre, por ejemplo octocat/Hello-World.")],
        required: ["repo"],
        capabilities: .init(requiresNetwork: true, requiresFileSystem: true)
    )

    // MARK: - Execution

    /// `scopeToProject` is false for models that use the full catalog, whose paths are
    /// always relative to the workspace root.
    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?, scopeToProject: Bool = true) async -> ToolExecutionResult {
        let started = Date()
        func result(_ output: String, error: String? = nil) -> ToolExecutionResult {
            ToolExecutionResult(toolCallId: invocation.id, output: output, error: error, duration: Date().timeIntervalSince(started))
        }
        do {
            let project = scopeToProject ? await activeProject() : nil
            let isChange = ["edit", "write", "undo"].contains(invocation.name)
            if isChange, project == nil, approval != .allowOnce, approval != .allowAlways {
                return result("", error: "Este cambio necesita tu aprobación.")
            }
            switch invocation.name {
            case "clone":
                return result(try await clone(invocation.arguments["repo"] ?? "", scopeToProject: scopeToProject))
            case "list":
                return result(try await list(invocation.arguments["path"] ?? "", project: project))
            case "read":
                let from = Int(invocation.arguments["from_line"] ?? "") ?? 1
                return result(try await read(try required(invocation, "path"), fromLine: from, project: project))
            case "find":
                return result(try await find(try required(invocation, "text"), project: project))
            case "edit":
                return result(try await edit(
                    try required(invocation, "path"),
                    oldText: try required(invocation, "old_text"),
                    newText: invocation.arguments["new_text"] ?? "",
                    project: project
                ))
            case "write":
                return result(try await write(try required(invocation, "path"), content: invocation.arguments["content"] ?? "", project: project))
            case "undo":
                return result(try await undoLastChange())
            default:
                return result("", error: "No existe la herramienta \(invocation.name).")
            }
        } catch {
            return result("", error: error.localizedDescription)
        }
    }

    /// Clones and makes the repository the active project. Used by the tool and the UI.
    @discardableResult
    public func cloneRepository(_ raw: String) async throws -> RepositoryCloner.Report {
        let report = try await cloner.clone(raw, into: workspace)
        setActiveProject(report.directory)
        return report
    }

    /// Reverts the most recent `edit` or `write`.
    @discardableResult
    public func undoLastChange() async throws -> String {
        guard let checkpoint = undoStack.popLast() else {
            throw SimpleToolError("No hay ningún cambio que deshacer.")
        }
        if let previous = checkpoint.previous {
            try await workspace.writeFile(at: checkpoint.path, data: previous)
            return "Deshecho: \(checkpoint.path) volvió a su contenido anterior."
        }
        try await workspace.deleteFile(at: checkpoint.path)
        return "Deshecho: se eliminó \(checkpoint.path), que no existía antes."
    }

    // MARK: - Tools

    private func clone(_ raw: String, scopeToProject: Bool) async throws -> String {
        let report = try await cloneRepository(raw)
        let top = try await list("", project: scopeToProject ? report.directory : nil, base: scopeToProject ? "" : report.directory)
        let skipped = report.skipped > 0 ? " Se omitieron \(report.skipped) entradas (enlaces o archivos muy grandes)." : ""
        let scope = scopeToProject
            ? "Desde ahora las rutas son relativas a ese proyecto."
            : "Los archivos están en \(report.directory)/ dentro del workspace."
        return "Clonado \(report.repository): \(report.files) archivos.\(skipped) \(scope)\n\(top)"
    }

    private func list(_ path: String, project: String?, base: String = "") async throws -> String {
        let relative = try Self.cleanPath(base.isEmpty ? path : (path.isEmpty ? base : base + "/" + path), allowEmpty: true)
        let entries = try await workspace.listDirectory(at: Self.join(project, relative))
        let sorted = entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !sorted.isEmpty else { return "\(relative.isEmpty ? "La raíz" : relative) está vacía." }
        var lines = sorted.prefix(Self.maximumListEntries).map { $0.isDirectory ? "\($0.name)/" : $0.name }
        if sorted.count > Self.maximumListEntries {
            lines.append("[\(sorted.count - Self.maximumListEntries) entradas más]")
        }
        return "Contenido de \(relative.isEmpty ? "la raíz" : relative):\n" + lines.joined(separator: "\n")
    }

    private func read(_ path: String, fromLine: Int, project: String?) async throws -> String {
        let relative = try Self.cleanPath(path)
        let text = try await readText(Self.join(project, relative))
        return Self.numberedWindow(of: text, fromLine: fromLine, path: relative)
    }

    private func find(_ query: String, project: String?) async throws -> String {
        var matches: [String] = []
        var truncated = false

        func walk(_ directory: String) async throws {
            for item in try await workspace.listDirectory(at: Self.join(project, directory)) {
                guard matches.count < Self.maximumMatches else { truncated = true; return }
                let relative = directory.isEmpty ? item.name : directory + "/" + item.name
                if item.isDirectory {
                    if !Self.skippedDirectories.contains(item.name) { try await walk(relative) }
                    continue
                }
                guard item.size <= Int64(Self.maximumTextBytes),
                      let data = try? await workspace.readFile(at: Self.join(project, relative)),
                      let text = String(data: data, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                    guard matches.count < Self.maximumMatches else { truncated = true; return }
                    matches.append("\(relative):\(index + 1): \(String(line.trimmingCharacters(in: .whitespaces).prefix(160)))")
                }
            }
        }

        try await walk("")
        guard !matches.isEmpty else { return "No encontré «\(query)» en ningún archivo." }
        return matches.joined(separator: "\n") + (truncated ? "\n[hay más coincidencias; busca algo más específico]" : "")
    }

    private func edit(_ path: String, oldText: String, newText: String, project: String?) async throws -> String {
        let relative = try Self.cleanPath(path)
        let full = Self.join(project, relative)
        let original = try await readText(full)
        let outcome = try Self.applyEdit(to: original, oldText: oldText, newText: newText, path: relative)
        try await save(outcome.text, to: full, previous: Data(original.utf8))
        let tolerance = outcome.wasTolerant ? " Se ignoraron diferencias de espacios." : ""
        return "Editado \(relative) (línea \(outcome.firstLine)).\(tolerance) Para revertirlo usa undo."
    }

    private func write(_ path: String, content: String, project: String?) async throws -> String {
        let relative = try Self.cleanPath(path)
        let full = Self.join(project, relative)
        var previous: Data?
        if await workspace.fileExists(at: full) {
            previous = try await workspace.readFile(at: full)
        }
        try await save(content, to: full, previous: previous)
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        return "\(previous == nil ? "Creado" : "Reemplazado") \(relative) (\(lines) líneas). Para revertirlo usa undo."
    }

    private func save(_ text: String, to path: String, previous: Data?) async throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumTextBytes else { throw SimpleToolError("El contenido es demasiado grande (máximo 1 MB).") }
        try await workspace.writeFile(at: path, data: data)
        undoStack.append(Checkpoint(path: path, previous: previous))
        if undoStack.count > Self.maximumUndoSteps { undoStack.removeFirst() }
    }

    private func readText(_ path: String) async throws -> String {
        let data = try await workspace.readFile(at: path)
        guard data.count <= Self.maximumTextBytes else { throw SimpleToolError("El archivo es demasiado grande para leerlo (más de 1 MB).") }
        guard let text = String(data: data, encoding: .utf8) else { throw SimpleToolError("Ese archivo no es texto.") }
        return text
    }

    private func required(_ invocation: ToolInvocation, _ key: String) throws -> String {
        guard let value = invocation.arguments[key], !value.isEmpty else { throw SimpleToolError("Falta el argumento \(key).") }
        return value
    }

    // MARK: - Pure helpers (covered by tests)

    /// Normalises a model-supplied path and refuses anything that could leave the scope.
    static func cleanPath(_ raw: String, allowEmpty: Bool = false) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("\\") else {
            throw SimpleToolError("Usa una ruta relativa al proyecto, por ejemplo src/app.js.")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.contains("..") else { throw SimpleToolError("La ruta no puede salir del proyecto.") }
        guard allowEmpty || !parts.isEmpty else { throw SimpleToolError("Falta la ruta del archivo.") }
        return parts.joined(separator: "/")
    }

    static func join(_ project: String?, _ relative: String) -> String {
        guard let project, !project.isEmpty else { return relative }
        return relative.isEmpty ? project : project + "/" + relative
    }

    static func numberedWindow(of text: String, fromLine: Int, path: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        guard !text.isEmpty, !lines.isEmpty else { return "\(path) está vacío." }
        let first = min(max(fromLine, 1), lines.count)
        let last = min(first + readWindow - 1, lines.count)
        let body = (first...last).map { number -> String in
            let line = lines[number - 1]
            let shown = line.count > maximumLineCharacters ? String(line.prefix(maximumLineCharacters)) + "…" : line
            return "\(number): \(shown)"
        }.joined(separator: "\n")
        let footer = last < lines.count
            ? "\n[líneas \(first)-\(last) de \(lines.count). Para seguir usa read con from_line=\(last + 1)]"
            : "\n[líneas \(first)-\(last) de \(lines.count). Fin del archivo]"
        return body + footer
    }

    struct EditOutcome: Equatable {
        let text: String
        /// 1-based line where the replacement starts.
        let firstLine: Int
        let wasTolerant: Bool
    }

    /// Replaces `oldText` with `newText`.
    ///
    /// An exact, unique match wins. Otherwise lines are compared ignoring leading and
    /// trailing whitespace, which is where small models drift (tabs for spaces, a lost
    /// indent, a trailing blank). The tolerant match must also be unique, and the
    /// replacement is shifted to the indentation of the line it replaces when the
    /// model wrote it starting at column zero.
    static func applyEdit(to original: String, oldText: String, newText: String, path: String) throws -> EditOutcome {
        let exact = original.components(separatedBy: oldText).count - 1
        if exact == 1, let range = original.range(of: oldText) {
            let line = original[..<range.lowerBound].components(separatedBy: "\n").count
            return EditOutcome(text: original.replacingCharacters(in: range, with: newText), firstLine: line, wasTolerant: false)
        }
        if exact > 1 {
            throw SimpleToolError("Ese texto aparece \(exact) veces en \(path). Incluye en old_text una línea más de contexto para que sea único.")
        }

        var fileLines = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline { fileLines.removeLast() }
        let wanted = trimmedBlock(oldText)
        guard !wanted.isEmpty, wanted.count <= fileLines.count else {
            throw SimpleToolError(notFoundMessage(wanted.first, in: fileLines, path: path))
        }
        let normalized = fileLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let starts = (0...(fileLines.count - wanted.count)).filter { start in
            Array(normalized[start..<(start + wanted.count)]) == wanted
        }
        guard let start = starts.first else {
            throw SimpleToolError(notFoundMessage(wanted.first, in: fileLines, path: path))
        }
        guard starts.count == 1 else {
            let places = starts.prefix(5).map { String($0 + 1) }.joined(separator: ", ")
            throw SimpleToolError("Ese texto aparece \(starts.count) veces en \(path) (líneas \(places)). Incluye una línea más de contexto.")
        }

        var replacement = newText.components(separatedBy: "\n")
        if newText.hasSuffix("\n") { replacement.removeLast() }
        let indent = String(fileLines[start].prefix { $0 == " " || $0 == "\t" })
        // A model usually writes its block starting at column zero. Shifting the whole
        // block by the replaced line's indent keeps its own relative indentation.
        let firstWritten = replacement.first { !$0.isEmpty } ?? ""
        let startsAtColumnZero = !firstWritten.hasPrefix(" ") && !firstWritten.hasPrefix("\t")
        if !indent.isEmpty, startsAtColumnZero {
            replacement = replacement.map { $0.isEmpty ? $0 : indent + $0 }
        }
        if newText.isEmpty { replacement = [] }
        fileLines.replaceSubrange(start..<(start + wanted.count), with: replacement)
        return EditOutcome(
            text: fileLines.joined(separator: "\n") + (trailingNewline ? "\n" : ""),
            firstLine: start + 1,
            wasTolerant: true
        )
    }

    /// Lines of `text`, each trimmed, without blank lines at either end.
    private static func trimmedBlock(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// An error that tells the model what to do next instead of only that it failed.
    private static func notFoundMessage(_ firstWanted: String?, in fileLines: [String], path: String) -> String {
        var message = "No encontré ese texto en \(path). Usa read para ver el archivo y copia el fragmento tal como aparece."
        if let firstWanted, firstWanted.count >= 4,
           let near = fileLines.firstIndex(where: { $0.localizedCaseInsensitiveContains(firstWanted) }) {
            message += " Algo parecido está en la línea \(near + 1)."
        }
        return message
    }
}

struct SimpleToolError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

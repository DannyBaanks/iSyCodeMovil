import Foundation

/// Persisted L1 (agent-authored) composite tool built on top of L0 native primitives.
public struct L1ToolDefinition: Codable, Sendable, Equatable {
    public struct Parameter: Codable, Sendable, Equatable {
        public let name: String
        public let type: String
        public let description: String
        public let required: Bool?

        public init(name: String, type: String = "string", description: String, required: Bool? = true) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public let tool: String
        public let args: [String: String]

        public init(tool: String, args: [String: String]) {
            self.tool = tool
            self.args = args
        }
    }

    public let name: String
    public let description: String
    public let parameters: [Parameter]
    public let steps: [Step]
}

/// Manages L1 tools created by the model inside the iPhone sandbox (`l1_tools.json`).
public actor DynamicToolRegistry {
    public static let metaToolNames: Set<String> = [
        "l1_create_tool",
        "l1_list_tools",
        "l1_delete_tool"
    ]

    public static let metaTools: [AgentTool] = [
        AgentTool(
            name: "l1_create_tool",
            description: "Crea o actualiza una herramienta L1 reutilizable compuesta por pasos de herramientas L0 del iPhone/sandbox (archivos, http_request, browser_*, iphone_*, shortcuts.run).",
            properties: [
                "name": .init(type: "string", description: "Nombre snake_case de la nueva tool L1 (ej. l1_estado_wda_y_pantalla)."),
                "description": .init(type: "string", description: "Qué hace la herramienta y cuándo usarla."),
                "parameters_json": .init(type: "string", description: "JSON array opcional de parámetros: [{\"name\":\"url\",\"type\":\"string\",\"description\":\"...\",\"required\":true}]."),
                "steps_json": .init(type: "string", description: "JSON array de pasos L0: [{\"tool\":\"iphone_launch_app\",\"args\":{\"app\":\"{{bundle_id}}\"}}]. Soporta {{param}} y {{prev_output}}.")
            ],
            required: ["name", "description", "steps_json"],
            capabilities: .init(requiresFileSystem: true)
        ),
        AgentTool(
            name: "l1_list_tools",
            description: "Lista todas las herramientas L1 creadas por el agente en este iPhone.",
            properties: [:],
            capabilities: .init(requiresFileSystem: true)
        ),
        AgentTool(
            name: "l1_delete_tool",
            description: "Elimina una herramienta L1 por nombre.",
            properties: [
                "name": .init(type: "string", description: "Nombre de la tool L1 a eliminar.")
            ],
            required: ["name"],
            capabilities: .init(requiresFileSystem: true)
        )
    ]

    private let storageURL: URL
    private var cached: [L1ToolDefinition]

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = docs.appendingPathComponent(".isycode/l1_tools.json")
        }
        self.cached = Self.load(from: self.storageURL)
    }

    public func allAgentTools() -> [AgentTool] {
        cached.map { def in
            var props: [String: AgentTool.PropertySchema] = [:]
            var req: [String] = []
            for p in def.parameters {
                props[p.name] = .init(type: p.type, description: p.description)
                if p.required ?? true {
                    req.append(p.name)
                }
            }
            return AgentTool(
                name: def.name,
                description: "[L1] \(def.description)",
                properties: props,
                required: req,
                capabilities: .init(requiresNetwork: true, requiresFileSystem: true)
            )
        }
    }

    public func definition(named name: String) -> L1ToolDefinition? {
        cached.first { $0.name == name }
    }

    public func createTool(arguments: [String: String]) throws -> String {
        guard let rawName = arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            throw NSError(domain: "L1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta el parámetro 'name'."])
        }
        let validName = rawName.range(of: "^[a-zA-Z][a-zA-Z0-9_]{1,63}$", options: .regularExpression) != nil
        guard validName, !Self.metaToolNames.contains(rawName) else {
            throw NSError(domain: "L1", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nombre inválido para tool L1: usa letras, números y guion bajo."])
        }
        guard let description = arguments["description"]?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            throw NSError(domain: "L1", code: 3, userInfo: [NSLocalizedDescriptionKey: "Falta el parámetro 'description'."])
        }
        guard let stepsJSON = arguments["steps_json"],
              let stepsData = stepsJSON.data(using: .utf8) else {
            throw NSError(domain: "L1", code: 4, userInfo: [NSLocalizedDescriptionKey: "Falta 'steps_json'."])
        }
        let steps = try JSONDecoder().decode([L1ToolDefinition.Step].self, from: stepsData)
        guard !steps.isEmpty, steps.count <= 12 else {
            throw NSError(domain: "L1", code: 5, userInfo: [NSLocalizedDescriptionKey: "'steps_json' debe tener entre 1 y 12 pasos."])
        }
        var params: [L1ToolDefinition.Parameter] = []
        if let paramsJSON = arguments["parameters_json"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !paramsJSON.isEmpty,
           let paramsData = paramsJSON.data(using: .utf8) {
            params = try JSONDecoder().decode([L1ToolDefinition.Parameter].self, from: paramsData)
        }

        let def = L1ToolDefinition(name: rawName, description: description, parameters: params, steps: steps)
        if let idx = cached.firstIndex(where: { $0.name == rawName }) {
            cached[idx] = def
        } else {
            cached.append(def)
        }
        try save()
        return "Tool L1 '\(rawName)' guardada con \(steps.count) paso(s) en \(storageURL.lastPathComponent). Ya puedes invocarla directamente."
    }

    public func listToolsText() -> String {
        guard !cached.isEmpty else {
            return "No hay tools L1 creadas todavía. Usa l1_create_tool para crear una sobre las primitivas L0."
        }
        return cached.map { def in
            let stepList = def.steps.map(\.tool).joined(separator: " -> ")
            return "• \(def.name): \(def.description) [pasos: \(stepList)]"
        }.joined(separator: "\n")
    }

    public func deleteTool(named name: String) throws -> String {
        let before = cached.count
        cached.removeAll { $0.name == name }
        guard cached.count < before else {
            return "No existe la tool L1 '\(name)'."
        }
        try save()
        return "Tool L1 '\(name)' eliminada."
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func load(from url: URL) -> [L1ToolDefinition] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([L1ToolDefinition].self, from: data) else {
            return []
        }
        return decoded
    }
}

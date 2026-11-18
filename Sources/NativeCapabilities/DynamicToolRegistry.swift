import Foundation

/// Persisted L1 (agent- or user-authored) composite tool built on top of L0 primitives.
/// Stores stable identity, input/output schema, steps, inherited permissions, restrictions,
/// tests, version, and provenance (Section 8).
public struct L1ToolDefinition: Codable, Sendable, Equatable, Identifiable {
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

    public struct TestSpec: Codable, Sendable, Equatable {
        public var sampleArguments: [String: String]
        public var expectedSubstring: String?
        public var lastVerifiedAt: Date?
        public var lastPassed: Bool?

        public init(
            sampleArguments: [String: String] = [:],
            expectedSubstring: String? = nil,
            lastVerifiedAt: Date? = nil,
            lastPassed: Bool? = nil
        ) {
            self.sampleArguments = sampleArguments
            self.expectedSubstring = expectedSubstring
            self.lastVerifiedAt = lastVerifiedAt
            self.lastPassed = lastPassed
        }
    }

    public let id: String
    public let name: String
    public let description: String
    public let parameters: [Parameter]
    public let outputSchema: String
    public let steps: [Step]
    public let requiredPermissions: [String]
    public let restrictions: [String]
    public let requiredSecrets: [String]
    public let workflowSummary: String?
    public var testSpec: TestSpec?
    public let version: String
    public let provenance: String

    public static let provenanceLearned = "learned_demonstration"

    public init(
        id: String? = nil,
        name: String,
        description: String,
        parameters: [Parameter] = [],
        outputSchema: String = "string (salida estructurada del último paso)",
        steps: [Step],
        requiredPermissions: [String]? = nil,
        restrictions: [String] = ["Solo ejecuta primitivas L0 autorizadas; sin escalación de permisos."],
        requiredSecrets: [String]? = nil,
        workflowSummary: String? = nil,
        testSpec: TestSpec? = nil,
        version: String = "1.0.0",
        provenance: String = "agent"
    ) {
        self.id = id ?? "l1.\(name)"
        self.name = name
        self.description = description
        self.parameters = parameters
        self.outputSchema = outputSchema
        self.steps = steps
        self.requiredPermissions = requiredPermissions ?? Self.inferPermissionLabels(from: steps)
        self.restrictions = restrictions
        self.requiredSecrets = requiredSecrets ?? Self.inferSecretAliases(from: steps)
        self.workflowSummary = workflowSummary
        self.testSpec = testSpec
        self.version = version
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, parameters, outputSchema, steps, requiredPermissions, restrictions, requiredSecrets, workflowSummary, testSpec, version, provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try c.decode(String.self, forKey: .name)
        let decodedSteps = try c.decode([Step].self, forKey: .steps)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? "l1.\(decodedName)"
        self.name = decodedName
        self.description = try c.decode(String.self, forKey: .description)
        self.parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        self.outputSchema = try c.decodeIfPresent(String.self, forKey: .outputSchema) ?? "string (salida estructurada)"
        self.steps = decodedSteps
        self.requiredPermissions = try c.decodeIfPresent([String].self, forKey: .requiredPermissions)
            ?? Self.inferPermissionLabels(from: decodedSteps)
        self.restrictions = try c.decodeIfPresent([String].self, forKey: .restrictions)
            ?? ["Solo ejecuta primitivas L0 autorizadas; sin escalación de permisos."]
        self.requiredSecrets = try c.decodeIfPresent([String].self, forKey: .requiredSecrets)
            ?? Self.inferSecretAliases(from: decodedSteps)
        self.workflowSummary = try c.decodeIfPresent(String.self, forKey: .workflowSummary)
        self.testSpec = try c.decodeIfPresent(TestSpec.self, forKey: .testSpec)
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        self.provenance = try c.decodeIfPresent(String.self, forKey: .provenance) ?? "agent"
    }

    public static func inferSecretAliases(from steps: [Step]) -> [String] {
        var aliases: [String] = []
        var seen: Set<String> = []
        for step in steps {
            for val in step.args.values {
                for alias in SecretVaultStore.extractAliases(in: val) where seen.insert(alias).inserted {
                    aliases.append(alias)
                }
            }
        }
        return aliases
    }

    public static func inferPermissionLabels(from steps: [Step]) -> [String] {
        var labels: [String] = []
        for step in steps {
            let t = step.tool.lowercased()
            if t == "read_file" || t == "read" || t == "list_directory" || t == "list" || t == "search_files" || t == "search_text" {
                if !labels.contains("Lectura de archivos del workspace") { labels.append("Lectura de archivos del workspace") }
            }
            if t == "write_file" || t == "write" || t == "edit_file" || t == "edit" || t == "delete_file" || t == "move_file" {
                if !labels.contains("Escritura en archivos (con confirmación)") { labels.append("Escritura en archivos (con confirmación)") }
            }
            if t == "python_eval" {
                if !labels.contains("Procesamiento local Python (pocketpy sin OS)") { labels.append("Procesamiento local Python (pocketpy sin OS)") }
            }
            if t == "http_request" || t.hasPrefix("browser_") {
                if !labels.contains("Acceso a red / web") { labels.append("Acceso a red / web") }
            }
            if t.hasPrefix("iphone_") {
                if !labels.contains("Control visual del iPhone (WDA)") { labels.append("Control visual del iPhone (WDA)") }
            }
            if t.hasPrefix("gmail.") || t.hasPrefix("google") {
                if !labels.contains("Servicios autorizados de Google") { labels.append("Servicios autorizados de Google") }
            }
            if t.hasPrefix("isymcp_") {
                if !labels.contains("Puente remoto ISyMCP (PC)") { labels.append("Puente remoto ISyMCP (PC)") }
            }
        }
        return labels
    }

    /// Canonical example L1 tool from Section 8: reads or receives CSV product data,
    /// validates prices & structure with embedded Python, and writes `catalogo_productos.json`.
    public static let sampleCatalogImporter = L1ToolDefinition(
        id: "l1.importar_catalogo_csv",
        name: "importar_catalogo_csv",
        description: "Importa un CSV de productos (nombre, precio, stock), valida precios con Python local y guarda catalogo_productos.json en el workspace.",
        parameters: [
            .init(name: "csv_content", type: "string", description: "Texto CSV con columnas sku,nombre,precio,stock", required: true),
            .init(name: "output_path", type: "string", description: "Archivo destino en el workspace (ej. catalogo_productos.json)", required: true)
        ],
        outputSchema: "JSON con resumen de productos válidos, alertas de precio y ruta guardada",
        steps: [
            .init(
                tool: "python_eval",
                args: [
                    "input_text": "{{csv_content}}",
                    "script": """
                    rows = csv.parse(INPUT_TEXT)
                    validos = []
                    alertas = []
                    for r in rows:
                        nombre = r.get('nombre', r.get('producto', 'Sin nombre'))
                        try:
                            precio = float(r.get('precio', '0').replace('$', '').strip())
                        except Exception:
                            precio = -1.0
                        if precio > 0:
                            validos.append({'sku': r.get('sku', 'N/A'), 'nombre': nombre, 'precio': precio, 'stock': r.get('stock', '1')})
                        else:
                            alertas.append(nombre)
                    total = sum([item['precio'] for item in validos])
                    catalogo = {'productos_validos': len(validos), 'alertas_precio': alertas, 'suma_precios': round(total, 2), 'catalogo': validos}
                    print(json.dumps(catalogo))
                    """
                ]
            ),
            .init(
                tool: "write_file",
                args: [
                    "path": "{{output_path}}",
                    "content": "{{prev_output}}"
                ]
            )
        ],
        requiredPermissions: [
            "Procesamiento local Python (pocketpy sin OS)",
            "Escritura en archivos (con confirmación)"
        ],
        restrictions: [
            "No accede a red ni fuera del workspace autorizado.",
            "Escribir el catálogo final pide confirmación del usuario."
        ],
        testSpec: .init(
            sampleArguments: [
                "csv_content": "sku,nombre,precio,stock\nP01,Café Orgánico 500g,185.50,12\nP02,Taza Cerámica Coral,120.00,8",
                "output_path": "catalogo_productos.json"
            ],
            expectedSubstring: "productos_validos"
        ),
        version: "1.0.0",
        provenance: "template"
    )
}

/// Manages L1 tools created by the model or user inside the iPhone sandbox (`l1_tools.json`).
public actor DynamicToolRegistry {
    public static let shared = DynamicToolRegistry()

    public static let metaToolNames: Set<String> = [
        "l1_create_tool",
        "l1_list_tools",
        "l1_delete_tool"
    ]

    public static let metaTools: [AgentTool] = [
        AgentTool(
            name: "l1_create_tool",
            description: "Crea o actualiza una herramienta L1 reutilizable compuesta por pasos de herramientas L0 (read_file, write_file, python_eval, http_request, browser_*, iphone_*, shortcuts.run, isymcp_*). La L1 hereda estrictamente los permisos de sus pasos L0.",
            properties: [
                "name": .init(type: "string", description: "Nombre snake_case de la nueva tool L1 (ej. importar_catalogo_csv)."),
                "description": .init(type: "string", description: "Qué hace la herramienta y cuándo usarla."),
                "parameters_json": .init(type: "string", description: "JSON array opcional de parámetros: [{\"name\":\"csv_content\",\"type\":\"string\",\"description\":\"...\",\"required\":true}]."),
                "steps_json": .init(type: "string", description: "JSON array de pasos L0: [{\"tool\":\"python_eval\",\"args\":{\"script\":\"...\",\"input_text\":\"{{csv_content}}\"}}]. Soporta {{param}} y {{prev_output}}."),
                "output_schema": .init(type: "string", description: "Descripción opcional del formato de salida.")
            ],
            required: ["name", "description", "steps_json"],
            capabilities: .init(requiresFileSystem: true)
        ),
        AgentTool(
            name: "l1_list_tools",
            description: "Lista todas las herramientas L1 registradas en este iPhone junto con sus pasos, permisos heredados y versión.",
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

    public func definitions() -> [L1ToolDefinition] {
        cached
    }

    /// Computes the effective capabilities of an L1 composition as the strict union of its L0 steps.
    /// An L1 tool NEVER drops `isDestructive` or `requiresApprovalEveryTime` from any internal step.
    public static func effectiveCapabilities(
        for definition: L1ToolDefinition,
        l0Catalog: [String: AgentTool] = [:]
    ) -> AgentTool.ToolCapabilities {
        var requiresNetwork = false
        var requiresFileSystem = false
        var isDestructive = false
        var requiresApprovalEveryTime = false
        var restrictions: [String] = definition.restrictions
        var sensitiveSteps: [String] = []

        let mutatingToolNames: Set<String> = [
            "write_file", "write", "edit_file", "edit", "replace_lines", "append_file",
            "delete_file", "move_file", "create_directory", "copy_file",
            "notifications.schedule", "notifications.cancel", "shortcuts.run",
            "update_shared_context", "open_pull_request", "isymcp_respond_task"
        ]
        let everyTimeToolNames: Set<String> = [
            "iphone_type_text", "iphone_open_url", "notifications.schedule",
            "notifications.cancel", "shortcuts.run", "open_pull_request"
        ]

        for step in definition.steps {
            let name = step.tool
            let lower = name.lowercased()
            if let catalogTool = l0Catalog[name] {
                let cap = catalogTool.capabilities
                if cap.requiresNetwork { requiresNetwork = true }
                if cap.requiresFileSystem { requiresFileSystem = true }
                if cap.isDestructive {
                    isDestructive = true
                    if !sensitiveSteps.contains(name) { sensitiveSteps.append(name) }
                }
                if cap.requiresApprovalEveryTime {
                    requiresApprovalEveryTime = true
                }
                for r in cap.restrictions where !restrictions.contains(r) {
                    restrictions.append(r)
                }
            } else {
                // Fallback static inference when the L0 tool is in another executor (fileSystem / simple / assistant / WDA)
                if lower == "http_request" || lower.hasPrefix("browser_") || lower.hasPrefix("gmail.") || lower.hasPrefix("google") || lower.hasPrefix("isymcp_") {
                    requiresNetwork = true
                }
                if lower.contains("file") || lower.contains("directory") || lower == "read" || lower == "write" || lower == "edit" || lower == "list" || lower == "search_text" {
                    requiresFileSystem = true
                }
                let isMutatingWDA = lower.hasPrefix("iphone_") && lower != "iphone_status" && lower != "iphone_list_elements" && lower != "iphone_screenshot" && lower != "iphone_list_apps" && lower != "iphone_wait_for"
                let isMutatingGoogle = (lower.hasPrefix("gmail.") || lower.hasPrefix("google")) && (lower.contains(".write.") || lower.contains(".read."))
                if mutatingToolNames.contains(lower) || isMutatingWDA || isMutatingGoogle {
                    isDestructive = true
                    if !sensitiveSteps.contains(name) { sensitiveSteps.append(name) }
                }
                if everyTimeToolNames.contains(lower) {
                    requiresApprovalEveryTime = true
                }
            }
            if SecretVaultStore.containsSecretReference(in: step.args) {
                isDestructive = true
                requiresApprovalEveryTime = true
                if !sensitiveSteps.contains("\(name)[llavero]") {
                    sensitiveSteps.append("\(name)[llavero]")
                }
                let secretNote = "Usa referencias protegidas del Llavero ({{secret:...}}); pide confirmación explícita y Face ID en cada ejecución."
                if !restrictions.contains(secretNote) {
                    restrictions.append(secretNote)
                }
            }
        }

        let approvalReason: String?
        if isDestructive {
            let stepsText = sensitiveSteps.joined(separator: ", ")
            approvalReason = "La herramienta compuesta L1 '\(definition.name)' ejecutará pasos que requieren tu permiso (\(stepsText))."
        } else {
            approvalReason = nil
        }

        return AgentTool.ToolCapabilities(
            requiresNetwork: requiresNetwork,
            requiresFileSystem: requiresFileSystem,
            isDestructive: isDestructive,
            restrictions: restrictions,
            approvalReason: approvalReason,
            requiresApprovalEveryTime: requiresApprovalEveryTime
        )
    }

    public func allAgentTools(l0Catalog: [String: AgentTool] = [:]) -> [AgentTool] {
        cached.map { def in
            var props: [String: AgentTool.PropertySchema] = [:]
            var req: [String] = []
            for p in def.parameters {
                props[p.name] = .init(type: p.type, description: p.description)
                if p.required ?? true {
                    req.append(p.name)
                }
            }
            let effectiveCaps = Self.effectiveCapabilities(for: def, l0Catalog: l0Catalog)
            return AgentTool(
                name: def.name,
                description: "[L1 v\(def.version)] \(def.description)",
                properties: props,
                required: req,
                capabilities: effectiveCaps
            )
        }
    }

    public func definition(named name: String) -> L1ToolDefinition? {
        cached.first { $0.name == name }
    }

    public func upsert(_ definition: L1ToolDefinition) throws {
        try Self.validateNoCycles(candidate: definition, existing: cached)
        if let idx = cached.firstIndex(where: { $0.name == definition.name }) {
            cached[idx] = definition
        } else {
            cached.append(definition)
        }
        try save()
    }

    public func createTool(arguments: [String: String], provenance: String = "agent") throws -> String {
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
        for (i, step) in steps.enumerated() {
            if step.tool == rawName || Self.metaToolNames.contains(step.tool) {
                throw NSError(domain: "L1", code: 6, userInfo: [NSLocalizedDescriptionKey: "El paso \(i + 1) ('\(step.tool)') no puede invocarse a sí mismo ni a meta-herramientas L1."])
            }
        }
        var params: [L1ToolDefinition.Parameter] = []
        if let paramsJSON = arguments["parameters_json"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !paramsJSON.isEmpty,
           let paramsData = paramsJSON.data(using: .utf8) {
            params = try JSONDecoder().decode([L1ToolDefinition.Parameter].self, from: paramsData)
        }
        let outputSchema = arguments["output_schema"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "string (salida estructurada del último paso)"

        let def = L1ToolDefinition(
            name: rawName,
            description: description,
            parameters: params,
            outputSchema: outputSchema.isEmpty ? "string" : outputSchema,
            steps: steps,
            provenance: provenance
        )
        try upsert(def)
        let perms = def.requiredPermissions.isEmpty ? "lectura básica" : def.requiredPermissions.joined(separator: ", ")
        return "Tool L1 '\(rawName)' (v\(def.version)) guardada con \(steps.count) paso(s). Permisos efectivos heredados: \(perms)."
    }

    public static func validateNoCycles(candidate: L1ToolDefinition, existing: [L1ToolDefinition]) throws {
        var map = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        map[candidate.name] = candidate

        func dfs(_ current: String, visited: Set<String>, depth: Int) throws {
            if depth > 4 {
                throw NSError(domain: "L1", code: 7, userInfo: [NSLocalizedDescriptionKey: "Profundidad máxima de composición L1 excedida (máx. 4 niveles)."])
            }
            guard let def = map[current] else { return }
            for step in def.steps {
                if visited.contains(step.tool) {
                    throw NSError(domain: "L1", code: 8, userInfo: [NSLocalizedDescriptionKey: "Ciclo detectado entre herramientas L1: \(visited.joined(separator: " -> ")) -> \(step.tool)."])
                }
                if map[step.tool] != nil {
                    var nextVisited = visited
                    nextVisited.insert(step.tool)
                    try dfs(step.tool, visited: nextVisited, depth: depth + 1)
                }
            }
        }
        try dfs(candidate.name, visited: [candidate.name], depth: 1)
    }

    public func listToolsText() -> String {
        guard !cached.isEmpty else {
            return "No hay tools L1 creadas todavía. Usa l1_create_tool o el Constructor de Agentes para crear una sobre las primitivas L0."
        }
        return cached.map { def in
            let stepList = def.steps.map(\.tool).joined(separator: " -> ")
            let perms = def.requiredPermissions.isEmpty ? "sin permisos sensibles" : def.requiredPermissions.joined(separator: ", ")
            return "• \(def.name) (v\(def.version), \(def.provenance)): \(def.description) [pasos: \(stepList)] [permisos: \(perms)]"
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
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cached)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func load(from url: URL) -> [L1ToolDefinition] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([L1ToolDefinition].self, from: data) {
            return decoded
        }
        return (try? JSONDecoder().decode([L1ToolDefinition].self, from: data)) ?? []
    }
}

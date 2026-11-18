import Foundation

public enum AgentBackendTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case localIphone = "local_iphone"
    case remoteISyMCP = "remote_isymcp"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Automático (iPhone primero, PC si hace falta)"
        case .localIphone: return "En este iPhone (Local + Python)"
        case .remoteISyMCP: return "En tu computadora (ISyMCP / Sandbox)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .auto: return "Auto (Local / ISyMCP)"
        case .localIphone: return "Este iPhone"
        case .remoteISyMCP: return "PC · ISyMCP"
        }
    }

    public var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .localIphone: return "iphone"
        case .remoteISyMCP: return "desktopcomputer"
        }
    }
}

public struct AgentAuthorizationScope: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let plainExplanation: String
    public let requiresConfirmationPerAction: Bool
    public let sourceTools: [String]

    public init(
        id: String,
        title: String,
        plainExplanation: String,
        requiresConfirmationPerAction: Bool,
        sourceTools: [String]
    ) {
        self.id = id
        self.title = title
        self.plainExplanation = plainExplanation
        self.requiresConfirmationPerAction = requiresConfirmationPerAction
        self.sourceTools = sourceTools
    }
}

public struct AgentScriptAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var language: String
    public var description: String
    public var sourceCode: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        language: String = "python",
        description: String,
        sourceCode: String
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.description = description
        self.sourceCode = sourceCode
    }
}

public struct AgentContractTest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var sampleInput: String
    public var pythonVerificationScript: String?
    public var expectedSubstring: String
    public var lastRunAt: Date?
    public var lastPassed: Bool?
    public var lastOutput: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        sampleInput: String,
        pythonVerificationScript: String? = nil,
        expectedSubstring: String,
        lastRunAt: Date? = nil,
        lastPassed: Bool? = nil,
        lastOutput: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sampleInput = sampleInput
        self.pythonVerificationScript = pythonVerificationScript
        self.expectedSubstring = expectedSubstring
        self.lastRunAt = lastRunAt
        self.lastPassed = lastPassed
        self.lastOutput = lastOutput
    }
}

/// Versioned `.isyagent.json` contract (Section 10).
/// Approved permissions never transfer across exports (`localApprovalGrantedAt` is excluded when exporting).
public struct AgentContract: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let id: String
    public var name: String
    public var category: String
    public var icon: String
    public var accentHex: String
    public var goal: String
    public var summary: String
    public var systemInstructions: String
    public var enabledL0Tools: [String]
    public var l1Tools: [L1ToolDefinition]
    public var scripts: [AgentScriptAsset]
    public var dependencies: [String]
    public var preferredBackend: AgentBackendTarget
    public var requiredScopes: [AgentAuthorizationScope]
    public var requiredSecrets: [String]
    public var limitations: [String]
    public var exampleTasks: [String]
    public var tests: [AgentContractTest]
    public var createdAt: Date
    public var updatedAt: Date
    /// Local-only timestamp indicating the user reviewed and accepted this agent's scopes on THIS device.
    /// Stripped on `.isyagent.json` export and cleared on import.
    public var localApprovalGrantedAt: Date?

    public init(
        schemaVersion: String = AgentContract.currentSchemaVersion,
        id: String = UUID().uuidString,
        name: String,
        category: String,
        icon: String = "sparkles",
        accentHex: String = "E94560",
        goal: String,
        summary: String,
        systemInstructions: String,
        enabledL0Tools: [String],
        l1Tools: [L1ToolDefinition] = [],
        scripts: [AgentScriptAsset] = [],
        dependencies: [String] = [],
        preferredBackend: AgentBackendTarget = .localIphone,
        requiredScopes: [AgentAuthorizationScope]? = nil,
        requiredSecrets: [String]? = nil,
        limitations: [String] = [],
        exampleTasks: [String] = [],
        tests: [AgentContractTest] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        localApprovalGrantedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.category = category
        self.icon = icon
        self.accentHex = accentHex
        self.goal = goal
        self.summary = summary
        self.systemInstructions = systemInstructions
        self.enabledL0Tools = enabledL0Tools
        self.l1Tools = l1Tools
        self.scripts = scripts
        self.dependencies = dependencies
        self.preferredBackend = preferredBackend
        self.requiredScopes = requiredScopes ?? Self.computeRequiredScopes(l0Tools: enabledL0Tools, l1Tools: l1Tools)
        self.requiredSecrets = requiredSecrets ?? Self.computeRequiredSecrets(l1Tools: l1Tools)
        self.limitations = limitations
        self.exampleTasks = exampleTasks
        self.tests = tests
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localApprovalGrantedAt = localApprovalGrantedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, category, icon, accentHex, goal, summary, systemInstructions
        case enabledL0Tools, l1Tools, scripts, dependencies, preferredBackend, requiredScopes, requiredSecrets
        case limitations, exampleTasks, tests, createdAt, updatedAt, localApprovalGrantedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? AgentContract.currentSchemaVersion
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decode(String.self, forKey: .name)
        self.category = try c.decodeIfPresent(String.self, forKey: .category) ?? "custom"
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        self.accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "E94560"
        self.goal = try c.decode(String.self, forKey: .goal)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.systemInstructions = try c.decodeIfPresent(String.self, forKey: .systemInstructions) ?? ""
        let l0 = try c.decodeIfPresent([String].self, forKey: .enabledL0Tools) ?? []
        let l1 = try c.decodeIfPresent([L1ToolDefinition].self, forKey: .l1Tools) ?? []
        self.enabledL0Tools = l0
        self.l1Tools = l1
        self.scripts = try c.decodeIfPresent([AgentScriptAsset].self, forKey: .scripts) ?? []
        self.dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        self.preferredBackend = try c.decodeIfPresent(AgentBackendTarget.self, forKey: .preferredBackend) ?? .localIphone
        self.requiredScopes = try c.decodeIfPresent([AgentAuthorizationScope].self, forKey: .requiredScopes)
            ?? Self.computeRequiredScopes(l0Tools: l0, l1Tools: l1)
        self.requiredSecrets = try c.decodeIfPresent([String].self, forKey: .requiredSecrets)
            ?? Self.computeRequiredSecrets(l1Tools: l1)
        self.limitations = try c.decodeIfPresent([String].self, forKey: .limitations) ?? []
        self.exampleTasks = try c.decodeIfPresent([String].self, forKey: .exampleTasks) ?? []
        self.tests = try c.decodeIfPresent([AgentContractTest].self, forKey: .tests) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.localApprovalGrantedAt = try c.decodeIfPresent(Date.self, forKey: .localApprovalGrantedAt)
    }

    public static func computeRequiredSecrets(l1Tools: [L1ToolDefinition]) -> [String] {
        var aliases: [String] = []
        var seen: Set<String> = []
        for l1 in l1Tools {
            for alias in l1.requiredSecrets + L1ToolDefinition.inferSecretAliases(from: l1.steps) {
                let norm = SecretVaultEntryMetadata.normalizeAlias(alias)
                if seen.insert(norm).inserted {
                    aliases.append(norm)
                }
            }
        }
        return aliases.sorted()
    }

    /// Computes effective authorization scopes from both direct L0 tools and composed L1 steps (zero escalation).
    public static func computeRequiredScopes(
        l0Tools: [String],
        l1Tools: [L1ToolDefinition]
    ) -> [AgentAuthorizationScope] {
        let allStepTools = l1Tools.flatMap { $0.steps.map(\.tool) }
        let union = Array(Set(l0Tools + allStepTools)).sorted()

        var scopes: [AgentAuthorizationScope] = []

        let readTools = union.filter { ["read_file", "read", "list_directory", "list", "search_files", "search_text", "file_info"].contains($0) }
        if !readTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "workspace.read",
                title: "Leer archivos del proyecto",
                plainExplanation: "Permite consultar archivos dentro del espacio de trabajo de la app para analizarlos.",
                requiresConfirmationPerAction: false,
                sourceTools: readTools
            ))
        }

        let writeTools = union.filter { ["write_file", "write", "edit_file", "edit", "create_directory", "move_file", "delete_file"].contains($0) }
        if !writeTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "workspace.write",
                title: "Guardar o editar archivos en el proyecto",
                plainExplanation: "Cada archivo nuevo o modificado muestra qué cambiará y pide tu confirmación antes de guardarse.",
                requiresConfirmationPerAction: true,
                sourceTools: writeTools
            ))
        }

        if union.contains("python_eval") {
            scopes.append(AgentAuthorizationScope(
                id: "python.local",
                title: "Ejecutar lógica y cálculos con Python local",
                plainExplanation: "Procesa tablas, CSV, JSON y fórmulas en memoria con límite de tiempo (sin tocar el sistema ni internet por su cuenta).",
                requiresConfirmationPerAction: false,
                sourceTools: ["python_eval"]
            ))
        }

        let netTools = union.filter { $0 == "http_request" || $0.hasPrefix("browser_") }
        if !netTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "network.web",
                title: "Consultar páginas web o servicios HTTP",
                plainExplanation: "Permite abrir o consultar páginas en el navegador integrado de iSyCode o APIs autorizadas.",
                requiresConfirmationPerAction: false,
                sourceTools: netTools
            ))
        }

        let googleTools = union.filter { $0.hasPrefix("gmail.") || $0.hasPrefix("google") }
        if !googleTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "google.workspace",
                title: "Conectar con tu cuenta de Google",
                plainExplanation: "Leer datos personales pide tu permiso la primera vez; enviar correos o modificar tu agenda pide confirmación siempre.",
                requiresConfirmationPerAction: true,
                sourceTools: googleTools
            ))
        }

        let iphoneTools = union.filter { $0.hasPrefix("iphone_") }
        if !iphoneTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "iphone.wda",
                title: "Interactuar con la pantalla del iPhone (WDA)",
                plainExplanation: "Puedes autorizar una acción individual o una secuencia acotada por tarea para que no se interrumpa el flujo.",
                requiresConfirmationPerAction: true,
                sourceTools: iphoneTools
            ))
        }

        let isymcpTools = union.filter { $0.hasPrefix("isymcp_") || $0 == "run_command" }
        if !isymcpTools.isEmpty {
            scopes.append(AgentAuthorizationScope(
                id: "remote.isymcp",
                title: "Delegar tareas pesadas a tu computadora (ISyMCP)",
                plainExplanation: "Usa Tailscale y requiere tu confirmación biométrica (Face ID) para autorizar comandos o consolas en tu PC.",
                requiresConfirmationPerAction: true,
                sourceTools: isymcpTools
            ))
        }

        let secretAliases = computeRequiredSecrets(l1Tools: l1Tools)
        if !secretAliases.isEmpty || union.contains("secret_vault_list") {
            scopes.append(AgentAuthorizationScope(
                id: "security.secret_vault",
                title: "Usar referencias protegidas del Llavero",
                plainExplanation: "Las contraseñas viven en el Keychain de este iPhone (\(secretAliases.isEmpty ? "solo aliases" : secretAliases.joined(separator: ", "))). Piden confirmación manual y Face ID en cada uso; jamás viajan al modelo ni se exportan.",
                requiresConfirmationPerAction: true,
                sourceTools: ["secret_vault_list"]
            ))
        }

        return scopes
    }

    /// Exports a sanitized `.isyagent.json` without transferring local approvals or secret values (only aliases).
    public func exportSanitizedJSON() throws -> String {
        var copy = self
        copy.localApprovalGrantedAt = nil
        copy.requiredScopes = Self.computeRequiredScopes(l0Tools: copy.enabledL0Tools, l1Tools: copy.l1Tools)
        copy.requiredSecrets = Self.computeRequiredSecrets(l1Tools: copy.l1Tools) + copy.requiredSecrets.filter {
            !Self.computeRequiredSecrets(l1Tools: copy.l1Tools).contains($0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func importFromJSON(_ jsonString: String) throws -> AgentContract {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AgentContract", code: 1, userInfo: [NSLocalizedDescriptionKey: "El archivo .isyagent.json no es texto UTF-8 válido."])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var contract = try decoder.decode(AgentContract.self, from: data)
        // Security invariant (Section 10): never inherit approval state from an imported contract.
        contract.localApprovalGrantedAt = nil
        contract.requiredScopes = computeRequiredScopes(l0Tools: contract.enabledL0Tools, l1Tools: contract.l1Tools)
        return contract
    }

    /// Builds the effective system prompt when running this agent in chat.
    public func effectiveSystemPrompt() -> String {
        let l0List = enabledL0Tools.isEmpty ? "ninguna directa" : enabledL0Tools.joined(separator: ", ")
        let l1List = l1Tools.isEmpty ? "ninguna" : l1Tools.map(\.name).joined(separator: ", ")
        let vaultLine = requiredSecrets.isEmpty
            ? ""
            : "\n        Llaves del Llavero requeridas (solo referencias opacas, nunca pidas ni repitas contraseñas): \(requiredSecrets.map { "{{secret:\($0).username}} / {{secret:\($0).password}}" }.joined(separator: ", "))."
        return """
        Eres el agente '\(name)' en ISyCode Móvil.
        Objetivo principal: \(goal)
        \(systemInstructions)

        Herramientas L0 habilitadas en tu contrato: \(l0List).
        Herramientas L1 compuestas en tu contrato: \(l1List).
        Backend preferido: \(preferredBackend.title).\(vaultLine)

        Reglas operativas:
        - Usa siempre las herramientas reales registradas (por ejemplo, `python_eval` para procesar CSV/JSON o cálculos, `read_file`/`write_file` para archivos del proyecto, o las L1 de tu contrato).
        - Si el usuario te pide aprender una nueva acción visual (ej. WhatsApp o hacer una factura en Safari), pregúntale primero qué datos cambiarán y usa `learn_action_prepare` junto con `secret_vault_list` para preparar el grabador.
        - Nunca pidas contraseñas en texto plano en el chat: usa `secret_vault_request_entry` o referencias `{{secret:alias.password}}` del Llavero.
        - Explica tus pasos en lenguaje claro y humano, sin pedirle al usuario comandos técnicos que tú mismo puedas resolver.
        - Respeta todas las confirmaciones de seguridad de ISyCode.
        """
    }
}

public struct AgentCompatibilityReport: Sendable, Equatable {
    public let isCompatible: Bool
    public let requiresUserAuthorization: Bool
    public let missingConnections: [String]
    public let summary: String
}

/// Declarative templates for the Agent Builder (Section 6.1).
public struct AgentTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let accentHex: String
    public let objective: String
    public let gusPitch: String
    public let suggestedL0Tools: [String]
    public let suggestedL1Tools: [L1ToolDefinition]
    public let scripts: [AgentScriptAsset]
    public let preferredBackend: AgentBackendTarget
    public let limitations: [String]
    public let exampleTasks: [String]
    public let defaultTest: AgentContractTest

    public func makeInitialContract() -> AgentContract {
        AgentContract(
            name: title,
            category: id,
            icon: icon,
            accentHex: accentHex,
            goal: objective,
            summary: subtitle,
            systemInstructions: "Ayuda a la persona a cumplir su objetivo paso a paso, validando los datos antes de guardar cambios.",
            enabledL0Tools: suggestedL0Tools,
            l1Tools: suggestedL1Tools,
            scripts: scripts,
            dependencies: ["pocketpy-2.2.0 (json, csv, math)"],
            preferredBackend: preferredBackend,
            limitations: limitations,
            exampleTasks: exampleTasks,
            tests: [defaultTest]
        )
    }
}

public enum AgentTemplateCatalog {
    public static let all: [AgentTemplate] = [
        AgentTemplate(
            id: "store_creator",
            title: "Creador de tiendas",
            subtitle: "Importa productos CSV, valida precios y arma tu catálogo",
            icon: "cart.fill",
            accentHex: "E94560",
            objective: "Importar mi lista de productos, revisar precios e inventario y generar un catálogo listo para vender.",
            gusPitch: "Puedo preparar una capacidad compuesta (`importar_catalogo_csv`) que lee tu archivo de productos, comprueba con Python que ningún precio esté vacío o negativo y guarda el catálogo verificado.",
            suggestedL0Tools: ["read_file", "python_eval", "write_file", "list_directory"],
            suggestedL1Tools: [L1ToolDefinition.sampleCatalogImporter],
            scripts: [
                AgentScriptAsset(
                    name: "validador_catalogo.py",
                    description: "Valida columnas SKU, nombre, precio y stock de un CSV y calcula totales.",
                    sourceCode: """
                    rows = csv.parse(INPUT_TEXT)
                    validos = [r for r in rows if float(r.get('precio', '0')) > 0]
                    total = sum([float(r['precio']) for r in validos])
                    print(json.dumps({'productos': len(validos), 'valor_catalogo': round(total, 2), 'items': validos}))
                    """
                )
            ],
            preferredBackend: .localIphone,
            limitations: [
                "No procesa pagos reales ni conecta pasarelas bancarias por sí mismo.",
                "Guardar el catálogo final en tu carpeta pide tu confirmación."
            ],
            exampleTasks: [
                "Importa este CSV de cafetería, revisa los precios y genera catalogo_productos.json",
                "Encuentra qué productos tienen stock bajo y sugiéreme precios de oferta"
            ],
            defaultTest: AgentContractTest(
                title: "Importar y validar catálogo CSV de ejemplo",
                sampleInput: "sku,nombre,precio,stock\nC01,Café de Altura 500g,185.50,15\nC02,Prensa Francesa,420.00,6\nC03,Filtro Papel,65.00,30",
                pythonVerificationScript: """
                rows = csv.parse(INPUT_TEXT)
                validos = [r for r in rows if float(r.get('precio', '0')) > 0]
                total = sum([float(r['precio']) for r in validos])
                print(json.dumps({'ok': True, 'productos_validos': len(validos), 'suma_precios': round(total, 2), 'muestra': validos[0]['nombre']}))
                """,
                expectedSubstring: "productos_validos"
            )
        ),
        AgentTemplate(
            id: "web_creator",
            title: "Creador de páginas web",
            subtitle: "Diseña sitios limpios y revísalos en el navegador integrado",
            icon: "globe",
            accentHex: "22D3EE",
            objective: "Crear una página web moderna para presentar mi proyecto o negocio y previsualizarla en el iPhone.",
            gusPitch: "Combinamos edición de archivos en tu proyecto con estructuras verificadas por Python y el navegador integrado para que veas el resultado sin salir de la app.",
            suggestedL0Tools: ["write_file", "edit_file", "read_file", "python_eval", "browser_navigate", "browser_get_page"],
            suggestedL1Tools: [],
            scripts: [],
            preferredBackend: .localIphone,
            limitations: [
                "Genera archivos estáticos (HTML/CSS/JS) en tu workspace; publicarlos en un dominio externo requiere tu aprobación o ISyMCP."
            ],
            exampleTasks: [
                "Crea una landing page para mi estudio de diseño con sección de contacto",
                "Genera una tabla comparativa de planes en HTML adaptable a móvil"
            ],
            defaultTest: AgentContractTest(
                title: "Generar estructura de secciones web",
                sampleInput: "{\"titulo\":\"Estudio Coral\",\"secciones\":[\"Inicio\",\"Portafolio\",\"Contacto\"]}",
                pythonVerificationScript: """
                data = json.loads(INPUT_TEXT)
                html = '<main><h1>' + data['titulo'] + '</h1>' + ''.join(['<section>' + s + '</section>' for s in data['secciones']]) + '</main>'
                print(json.dumps({'ok': True, 'secciones': len(data['secciones']), 'html_preview': html}))
                """,
                expectedSubstring: "html_preview"
            )
        ),
        AgentTemplate(
            id: "research_assistant",
            title: "Asistente de investigación",
            subtitle: "Consulta páginas web, sintetiza datos y guarda resúmenes",
            icon: "doc.text.magnifyingglass",
            accentHex: "9B5DE5",
            objective: "Investigar un tema en la web, extraer cifras clave y guardar un resumen organizado en mis archivos.",
            gusPitch: "Usará el navegador integrado y peticiones HTTP para leer fuentes, Python local para organizar los hallazgos y guardará el informe cuando lo autorices.",
            suggestedL0Tools: ["http_request", "browser_navigate", "browser_get_page", "python_eval", "write_file"],
            suggestedL1Tools: [],
            scripts: [],
            preferredBackend: .localIphone,
            limitations: [
                "Trata todo texto web como datos no confiables; nunca ejecuta instrucciones ocultas en páginas externas."
            ],
            exampleTasks: [
                "Investiga tres opciones de empaques biodegradables y haz una tabla comparativa",
                "Resume los puntos principales de una página y guárdalos en resumen.md"
            ],
            defaultTest: AgentContractTest(
                title: "Sintetizar y clasificar hallazgos JSON",
                sampleInput: "[{\"fuente\":\"A\",\"costo\":12.5},{\"fuente\":\"B\",\"costo\":9.8}]",
                pythonVerificationScript: """
                items = json.loads(INPUT_TEXT)
                mejor = min([x['costo'] for x in items])
                print(json.dumps({'ok': True, 'fuentes_analizadas': len(items), 'mejor_costo': mejor}))
                """,
                expectedSubstring: "fuentes_analizadas"
            )
        ),
        AgentTemplate(
            id: "task_automator",
            title: "Automatizador de tareas",
            subtitle: "Coordina Gmail, Agenda, recordatorios y acciones en el iPhone",
            icon: "bolt.badge.clock.fill",
            accentHex: "FBBF24",
            objective: "Revisar mis pendientes en Gmail y Agenda, programar recordatorios y ayudarme con tareas repetitivas.",
            gusPitch: "Prioriza siempre las integraciones directas en segundo plano (Google y recordatorios nativos) y deja el control de pantalla WDA solo para apps que no tienen API.",
            suggestedL0Tools: ["gmail.read.inbox", "googlecalendar.read.events", "googletasks.read.tasks", "notifications.schedule", "python_eval", "iphone_status", "iphone_list_elements"],
            suggestedL1Tools: [],
            scripts: [],
            preferredBackend: .localIphone,
            limitations: [
                "Requiere conectar tu cuenta de Google en la sección Google para leer correo o agenda.",
                "Las secuencias visuales WDA requieren que WDA esté activo en el iPhone."
            ],
            exampleTasks: [
                "Revisa qué correos urgentes tengo hoy y créame un recordatorio en 30 minutos",
                "Cruza mis eventos de hoy con mi lista de tareas pendientes"
            ],
            defaultTest: AgentContractTest(
                title: "Priorizar lista de tareas pendientes",
                sampleInput: "[{\"tarea\":\"Enviar factura\",\"urgente\":true},{\"tarea\":\"Archivar recibos\",\"urgente\":false}]",
                pythonVerificationScript: """
                tareas = json.loads(INPUT_TEXT)
                urgentes = [t['tarea'] for t in tareas if t.get('urgente')]
                print(json.dumps({'ok': True, 'total': len(tareas), 'urgentes': urgentes}))
                """,
                expectedSubstring: "urgentes"
            )
        ),
        AgentTemplate(
            id: "file_organizer",
            title: "Organizador de archivos",
            subtitle: "Explora tu carpeta de proyecto, clasifica textos y crea índices",
            icon: "folder.fill.badge.gearshape",
            accentHex: "4ADE80",
            objective: "Ordenar los archivos de mi proyecto, encontrar notas dispersas y crear un índice claro.",
            gusPitch: "Solo necesita permiso para leer tu carpeta de trabajo y pedirte confirmación antes de escribir el índice nuevo. Nunca borra archivos por su cuenta.",
            suggestedL0Tools: ["list_directory", "search_files", "read_file", "python_eval", "write_file"],
            suggestedL1Tools: [],
            scripts: [],
            preferredBackend: .localIphone,
            limitations: [
                "Solo ve la carpeta del proyecto o la carpeta que autorizaste en Archivos.",
                "No elimina archivos sin que se habilite y apruebe explícitamente."
            ],
            exampleTasks: [
                "Explora esta carpeta y hazme un índice de todos los documentos por tema",
                "Busca dónde se menciona el presupuesto en mis notas"
            ],
            defaultTest: AgentContractTest(
                title: "Agrupar lista de archivos por extensión",
                sampleInput: "[\"notas.md\",\"ventas.csv\",\"catalogo.json\",\"plan.md\"]",
                pythonVerificationScript: """
                files = json.loads(INPUT_TEXT)
                grupos = {}
                for f in files:
                    ext = f.split('.')[-1] if '.' in f else 'otros'
                    grupos[ext] = grupos.get(ext, 0) + 1
                print(json.dumps({'ok': True, 'total_archivos': len(files), 'por_tipo': grupos}))
                """,
                expectedSubstring: "por_tipo"
            )
        ),
        AgentTemplate(
            id: "business_assistant",
            title: "Asistente de negocios",
            subtitle: "Analiza ventas, márgenes y correos de clientes con claridad",
            icon: "chart.bar.xaxis",
            accentHex: "F799C6",
            objective: "Analizar mis números de ventas y gastos, calcular márgenes reales y preparar reportes claros.",
            gusPitch: "Usa Python local para que las cuentas siempre sean exactas (sin alucinaciones matemáticas del modelo) y guarda tus reportes en el workspace.",
            suggestedL0Tools: ["read_file", "python_eval", "write_file", "gmail.read.inbox"],
            suggestedL1Tools: [L1ToolDefinition.sampleCatalogImporter],
            scripts: [],
            preferredBackend: .localIphone,
            limitations: [
                "Los cálculos financieros son informativos; revisa siempre antes de enviar un reporte externo."
            ],
            exampleTasks: [
                "Calcula el margen neto de estas ventas CSV y dime cuáles son los 3 productos más rentables",
                "Prepara un resumen semanal de ingresos vs gastos"
            ],
            defaultTest: AgentContractTest(
                title: "Calcular margen y utilidad de ventas",
                sampleInput: "producto,venta,costo\nSuscripción Pro,1200,300\nConsultoría,2500,800",
                pythonVerificationScript: """
                rows = csv.parse(INPUT_TEXT)
                ingresos = sum([float(r['venta']) for r in rows])
                costos = sum([float(r['costo']) for r in rows])
                utilidad = ingresos - costos
                print(json.dumps({'ok': True, 'ingresos': ingresos, 'costos': costos, 'utilidad_neta': utilidad}))
                """,
                expectedSubstring: "utilidad_neta"
            )
        ),
        AgentTemplate(
            id: "custom_agent",
            title: "Agente personalizado",
            subtitle: "Elige tu objetivo y deja que GUS te recomiende las capacidades",
            icon: "wand.and.stars",
            accentHex: "9E99F7",
            objective: "",
            gusPitch: "Cuéntame con tus propias palabras qué quieres lograr. Yo te sugiero qué herramientas L0/L1 activar y si conviene correrlo en este iPhone o con ISyMCP en tu PC.",
            suggestedL0Tools: ["read_file", "python_eval", "write_file"],
            suggestedL1Tools: [],
            scripts: [],
            preferredBackend: .auto,
            limitations: [
                "Las herramientas que elijas determinan exactamente los permisos que pedirá el agente."
            ],
            exampleTasks: [
                "Procesar datos de un archivo y generar un reporte limpio",
                "Coordinar tareas entre mi iPhone y mi computadora con ISyMCP"
            ],
            defaultTest: AgentContractTest(
                title: "Verificación básica de Python local",
                sampleInput: "{\"mensaje\":\"Hola desde tu agente personalizado\"}",
                pythonVerificationScript: """
                data = json.loads(INPUT_TEXT)
                print(json.dumps({'ok': True, 'eco': data['mensaje']}))
                """,
                expectedSubstring: "Hola desde tu agente"
            )
        )
    ]

    /// Recommends L0 and L1 tools based on the user's plain-language goal (Step A -> Step B).
    public static func recommendTools(forGoal rawGoal: String) -> (l0: [String], l1: [L1ToolDefinition], explanation: String) {
        let lower = rawGoal.lowercased()
        var l0: [String] = ["read_file", "python_eval", "write_file"]
        var l1: [L1ToolDefinition] = []
        var reasons: [String] = [
            "Lectura y escritura de archivos del proyecto junto con Python local (`python_eval`) para procesar datos con exactitud."
        ]

        if lower.contains("tienda") || lower.contains("csv") || lower.contains("producto") || lower.contains("catálogo") || lower.contains("catalogo") || lower.contains("precio") || lower.contains("inventario") {
            l1.append(.sampleCatalogImporter)
            reasons.append("Incluí la capacidad compuesta `importar_catalogo_csv` para validar precios e inventario automáticamente.")
        }
        if lower.contains("web") || lower.contains("página") || lower.contains("pagina") || lower.contains("html") || lower.contains("sitio") || lower.contains("investiga") {
            for t in ["http_request", "browser_navigate", "browser_get_page"] where !l0.contains(t) {
                l0.append(t)
            }
            reasons.append("Añadí el navegador integrado y consultas web para revisar páginas sin salir de iSyCode.")
        }
        if lower.contains("correo") || lower.contains("gmail") || lower.contains("email") || lower.contains("agenda") || lower.contains("calendario") {
            for t in ["gmail.read.inbox", "googlecalendar.read.events", "googletasks.read.tasks"] where !l0.contains(t) {
                l0.append(t)
            }
            reasons.append("Añadí las herramientas de Google en segundo plano para consultar correo y agenda con tu permiso.")
        }
        if lower.contains("iphone") || lower.contains("pantalla") || lower.contains("app") || lower.contains("whatsapp") || lower.contains(" safari") {
            for t in ["iphone_status", "iphone_list_elements", "iphone_tap_element"] where !l0.contains(t) {
                l0.append(t)
            }
            reasons.append("Añadí control del iPhone (WDA) con aprobación por secuencia para no interrumpir la tarea.")
        }
        if lower.contains("compila") || lower.contains("pc") || lower.contains("computadora") || lower.contains("isymcp") || lower.contains("terminal") || lower.contains("zig") || lower.contains("swift") {
            for t in ["isymcp_status", "isymcp_tasks"] where !l0.contains(t) {
                l0.append(t)
            }
            reasons.append("Añadí el enlace con ISyMCP en tu computadora para tareas que requieren compilador o consola remota.")
        }

        return (l0, l1, reasons.joined(separator: " "))
    }
}

/// Persisted draft state for the 6-step Agent Builder so iOS suspension never loses work (Section 6.2 & Scenario D).
public struct AgentBuilderDraft: Codable, Sendable, Equatable {
    public var currentStepIndex: Int
    public var selectedTemplateID: String
    public var contract: AgentContract
    public var savedAt: Date

    public init(
        currentStepIndex: Int = 0,
        selectedTemplateID: String = "store_creator",
        contract: AgentContract = AgentTemplateCatalog.all[0].makeInitialContract(),
        savedAt: Date = Date()
    ) {
        self.currentStepIndex = currentStepIndex
        self.selectedTemplateID = selectedTemplateID
        self.contract = contract
        self.savedAt = savedAt
    }
}

/// Manages saved Agent Contracts (`agents.json`) and the active Builder Draft (`agent_builder_draft.json`).
@MainActor
public final class AgentContractStore: ObservableObject {
    public static let shared = AgentContractStore()

    @Published public private(set) var agents: [AgentContract] = []
    @Published public var activeDraft: AgentBuilderDraft?
    @Published public var activeAgentForSession: AgentContract?
    @Published public private(set) var isRefreshing = false
    @Published public var lastError: String?

    private let agentsURL: URL
    private let draftURL: URL

    public init(directoryURL: URL? = nil) {
        let base: URL
        if let directoryURL {
            base = directoryURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = docs.appendingPathComponent(".isycode")
        }
        self.agentsURL = base.appendingPathComponent("agents.json")
        self.draftURL = base.appendingPathComponent("agent_builder_draft.json")
        loadFromDisk()
    }

    public func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: agentsURL),
           let decoded = try? decoder.decode([AgentContract].self, from: data) {
            self.agents = decoded
        } else if agents.isEmpty {
            // Seed with a ready-to-inspect starter agent so "Mis agentes" is immediately useful
            var starter = AgentTemplateCatalog.all[0].makeInitialContract()
            starter.localApprovalGrantedAt = Date()
            self.agents = [starter]
            saveAgentsToDisk()
        }

        if let draftData = try? Data(contentsOf: draftURL),
           let decodedDraft = try? decoder.decode(AgentBuilderDraft.self, from: draftData) {
            self.activeDraft = decodedDraft
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        try? await Task.sleep(nanoseconds: 180_000_000)
        loadFromDisk()
    }

    public func saveDraft(_ draft: AgentBuilderDraft) {
        var updated = draft
        updated.savedAt = Date()
        updated.contract.updatedAt = Date()
        updated.contract.requiredScopes = AgentContract.computeRequiredScopes(
            l0Tools: updated.contract.enabledL0Tools,
            l1Tools: updated.contract.l1Tools
        )
        self.activeDraft = updated
        do {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(updated)
            try data.write(to: draftURL, options: .atomic)
        } catch {
            lastError = "No se pudo guardar el borrador: \(error.localizedDescription)"
        }
    }

    public func clearDraft() {
        activeDraft = nil
        try? FileManager.default.removeItem(at: draftURL)
    }

    public func saveAgent(_ contract: AgentContract, registerL1Tools: Bool = true) async {
        var updated = contract
        updated.updatedAt = Date()
        updated.requiredScopes = AgentContract.computeRequiredScopes(
            l0Tools: updated.enabledL0Tools,
            l1Tools: updated.l1Tools
        )
        if let idx = agents.firstIndex(where: { $0.id == updated.id }) {
            agents[idx] = updated
        } else {
            agents.insert(updated, at: 0)
        }
        saveAgentsToDisk()

        if registerL1Tools {
            for l1 in updated.l1Tools {
                try? await DynamicToolRegistry.shared.upsert(l1)
            }
        }
    }

    public func deleteAgent(id: String) {
        agents.removeAll { $0.id == id }
        if activeAgentForSession?.id == id {
            activeAgentForSession = nil
        }
        saveAgentsToDisk()
    }

    public func approveContractOnThisDevice(id: String) {
        guard let idx = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[idx].localApprovalGrantedAt = Date()
        saveAgentsToDisk()
    }

    public func evaluateCompatibility(
        for contract: AgentContract,
        googleConnected: Bool,
        isymcpPaired: Bool,
        vaultStore: SecretVaultStore? = nil
    ) -> AgentCompatibilityReport {
        let resolvedVault = vaultStore ?? .shared
        var missing: [String] = []
        let allTools = Set(contract.enabledL0Tools + contract.l1Tools.flatMap { $0.steps.map(\.tool) })
        if allTools.contains(where: { $0.hasPrefix("gmail.") || $0.hasPrefix("google") }) && !googleConnected {
            missing.append("Cuenta de Google (conéctala en la sección Google)")
        }
        if (contract.preferredBackend == .remoteISyMCP || allTools.contains(where: { $0.hasPrefix("isymcp_") })) && !isymcpPaired {
            missing.append("Computadora con ISyMCP (emparéjala en Conexiones → ISyMCP)")
        }
        let allRequiredSecrets = Set(contract.requiredSecrets + AgentContract.computeRequiredSecrets(l1Tools: contract.l1Tools))
        let missingSecrets = resolvedVault.missingAliases(from: Array(allRequiredSecrets))
        for alias in missingSecrets {
            missing.append("Credencial en Llavero: '{{secret:\(alias)}}' (guárdala en Conexiones → Llavero)")
        }
        let needsAuth = contract.localApprovalGrantedAt == nil && !contract.requiredScopes.isEmpty
        let summary: String
        if missing.isEmpty {
            summary = needsAuth
                ? "Compatible con este iPhone. Revisa y autoriza sus permisos antes de ejecutarlo."
                : "Listo para ejecutarse en este iPhone."
        } else {
            summary = "Compatible parcialmente. Para usar todas las funciones conecta: \(missing.joined(separator: ", "))."
        }
        return AgentCompatibilityReport(
            isCompatible: missing.isEmpty,
            requiresUserAuthorization: needsAuth,
            missingConnections: missing,
            summary: summary
        )
    }

    private func saveAgentsToDisk() {
        do {
            try FileManager.default.createDirectory(at: agentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(agents)
            try data.write(to: agentsURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "No se pudo guardar el agente: \(error.localizedDescription)"
        }
    }
}

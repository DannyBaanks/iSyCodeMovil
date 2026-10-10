import Foundation

/// Protocolo base común para backends remotos.
/// Abstracta las operaciones que cualquier backend remoto (OpenCode, Crush, Codex, etc.)
/// debe implementar para conectarse a un servidor HTTP existente.
public protocol RemoteBackend: WorkbenchBackend {
    /// El tipo de backend remoto (para UI/display)
    var remoteType: RemoteBackendType { get }
    
    /// URL base del servidor remoto
    var baseURL: URL { get }
    
    /// Headers de autenticación para requests
    var authHeaders: [String: String] { get }
    
    /// Configura el backend con una pairing link parseada
    func configure(with pairing: RemotePairing) async throws
    
    /// Health check del servidor remoto
    func healthCheck() async throws -> RemoteHealth
    
    /// Obtiene la lista de sesiones del servidor remoto
    func listSessions() async throws -> [RemoteSession]
    
    /// Crea una nueva sesión en el servidor remoto
    func createSession(title: String) async throws -> RemoteSession
    
    /// Elimina una sesión en el servidor remoto
    func deleteSession(sessionID: String) async throws
    
    /// Renombra una sesión
    func renameSession(sessionID: String, title: String) async throws
    
    /// Envía un prompt al servidor remoto
    func sendPrompt(sessionID: String, text: String, agent: String?, modelProvider: String?, modelID: String?) async throws
    
    /// Aborta la ejecución actual
    func abort(sessionID: String) async throws
    
    /// Responde a un pedido de permisos
    func replyPermission(sessionID: String, permissionID: String, response: String) async throws
    
    /// Obtiene mensajes de una sesión
    func messages(sessionID: String) async throws -> [RemoteMessage]
    
    /// Stream de eventos del servidor (SSE/WS)
    func events() -> AsyncThrowingStream<RemoteEvent, Error>
    
    /// Lista archivos en el servidor remoto
    func listFiles(path: String) async throws -> [RemoteFileNode]
    
    /// Obtiene contenido de un archivo
    func fileContent(path: String) async throws -> RemoteFileContent
    
    /// Ejecuta un comando shell en el servidor remoto
    func runShell(sessionID: String, command: String, agent: String?, workdir: String?) async throws -> ShellResult
    
    /// Obtiene diff de una sesión
    func sessionDiff(sessionID: String) async throws -> [SessionDiff]
    
    /// Lista providers disponibles
    func providers() async throws -> ProviderListResult
    
    /// Obtiene configuración del servidor
    func config() async throws -> ConfigInfo
    
    /// Obtiene comandos disponibles
    func commands() async throws -> [CommandInfo]
    
    /// Obtiene path del workspace
    func getPath() async throws -> String
}

/// Tipos de backend remoto soportados
public enum RemoteBackendType: String, Sendable, CaseIterable {
    case opencode = "opencode"
    case crush = "crush"
    case codex = "codex"
    case grok = "grok"
    case claudeCode = "claude_code"
    case gemini = "gemini"
    case openisy = "openisy"
    
    public var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .crush: return "Crush"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .claudeCode: return "Claude Code"
        case .gemini: return "Gemini"
        case .openisy: return "OpenISy"
        }
    }
}

/// Pairing genérico para cualquier backend remoto
public struct RemotePairing: Equatable, Sendable {
    public let type: RemoteBackendType
    public let scheme: String
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let directory: String
    
    public init(type: RemoteBackendType = .opencode,
                scheme: String = "http",
                host: String,
                port: Int,
                username: String = "user",
                password: String,
                directory: String = "") {
        self.type = type
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.directory = directory
    }
    
    public var baseURL: URL {
        URL(string: "\(scheme)://\(host):\(port)")!
    }
    
    public var authHeaders: [String: String] {
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(credentials)"]
    }
}

/// Health check response
public struct RemoteHealth: Sendable {
    public let healthy: Bool
    public let version: String
    public let backendType: RemoteBackendType?
}

/// Sesión remota
public struct RemoteSession: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let directory: String
    public let updatedAt: Date
    public let backendType: RemoteBackendType
    
    public init(id: String, title: String, directory: String, updatedAt: Date, backendType: RemoteBackendType = .opencode) {
        self.id = id
        self.title = title
        self.directory = directory
        self.updatedAt = updatedAt
        self.backendType = backendType
    }
}

/// Mensaje remoto
public struct RemoteMessage: Sendable {
    public let role: String
    public let id: String
    public let parts: [RemotePart]
}

/// Partes de mensaje remoto
public struct RemotePart: Sendable {
    public enum Kind: Sendable { case text, reasoning, tool, other }
    public let id: String
    public let messageID: String?
    public let kind: Kind
    public let text: String?
    public let tool: String?
    public let callID: String?
    public let status: String?
    public let input: [String: String]
    public let output: String?
    public let error: String?
}

/// Eventos de streaming remoto
public enum RemoteEvent: Sendable {
    case connected
    case disconnected(String)
    case part(RemotePart)
    case partDelta(partID: String, delta: String)
    case permission(RemotePermission)
    case messageRole(messageID: String, role: String)
    case sessionIdle(String)
    case sessionError(String)
    case other(String)
}

/// Pedido de permisos remoto
public struct RemotePermission: Sendable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let type: String
    public let metadata: [String: String]
}

/// Nodo de archivo remoto
public struct RemoteFileNode: Sendable {
    public let name: String
    public let path: String
    public let absolutePath: String?
    public let isDirectory: Bool
    public let type: String?
    public let ignored: Bool?
}

/// Contenido de archivo remoto
public struct RemoteFileContent: Sendable {
    public let path: String
    public let type: String
    public let content: String
    public let mimeType: String?
    public let encoding: String?
}

/// Resultado de shell remoto
public struct ShellResult: Sendable {
    public let sessionID: String
    public let messageID: String
    public let parts: [RemotePart]

    public var textParts: [String] { parts.compactMap(\.text) }
    public var error: String? {
        parts.first { $0.kind == .tool && $0.status == "error" }?.error
    }
}

/// Diff de sesión
public struct SessionDiff: Sendable {
    public let file: String
    public let additions: Int
    public let deletions: Int
    public let before: String?
    public let after: String?
}

/// Info de provider
public struct ProviderInfo: Sendable {
    public let id: String
    public let name: String
    public let models: [String: [String: Any]]?
}

public struct ProviderListResult: Sendable {
    public let all: [ProviderInfo]
    public let connected: [String]
    public let defaultProvider: String?
}

/// Config info
public struct ConfigInfo: Sendable {
    public let agents: [String: [String: Any]]?
    public let provider: [String: Any]?
}

/// Info de comando
public struct CommandInfo: Sendable {
    public let name: String
    public let description: String?
}

/// Errores comunes de backend remoto
public enum RemoteBackendError: Error, LocalizedError, Sendable {
    case invalidPairingLink
    case invalidResponse
    case http(Int, String)
    case missingSession
    case unsupportedOnThisHost(String)
    case unsupportedFeature(String)
    case authenticationFailed
    case connectionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPairingLink: return "Invalid pairing link"
        case .invalidResponse: return "Invalid response from remote server"
        case .http(let status, let body): return "Remote server HTTP \(status): \(body)"
        case .missingSession: return "No session is selected"
        case .unsupportedOnThisHost(let detail): return "Not supported on this host: \(detail)"
        case .unsupportedFeature(let feature): return "Unsupported feature: \(feature)"
        case .authenticationFailed: return "Authentication failed"
        case .connectionFailed(let detail): return "Connection failed: \(detail)"
        }
    }
}

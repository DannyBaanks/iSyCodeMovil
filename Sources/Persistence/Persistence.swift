import Foundation

/// Protocolo de persistencia para el runtime del agente.
/// Almacena conversaciones, eventos, estado del agente, configuración.
/// Secrets (API keys) se gestionan via Keychain.
public protocol Persistence: Sendable {
    func saveConversation(_ conversation: Conversation) async throws
    func loadConversation(id: String) async throws -> Conversation?
    func listConversations() async throws -> [ConversationSummary]
    func deleteConversation(id: String) async throws
    
    func saveAgentState(_ state: AgentState) async throws
    func loadAgentState() async throws -> AgentState?
    
    func saveConfiguration(_ config: Configuration) async throws
    func loadConfiguration() async throws -> Configuration?
    
    // Keychain methods for secrets
    func saveAPIKey(provider: String, key: String) async throws
    func loadAPIKey(provider: String) async throws -> String?
    func deleteAPIKey(provider: String) async throws
    
    func appendEvent(_ event: AgentEvent) async throws
    func loadEvents(conversationId: String, since: Date?) async throws -> [AgentEvent]
}

/// Conversación completa
public struct Conversation: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]
    public var metadata: [String: String]
    
    public init(id: String = UUID().uuidString, title: String = "New Conversation") {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
        self.metadata = [:]
    }
}

/// Resumen para listar conversaciones
public struct ConversationSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let lastMessagePreview: String?
}

/// Mensaje individual
public struct Message: Codable, Sendable, Identifiable {
    public let id: String
    public let role: Role
    public let content: String
    public let toolCalls: [ToolCall]?
    public let toolResults: [ToolResult]?
    public let timestamp: Date
    public let metadata: [String: String]
    public let multimodalParts: [ModelMessage.ContentPart]?
    
    public enum Role: String, Codable, Sendable {
        case user, assistant, system, tool
    }
    
    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolResults: [ToolResult]? = nil,
        metadata: [String: String] = [:],
        multimodalParts: [ModelMessage.ContentPart]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.timestamp = Date()
        self.metadata = metadata
        self.multimodalParts = multimodalParts
    }
}

/// Llamada a herramienta
public struct ToolCall: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: [String: String]
    public let timestamp: Date
    
    public init(id: String = UUID().uuidString, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.timestamp = Date()
    }
}

/// Resultado de herramienta
public struct ToolResult: Codable, Sendable, Identifiable {
    public let id: String
    public let toolCallId: String
    public let output: String
    public let error: String?
    public let timestamp: Date
    
    public init(id: String = UUID().uuidString, toolCallId: String, output: String, error: String? = nil) {
        self.id = id
        self.toolCallId = toolCallId
        self.output = output
        self.error = error
        self.timestamp = Date()
    }
}

/// Estado del agente
public struct AgentState: Codable, Sendable {
    public var currentWorkspace: String?
    public var modelProvider: String?
    public var modelName: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var systemPrompt: String?
    public var settings: [String: String]
    
    public init() {
        self.settings = [:]
    }
}

/// Evento del agente (para JSONL audit trail)
public struct AgentEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let conversationId: String
    public let type: EventType
    public let payload: [String: String]
    public let timestamp: Date
    
    public enum EventType: String, Codable, Sendable {
        case userInput, modelRequest, modelResponse, toolCall, toolResult, error, stateChange
    }
    
    public init(
        id: String = UUID().uuidString,
        conversationId: String,
        type: EventType,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.conversationId = conversationId
        self.type = type
        self.payload = payload
        self.timestamp = Date()
    }
}

/// Configuración de la app
public struct Configuration: Codable, Sendable {
    public var defaultModelProvider: String?
    public var defaultModelName: String?
    // apiKeys se almacenan en Keychain, no en JSON
    public var workspacePath: String?
    public var theme: String?
    public var fontSize: Double?
    public var autoSave: Bool?
    
    public init() {
        self.theme = "system"
        self.fontSize = 14
        self.autoSave = true
    }
}

/// Implementación nativa iOS usando JSONL en Application Support
/// Formato simple, auditable, append-only para eventos.
/// Secrets (API keys) se almacenan en Keychain, no en disco.
public actor IOSPersistence: Persistence {
    private let fileManager = FileManager.default
    private let baseURL: URL
    private let conversationsDir: URL
    private let eventsDir: URL
    private let stateFile: URL
    private let configFile: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let jsonlEncoder = JSONEncoder()
    private let keychain = KeychainHelper.shared
    private let keychainPrefix = "apikey_"
    
    public init() throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseURL = appSupport.appendingPathComponent("IysCodeMovil", isDirectory: true)
        
        self.conversationsDir = baseURL.appendingPathComponent("conversations", isDirectory: true)
        self.eventsDir = baseURL.appendingPathComponent("events", isDirectory: true)
        self.stateFile = baseURL.appendingPathComponent("agent_state.json")
        self.configFile = baseURL.appendingPathComponent("config.json")
        
        try fileManager.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        jsonlEncoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - Conversations
    
    public func saveConversation(_ conversation: Conversation) async throws {
        var conv = conversation
        conv.updatedAt = Date()
        let file = conversationsDir.appendingPathComponent("\(conv.id).json")
        let data = try encoder.encode(conv)
        try data.write(to: file, options: .atomic)
    }
    
    public func loadConversation(id: String) async throws -> Conversation? {
        let file = conversationsDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try decoder.decode(Conversation.self, from: data)
    }
    
    public func listConversations() async throws -> [ConversationSummary] {
        let files = try fileManager.contentsOfDirectory(at: conversationsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var summaries: [ConversationSummary] = []
        
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let conv = try decoder.decode(Conversation.self, from: data)
                let previewText = conv.messages.last(where: {
                    ($0.role == .user || $0.role == .assistant)
                        && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })?.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                summaries.append(ConversationSummary(
                    id: conv.id,
                    title: conv.title,
                    createdAt: conv.createdAt,
                    updatedAt: conv.updatedAt,
                    messageCount: conv.messages.count,
                    lastMessagePreview: previewText.map { String($0.prefix(100)) }
                ))
            } catch {
                // Skip corrupted files
                continue
            }
        }
        
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    public func deleteConversation(id: String) async throws {
        let file = conversationsDir.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }
    
    // MARK: - Agent State
    
    public func saveAgentState(_ state: AgentState) async throws {
        let data = try encoder.encode(state)
        try data.write(to: stateFile, options: .atomic)
    }
    
    public func loadAgentState() async throws -> AgentState? {
        guard fileManager.fileExists(atPath: stateFile.path) else { return nil }
        let data = try Data(contentsOf: stateFile)
        return try decoder.decode(AgentState.self, from: data)
    }
    
    // MARK: - Configuration
    
    public func saveConfiguration(_ config: Configuration) async throws {
        // Configuration no contiene apiKeys: los secretos viven en Keychain
        // (saveAPIKey/loadAPIKey/deleteAPIKey), nunca en este JSON.
        let data = try encoder.encode(config)
        try data.write(to: configFile, options: .atomic)
    }

    public func loadConfiguration() async throws -> Configuration? {
        guard fileManager.fileExists(atPath: configFile.path) else { return nil }
        let data = try Data(contentsOf: configFile)
        return try decoder.decode(Configuration.self, from: data)
    }
    
    /// Guarda una API key en Keychain
    public func saveAPIKey(provider: String, key: String) async throws {
        try await keychain.save(key: keychainPrefix + provider, value: key)
    }
    
    /// Carga una API key desde Keychain
    public func loadAPIKey(provider: String) async throws -> String? {
        return try await keychain.load(key: keychainPrefix + provider)
    }
    
    /// Elimina una API key de Keychain
    public func deleteAPIKey(provider: String) async throws {
        try await keychain.delete(key: keychainPrefix + provider)
    }
    
    // MARK: - Events (JSONL append-only)
    
    public func appendEvent(_ event: AgentEvent) async throws {
        let dateStr: String = {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: event.timestamp)
        }()
        let file = eventsDir.appendingPathComponent("events_\(dateStr).jsonl")
        
        let data = try jsonlEncoder.encode(event)
        var line = String(data: data, encoding: .utf8)!
        line += "\n"
        
        if fileManager.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
            try handle.close()
        } else {
            try line.data(using: .utf8)!.write(to: file, options: .atomic)
        }
    }
    
    public func loadEvents(conversationId: String, since: Date?) async throws -> [AgentEvent] {
        let files = try fileManager.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var events: [AgentEvent] = []
        
        for file in files where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
            
            for line in lines {
                guard !line.isEmpty else { continue }
                do {
                    let event = try decoder.decode(AgentEvent.self, from: Data(line.utf8))
                    if event.conversationId == conversationId {
                        if let since = since, event.timestamp <= since { continue }
                        events.append(event)
                    }
                } catch {
                    continue // Skip corrupted lines
                }
            }
        }
        
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
import Foundation

/// Definición de una herramienta disponible para el agente
public struct AgentTool: Sendable, Codable {
    public let name: String
    public let description: String
    public let parameters: ToolSchema
    public let capabilities: ToolCapabilities
    
    public struct ToolSchema: Codable, Sendable {
        public var type: String = "object"
        public let properties: [String: PropertySchema]
        public let required: [String]
        
        public init(properties: [String: PropertySchema], required: [String], type: String = "object") {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }
    
    public struct PropertySchema: Codable, Sendable {
        public let type: String
        public let description: String?
        public let enumValues: [String]?
        
        public init(type: String, description: String?, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }
    
    public struct ToolCapabilities: Codable, Sendable {
        public var requiresNetwork: Bool = false
        public var requiresFileSystem: Bool = false
        public var isDestructive: Bool = false
        public var restrictions: [String] = []
        public var approvalReason: String? = nil
        public var requiresApprovalEveryTime: Bool = false
        
        public init(
            requiresNetwork: Bool = false,
            requiresFileSystem: Bool = false,
            isDestructive: Bool = false,
            restrictions: [String] = [],
            approvalReason: String? = nil,
            requiresApprovalEveryTime: Bool = false
        ) {
            self.requiresNetwork = requiresNetwork
            self.requiresFileSystem = requiresFileSystem
            self.isDestructive = isDestructive
            self.restrictions = restrictions
            self.approvalReason = approvalReason
            self.requiresApprovalEveryTime = requiresApprovalEveryTime
        }
    }
    
    public init(
        name: String,
        description: String,
        properties: [String: PropertySchema],
        required: [String] = [],
        capabilities: ToolCapabilities = ToolCapabilities()
    ) {
        self.name = name
        self.description = description
        self.parameters = ToolSchema(properties: properties, required: required)
        self.capabilities = capabilities
    }
}

/// Llamada a herramienta desde el modelo
public struct ToolInvocation: Codable, Sendable, Identifiable {
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

/// Resultado de ejecución de herramienta
public struct ToolExecutionResult: Codable, Sendable, Identifiable {
    public let id: String
    public let toolCallId: String
    public let output: String
    public let error: String?
    public let duration: TimeInterval
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        toolCallId: String,
        output: String,
        error: String? = nil,
        duration: TimeInterval
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.output = output
        self.error = error
        self.duration = duration
        self.timestamp = Date()
    }
}

/// Protocolo para ejecutor de herramientas
public protocol ToolExecutor: Sendable {
    var availableTools: [AgentTool] { get }
    func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool]
    func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult
    func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult
    func sharedContextForPrompt() async -> String?
}

public extension ToolExecutor {
    func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool] { availableTools }
    func sharedContextForPrompt() async -> String? { nil }
    func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        await execute(invocation)
    }
}

/// Contexto de ejecución del agente
public struct AgentContext: Sendable {
    public let conversationId: String
    public let workspace: any Workspace
    public let persistence: any Persistence
    public let modelProvider: any ModelProvider
    public let modelName: String?
    public let toolExecutor: any ToolExecutor
    public let systemPrompt: String?
    public let maxTurns: Int
    public let permissionHandler: (@Sendable (PermissionRequest) async -> PermissionResponse)?
    
    public init(
        conversationId: String,
        workspace: any Workspace,
        persistence: any Persistence,
        modelProvider: any ModelProvider,
        modelName: String? = nil,
        toolExecutor: any ToolExecutor,
        systemPrompt: String? = nil,
        maxTurns: Int = 10,
        permissionHandler: (@Sendable (PermissionRequest) async -> PermissionResponse)? = nil
    ) {
        self.conversationId = conversationId
        self.workspace = workspace
        self.persistence = persistence
        self.modelProvider = modelProvider
        self.modelName = modelName
        self.toolExecutor = toolExecutor
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
        self.permissionHandler = permissionHandler
    }
}

/// Solicitud de permiso para herramienta destructiva
public struct PermissionRequest: Codable, Sendable, Identifiable {
    public let id: String
    public let toolName: String
    public let toolDescription: String
    public let arguments: [String: String]
    public let reason: String
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        toolName: String,
        toolDescription: String,
        arguments: [String: String],
        reason: String
    ) {
        self.id = id
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.arguments = arguments
        self.reason = reason
        self.timestamp = Date()
    }
}

/// Respuesta de permiso
public struct PermissionResponse: Codable, Sendable {
    public let requestId: String
    public let decision: Decision
    public let timestamp: Date
    
    public enum Decision: String, Codable, Sendable {
        case allowOnce
        case allowAlways
        case deny
        case decline
        case cancel
    }
    
    public init(requestId: String, decision: Decision) {
        self.requestId = requestId
        self.decision = decision
        self.timestamp = Date()
    }
}

/// Eventos del loop del agente (para observabilidad)
public enum AgentLoopEvent: Sendable {
    case turnStarted(turn: Int)
    case modelRequest(messages: [ModelMessage])
    case modelDelta(String)
    case modelResponse(ModelResponse)
    case toolInvocation(ToolInvocation)
    case toolResult(ToolExecutionResult)
    case permissionRequested(PermissionRequest)
    case turnCompleted
    case error(Error)
    case finished(finalResponse: String)
}

/// Loop principal del agente
/// Ejecuta: user input → model → tool calls → results → model → response
public actor AgentLoop {
    private let context: AgentContext
    private var turnCount = 0
    private var currentConversation: Conversation?
    private var eventHandler: (@Sendable (AgentLoopEvent) async -> Void)?
    private var isRunning = false
    private var alwaysAllowedTools: Set<String> = []
    
    public init(context: AgentContext) {
        self.context = context
    }
    
    public func setEventHandler(_ handler: @escaping @Sendable (AgentLoopEvent) async -> Void) {
        self.eventHandler = handler
    }
    
    /// Ejecuta un turno completo del agente
    /// Retorna la respuesta final del asistente
    public func run(userInput: String) async throws -> String {
        guard !isRunning else {
            throw AgentError.toolError("AgentLoop already running")
        }
        isRunning = true
        defer { isRunning = false }
        
        // Cargar o crear conversación
        if currentConversation == nil {
            if let existing = try await context.persistence.loadConversation(id: context.conversationId) {
                currentConversation = existing
            } else {
                currentConversation = Conversation(id: context.conversationId)
            }
        }
        
        guard var conversation = currentConversation else {
            throw AgentError.noConversation
        }
        
        // Añadir mensaje del usuario
        let userMessage = Message(role: .user, content: userInput)
        conversation.messages.append(userMessage)
        currentConversation = conversation
        try await context.persistence.saveConversation(conversation)
        try await context.persistence.appendEvent(AgentEvent(conversationId: context.conversationId, type: .userInput, payload: ["content": userInput]))
        try await context.persistence.appendEvent(AgentEvent(
            conversationId: context.conversationId,
            type: .stateChange,
            payload: ["state": "user_input_received"]
        ))
        
        // Loop de turnos
        var finalResponse = ""
        
        for turn in 1...context.maxTurns {
            try Task.checkCancellation()
            turnCount = turn
            await eventHandler?(.turnStarted(turn: turn))
            
            // Construir mensajes para el modelo
            var messagesForModel = buildModelMessages(from: conversation)
            if let sharedContext = await context.toolExecutor.sharedContextForPrompt(), !sharedContext.isEmpty {
                let systemCount = messagesForModel.prefix { $0.role == .system }.count
                messagesForModel.insert(ModelMessage(role: .user, content: sharedContext), at: systemCount)
            }
            let modelMessages = ModelContextBudget.fit(
                messagesForModel,
                budget: ModelContextBudget.characterBudget(for: context.modelProvider.capabilities,
                                                           reservedOutputTokens: Self.maxOutputTokens)
            )
            
            await eventHandler?(.modelRequest(messages: modelMessages))
            
            // Persist model request event
            let requestPayload = try JSONEncoder().encode(modelMessages)
            try await context.persistence.appendEvent(AgentEvent(
                conversationId: context.conversationId,
                type: .modelRequest,
                payload: ["request": String(data: requestPayload, encoding: .utf8) ?? "[]"]
            ))
            
            // Llamar al modelo
            let turnTools = await context.toolExecutor.tools(relevantTo: modelMessages)
            let tools = turnTools.map { tool in
                ToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    parameters: ToolDefinition.ToolParameters(
                        properties: tool.parameters.properties.mapValues {
                            ToolDefinition.PropertySchema(
                                type: $0.type,
                                description: $0.description,
                                enumValues: $0.enumValues
                            )
                        },
                        required: tool.parameters.required
                    )
                )
            }
            
            let options = GenerationOptions(
                model: context.modelName,
                temperature: 0.7,
                maxTokens: Self.maxOutputTokens
            )
            
            let response = try await completeTurn(
                messages: modelMessages,
                tools: tools.isEmpty ? nil : tools,
                options: options
            )
            try Task.checkCancellation()

            await eventHandler?(.modelResponse(response))
            try await context.persistence.appendEvent(AgentEvent(
                conversationId: context.conversationId,
                type: .modelResponse,
                payload: [
                    "response": response.content,
                    "tool_call_count": String(response.toolCalls?.count ?? 0)
                ]
            ))
            
            // Añadir respuesta del modelo a la conversación
            var assistantMessage = Message(role: .assistant, content: response.content)
            
            // Si hay tool calls, ejecutarlos
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                assistantMessage = Message(
                    role: .assistant,
                    content: response.content,
                    toolCalls: toolCalls
                )
                conversation.messages.append(assistantMessage)
                currentConversation = conversation
                try await context.persistence.saveConversation(conversation)

                // Ejecutar cada tool call
                for toolCall in toolCalls {
                    let invocation = ToolInvocation(id: toolCall.id, name: toolCall.name, arguments: toolCall.arguments)
                    var toolApproval: PermissionResponse.Decision?
                    await eventHandler?(.toolInvocation(invocation))
                    
                    // Persist tool call event
                    try await context.persistence.appendEvent(AgentEvent(
                        conversationId: context.conversationId,
                        type: .toolCall,
                        payload: ["tool": toolCall.name, "arguments": toolCall.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")]
                    ))
                    
                    // Destructive tools are fail-closed unless explicitly allowed.
                    if let tool = turnTools.first(where: { $0.name == toolCall.name }),
                       tool.capabilities.isDestructive,
                       (tool.capabilities.requiresApprovalEveryTime || !alwaysAllowedTools.contains(tool.name)) {
                        try Task.checkCancellation()

                        let request = PermissionRequest(
                            toolName: tool.name,
                            toolDescription: tool.description,
                            arguments: toolCall.arguments,
                            reason: tool.capabilities.approvalReason ?? "This tool will modify files in your workspace. Are you sure you want to proceed?"
                        )

                        await eventHandler?(.permissionRequested(request))

                        guard let handler = context.permissionHandler else {
                            let deniedResult = ToolExecutionResult(
                                toolCallId: invocation.id,
                                output: "",
                                error: "Permission required but no permission handler is available",
                                duration: 0
                            )
                            await eventHandler?(.toolResult(deniedResult))
                            conversation.messages.append(Message(
                                role: .tool,
                                content: "error: \(deniedResult.error!)",
                                toolResults: [ToolResult(
                                    toolCallId: toolCall.id,
                                    output: "",
                                    error: deniedResult.error
                                )]
                            ))
                            currentConversation = conversation
                            try await context.persistence.saveConversation(conversation)
                            try await context.persistence.appendEvent(AgentEvent(
                                conversationId: context.conversationId,
                                type: .toolResult,
                                payload: ["tool": invocation.name, "output": "", "error": deniedResult.error ?? ""]
                            ))
                            continue
                        }

                        let permission = await handler(request)
                        try Task.checkCancellation()

                        guard permission.requestId == request.id else {
                            let deniedResult = ToolExecutionResult(
                                toolCallId: invocation.id,
                                output: "",
                                error: "Permission response did not match request",
                                duration: 0
                            )
                            await eventHandler?(.toolResult(deniedResult))
                            conversation.messages.append(Message(
                                role: .tool,
                                content: "error: \(deniedResult.error!)",
                                toolResults: [ToolResult(
                                    toolCallId: toolCall.id,
                                    output: "",
                                    error: deniedResult.error
                                )]
                            ))
                            currentConversation = conversation
                            try await context.persistence.saveConversation(conversation)
                            try await context.persistence.appendEvent(AgentEvent(
                                conversationId: context.conversationId,
                                type: .toolResult,
                                payload: ["tool": invocation.name, "output": "", "error": deniedResult.error ?? ""]
                            ))
                            continue
                        }

                        switch permission.decision {
                        case .deny, .decline, .cancel:
                            let deniedResult = ToolExecutionResult(
                                toolCallId: invocation.id,
                                output: "",
                                error: "Permission denied by user",
                                duration: 0
                            )
                            await eventHandler?(.toolResult(deniedResult))
                            conversation.messages.append(Message(
                                role: .tool,
                                content: "error: Permission denied by user",
                                toolResults: [ToolResult(
                                    toolCallId: toolCall.id,
                                    output: "",
                                    error: deniedResult.error
                                )]
                            ))
                            currentConversation = conversation
                            try await context.persistence.saveConversation(conversation)
                            try await context.persistence.appendEvent(AgentEvent(
                                conversationId: context.conversationId,
                                type: .toolResult,
                                payload: ["tool": invocation.name, "output": "", "error": deniedResult.error ?? ""]
                            ))
                            continue

                        case .allowOnce:
                            toolApproval = .allowOnce

                        case .allowAlways:
                            alwaysAllowedTools.insert(tool.name)
                            toolApproval = .allowAlways
                        }
                    }

                    try Task.checkCancellation()
                    let result = await context.toolExecutor.execute(invocation, approval: toolApproval)
                    
                    await eventHandler?(.toolResult(result))
                    
                    // Añadir resultado a la conversación como mensaje tool vinculado al tool_call_id original
                    let toolResultMsg = Message(
                        role: .tool,
                        content: result.error != nil ? "error: \(result.error!)" : (result.output.isEmpty ? "(empty)" : result.output),
                        toolResults: [ToolResult(
                            toolCallId: toolCall.id,
                            output: result.output,
                            error: result.error
                        )]
                    )
                    conversation.messages.append(toolResultMsg)
                    currentConversation = conversation
                    try await context.persistence.saveConversation(conversation)

                    try await context.persistence.appendEvent(AgentEvent(
                        conversationId: context.conversationId,
                        type: .toolResult,
                        payload: ["tool": invocation.name, "output": result.output, "error": result.error ?? ""]
                    ))
                }
                
                // Continuar el loop para que el modelo procese los resultados
                continue
            } else {
                // No hay tool calls, respuesta final
                finalResponse = response.content
                conversation.messages.append(Message(role: .assistant, content: finalResponse))
                currentConversation = conversation
                try await context.persistence.saveConversation(conversation)
                break
            }
        }
        
        if finalResponse.isEmpty {
            finalResponse = "Max turns reached without final response"
        }
        
        // Actualizar conversación en memoria ANTES de persistir
        currentConversation = conversation
        
        // Guardar conversación actualizada
        try await context.persistence.saveConversation(conversation)
        try await context.persistence.appendEvent(AgentEvent(
            conversationId: context.conversationId,
            type: .stateChange,
            payload: ["state": "finished"]
        ))
        
        await eventHandler?(.finished(finalResponse: finalResponse))
        
        return finalResponse
    }
    
    private func buildModelMessages(from conversation: Conversation) -> [ModelMessage] {
        var messages: [ModelMessage] = []
        
        // System prompt
        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            messages.append(ModelMessage(role: .system, content: systemPrompt))
        }
        
        // Historial de conversación
        for msg in conversation.messages {
            switch msg.role {
            case .user:
                messages.append(ModelMessage(role: .user, content: msg.content))
            case .assistant:
                let content = msg.content
                messages.append(ModelMessage(
                    role: .assistant,
                    content: content,
                    toolCalls: msg.toolCalls
                ))
            case .tool:
                if let toolResults = msg.toolResults {
                    for result in toolResults {
                        messages.append(ModelMessage(
                            role: .tool,
                            content: result.output.isEmpty ? (result.error ?? "") : result.output,
                            toolCallId: result.toolCallId
                        ))
                    }
                }
            case .system:
                messages.append(ModelMessage(role: .system, content: msg.content))
            }
        }
        
        return messages
    }

    /// Streams tokens when the provider can, and still returns the finished
    /// turn so tool calls keep working. A non-streaming provider is unchanged.
    private func completeTurn(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse {
        guard context.modelProvider.capabilities.streaming else {
            return try await context.modelProvider.generate(messages: messages, tools: tools, options: options)
        }

        var content = ""
        var toolSlots: [Int: (id: String, name: String, args: String)] = [:]
        let stream = context.modelProvider.generateStream(messages: messages, tools: tools, options: options)
        do {
            for try await chunk in stream {
                if let delta = chunk.delta, !delta.isEmpty {
                    content += delta
                    await eventHandler?(.modelDelta(delta))
                }
                if let call = chunk.toolCallDelta {
                    var slot = toolSlots[call.index] ?? (id: "", name: "", args: "")
                    if let id = call.id, !id.isEmpty { slot.id = id }
                    if let name = call.name, !name.isEmpty { slot.name = name }
                    if let args = call.arguments { slot.args += args }
                    toolSlots[call.index] = slot
                }
            }
        } catch {
            if content.isEmpty { throw error }
            throw error
        }

        let calls: [ToolCall] = toolSlots.keys.sorted().compactMap { index in
            guard let slot = toolSlots[index], !slot.name.isEmpty else { return nil }
            return ToolCall(
                id: slot.id.isEmpty ? "call_\(index)" : slot.id,
                name: slot.name,
                arguments: ToolArgumentDecoding.flatten(slot.args)
            )
        }
        return ModelResponse(content: content, toolCalls: calls.isEmpty ? nil : calls, finishReason: "stop")
    }

    static let maxOutputTokens = 2048
}

/// Errores del agente
public enum AgentError: Error, LocalizedError, Sendable {
    case noConversation
    case maxTurnsExceeded
    case modelError(String)
    case toolError(String)
    case persistenceError(String)
    
    public var errorDescription: String? {
        switch self {
        case .noConversation: return "No active conversation"
        case .maxTurnsExceeded: return "Maximum turns exceeded"
        case .modelError(let m): return "Model error: \(m)"
        case .toolError(let m): return "Tool error: \(m)"
        case .persistenceError(let m): return "Persistence error: \(m)"
        }
    }
}

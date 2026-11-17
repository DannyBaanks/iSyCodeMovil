import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Capabilities que un proveedor de modelos declara.
public struct ModelProviderCapabilities: Codable, Sendable {
    public let streaming: Bool
    public let toolCalls: Bool
    public let maxTokens: Int?
    public let maxContextTokens: Int?
    public let supportsSystemPrompt: Bool
    public let supportsImages: Bool
    public let localOnly: Bool // true = runs on-device (CoreML), false = remote API
    
    public let restrictions: [String]
    
    public init(
        streaming: Bool = false,
        toolCalls: Bool = false,
        maxTokens: Int? = nil,
        maxContextTokens: Int? = nil,
        supportsSystemPrompt: Bool = true,
        supportsImages: Bool = false,
        localOnly: Bool = false,
        restrictions: [String] = []
    ) {
        self.streaming = streaming
        self.toolCalls = toolCalls
        self.maxTokens = maxTokens
        self.maxContextTokens = maxContextTokens
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsImages = supportsImages
        self.localOnly = localOnly
        self.restrictions = restrictions
    }
}

/// Respuesta de un modelo
public struct ModelResponse: Codable, Sendable {
    public let content: String
    public let toolCalls: [ToolCall]?
    public let usage: Usage?
    public let finishReason: String?
    public let metadata: [String: String]
    
    public struct Usage: Codable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
    }
    
    public init(
        content: String,
        toolCalls: [ToolCall]? = nil,
        usage: Usage? = nil,
        finishReason: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.metadata = metadata
    }
}

/// Chunk de streaming
public struct ModelStreamChunk: Codable, Sendable {
    public let delta: String?
    public let toolCallDelta: ToolCallDelta?
    public let done: Bool
    public let finishReason: String?
    
    public struct ToolCallDelta: Codable, Sendable {
        public let index: Int
        public let id: String?
        public let name: String?
        public let arguments: String?
    }
}

/// Errores del proveedor
public enum ModelProviderError: Error, LocalizedError, Sendable {
    case notConfigured(String)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?, detail: String? = nil)
    /// One request is bigger than the account's per-minute token limit or the
    /// model's context. OpenAI answers this with a 429 too; waiting never helps.
    case requestTooLarge(provider: String, detail: String?)
    /// The account has no API credit or quota left (billing, not speed). Retrying will not help.
    case quotaExceeded(provider: String, detail: String?)
    case contextTooLarge(maxTokens: Int)
    case invalidRequest(String)
    case modelNotFound(String)
    case authenticationFailed
    case unsupportedFeature(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return "Provider not configured: \(m)"
        case .networkError(let m): return "Network error: \(m)"
        case .quotaExceeded(let provider, let detail):
            var text = "\(provider) rechazó la solicitud por falta de saldo o cuota en la cuenta de API. Revisa la facturación del proveedor; reintentar no lo arregla."
            if provider.localizedCaseInsensitiveContains("openai") {
                text += " Ojo: ChatGPT Plus/Pro (y el uso de Codex) no incluye crédito de OpenAI API; ese se compra aparte en platform.openai.com."
            }
            if let detail, !detail.isEmpty { text += " Detalle: \(detail)" }
            return text
        case .rateLimited(let retry, let detail):
            var text = "El proveedor limitó las solicitudes."
            if let retry, retry > 0 { text += " Intenta de nuevo en \(Int(ceil(retry))) s." } else { text += " Espera un momento antes de volver a intentar." }
            if let detail, !detail.isEmpty { text += " Detalle: \(detail)" }
            return text
        case .requestTooLarge(let provider, let detail):
            var text = "La solicitud es demasiado grande para \(provider) (límite de tokens por minuto o de contexto de tu cuenta). Esperar no lo arregla: empieza una sesión nueva o pide archivos más pequeños."
            if let detail, !detail.isEmpty { text += " Detalle: \(detail)" }
            return text
        case .contextTooLarge(let max): return "Context too large, max \(max) tokens"
        case .invalidRequest(let m): return "Invalid request: \(m)"
        case .modelNotFound(let m): return "Model not found: \(m)"
        case .authenticationFailed: return "El proveedor rechazó la clave de API (revisa que sea correcta y esté activa)."
        case .unsupportedFeature(let m): return "Unsupported feature: \(m)"
        }
    }
}

/// Protocolo para proveedores de modelos.
/// Abstracción que permite swapping entre remoto (API) y local (CoreML).
public protocol ModelProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var capabilities: ModelProviderCapabilities { get }
    var availableModels: [String] { get }
    
    func configure(_ config: ModelConfiguration) async throws
    func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse
    
    func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error>
}

/// Mensaje para el modelo
public struct ModelMessage: Codable, Sendable {
    public let role: Role
    public let content: String
    public let name: String? // for tool messages
    public let toolCallId: String? // for tool results
    public let toolCalls: [ToolCall]? // assistant tool_calls echo (history)
    public let metadata: [String: String]
    
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }
    
    public init(
        role: Role,
        content: String,
        name: String? = nil,
        toolCallId: String? = nil,
        toolCalls: [ToolCall]? = nil,
        metadata: [String: String] = [:]
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
        self.metadata = metadata
    }
}

/// Definición de herramienta (OpenAI function calling style)
public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: ToolParameters
    
    public struct ToolParameters: Codable, Sendable {
        public let type: String
        public let properties: [String: PropertySchema]
        public let required: [String]

        public init(type: String = "object", properties: [String: PropertySchema], required: [String]) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }
    
    public struct PropertySchema: Codable, Sendable {
        public let type: String
        public let description: String?
        public let enumValues: [String]?
    }
}

/// Opciones de generación
public struct GenerationOptions: Codable, Sendable {
    public let model: String?
    public let temperature: Double?
    public let maxTokens: Int?
    public let topP: Double?
    public let stopSequences: [String]?
    public let seed: Int?
    
    public init(
        model: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        seed: Int? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.stopSequences = stopSequences
        self.seed = seed
    }
}

/// Configuración del proveedor
public struct ModelConfiguration: Codable, Sendable {
    public let apiKey: String?
    public let baseURL: String?
    public let organization: String?
    public let timeout: TimeInterval
    public let extraHeaders: [String: String]
    
    public init(
        apiKey: String? = nil,
        baseURL: String? = nil,
        organization: String? = nil,
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.organization = organization
        self.timeout = timeout
        self.extraHeaders = extraHeaders
    }
}

/// Proveedor remoto genérico (OpenAI-compatible API)
/// Compatible con OpenAI, Anthropic (via proxy), Ollama, vLLM, etc.
public actor RemoteModelProvider: @preconcurrency ModelProvider {
    public let id: String
    public let name: String
    public let capabilities: ModelProviderCapabilities
    public private(set) var availableModels: [String] = []
    
    private var config: ModelConfiguration?
    private let session: URLSession
    
    public init(id: String = "remote", name: String = "Remote API") {
        self.id = id
        self.name = name
        self.capabilities = ModelProviderCapabilities(
            streaming: true,
            toolCalls: true,
            maxTokens: 4096,
            maxContextTokens: 128000,
            supportsSystemPrompt: true,
            supportsImages: false,
            localOnly: false,
            restrictions: [
                "Requires network connectivity",
                "API key required",
                "Latency depends on network",
                "Cost per token",
                "Rate limits apply"
            ]
        )
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    public func configure(_ config: ModelConfiguration) async throws {
        self.config = config
        // Try to fetch available models
        try await fetchModels()
    }
    
    private func endpoint(_ path: String) -> URL? {
        guard var base = config?.baseURL, !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    private func fetchModels() async throws {
        guard let config = config, let url = endpoint("/models") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            // The model list is optional. Leave it empty so a failed /models
            // call does not pretend the account has a catalog it never returned.
            self.availableModels = []
            return
        }
        // A rejected key is reported now, not as a vague failure on the first message.
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            self.availableModels = []
            throw ModelProviderError.authenticationFailed
        }
        if let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let dataArray = json["data"] as? [[String: Any]] {
            self.availableModels = dataArray.compactMap { $0["id"] as? String }
        } else {
            self.availableModels = []
        }
    }
    
    // MARK: Retries

    /// Retries per request after the first attempt, like the official SDKs.
    static let maxRetries = 3
    /// A Retry-After longer than this is surfaced instead of silently waited out.
    static let maxRetryWait: TimeInterval = 20

    /// Rate limits and 5xx are transient and retried with backoff. Billing,
    /// oversized requests and bad keys fail at once: retrying cannot fix them.
    static func retryDelay(after error: ModelProviderError, attempt: Int) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }
        switch error {
        case .rateLimited(let retryAfter, _):
            if let retryAfter { return retryAfter <= maxRetryWait ? max(retryAfter, 0.5) : nil }
            return backoff(attempt)
        case .networkError(let message) where message.hasPrefix("HTTP 5"):
            return backoff(attempt)
        default:
            return nil
        }
    }

    static func backoff(_ attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt)), 8) + Double.random(in: 0..<0.5)
    }

    private static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse {
        guard config != nil else {
            throw ModelProviderError.notConfigured("Call configure() first")
        }
        
        let reverseNames = Self.reverseToolNameMap(from: tools)
        let request = try buildRequest(messages: messages, tools: tools, options: options, stream: false)
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            do {
                try checkResponse(response, body: data)
            } catch let error as ModelProviderError {
                guard let delay = Self.retryDelay(after: error, attempt: attempt) else { throw error }
                attempt += 1
                try await Self.sleep(delay)
                continue
            }
            return try parseResponse(data, reverseNames: reverseNames)
        }
    }
    
    public func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(UIKit) || canImport(AppKit) || os(Linux)
            let task = Task {
                do {
                    guard config != nil else {
                        throw ModelProviderError.notConfigured("Call configure() first")
                    }
                    
                    let reverseNames = Self.reverseToolNameMap(from: tools)
                    let request = try buildRequest(messages: messages, tools: tools, options: options, stream: true)
                    var attempt = 0
                    var opened: URLSession.AsyncBytes?
                    while opened == nil {
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
                            opened = bytes
                            break
                        }
                        // Read the error body (bounded) so the real reason reaches the user.
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 64 * 1024 { break }
                        }
                        do {
                            try checkResponse(response, body: body)
                        } catch let error as ModelProviderError {
                            // Nothing was streamed yet, so retrying is invisible to the user.
                            guard let delay = Self.retryDelay(after: error, attempt: attempt) else { throw error }
                            attempt += 1
                            try await Self.sleep(delay)
                        }
                    }
                    guard let bytes = opened else { throw ModelProviderError.networkError("No response from the provider") }
                    
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if jsonStr == "[DONE]" {
                            continuation.yield(ModelStreamChunk(delta: nil, toolCallDelta: nil, done: true, finishReason: "stop"))
                            break
                        }
                        let data = Data(jsonStr.utf8)
                        if let chunk = try? Self.openAIDecoder.decode(StreamChunkResponse.self, from: data) {
                            guard let choice = chunk.choices.first else { continue }
                            let calls = choice.delta.toolCalls ?? []
                            continuation.yield(ModelStreamChunk(
                                delta: choice.delta.content,
                                toolCallDelta: calls.first.map { Self.toolCallDelta($0, reverseNames: reverseNames) },
                                done: false,
                                finishReason: choice.finishReason
                            ))
                            // Parallel tool calls can share a chunk; keep every one.
                            for extra in calls.dropFirst() {
                                continuation.yield(ModelStreamChunk(delta: nil, toolCallDelta: Self.toolCallDelta(extra, reverseNames: reverseNames),
                                                                    done: false, finishReason: nil))
                            }
                        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  object["error"] != nil {
                            // Providers report mid-stream failures as a data event.
                            let info = Self.providerErrorInfo(from: data)
                            throw ModelProviderError.networkError("El proveedor cortó la respuesta: \(info.message ?? String(jsonStr.prefix(300)))")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            // Streaming via URLSession.bytes is unavailable on this platform toolchain
            // (e.g. Swift CoreLibs FoundationNetworking on Windows). Non-streaming generate() works.
            continuation.finish(throwing: ModelProviderError.unsupportedFeature("streaming not supported on this host toolchain"))
            #endif
        }
    }

    private static func toolCallDelta(_ call: StreamChunkResponse.StreamChoice.StreamToolCall, reverseNames: [String: String]) -> ModelStreamChunk.ToolCallDelta {
        let resolvedName = call.function?.name.map { reverseNames[$0] ?? $0 }
        return ModelStreamChunk.ToolCallDelta(index: call.index, id: call.id, name: resolvedName, arguments: call.function?.arguments)
    }

    static func openAIFunctionName(for toolName: String) -> String {
        toolName.replacingOccurrences(of: ".", with: "__")
    }

    static func reverseToolNameMap(from tools: [ToolDefinition]?) -> [String: String] {
        guard let tools else { return [:] }
        var map: [String: String] = [:]
        for tool in tools {
            let sanitized = openAIFunctionName(for: tool.name)
            if sanitized != tool.name {
                map[sanitized] = tool.name
            }
        }
        return map
    }

    /// OpenAI reasoning models (o-series, GPT-5) reject `max_tokens` and any
    /// temperature other than the default. `gpt-5-chat-*` is not a reasoning model.
    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let id = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if id.hasPrefix("gpt-5") { return !id.contains("chat") }
        return id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }
    
    private func buildRequest(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions, stream: Bool) throws -> URLRequest {
        guard let config = config, let url = endpoint("/chat/completions") else {
            throw ModelProviderError.invalidRequest("Invalid base URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        config.extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        
        let model = options.model ?? availableModels.first ?? "gpt-4o-mini"
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { msg in
                var m: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
                if let name = msg.name { m["name"] = Self.openAIFunctionName(for: name) }
                if let toolCallId = msg.toolCallId { m["tool_call_id"] = toolCallId }
                // Echo assistant tool_calls back into history (OpenAI requires this for multi-turn tool use)
                if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    m["tool_calls"] = toolCalls.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": Self.openAIFunctionName(for: tc.name),
                                "arguments": (try? jsonString(from: tc.arguments)) ?? "{}"
                            ]
                        ] as [String: Any]
                    }
                }
                return m
            },
            "stream": stream
        ]
        
        let isOpenAI = url.host?.lowercased() == "api.openai.com"
        let reasoning = isOpenAI && Self.isOpenAIReasoningModel(model)
        if !reasoning {
            if let temp = options.temperature { body["temperature"] = temp }
            if let topP = options.topP { body["top_p"] = topP }
        }
        if let maxTokens = options.maxTokens {
            if isOpenAI {
                // Reasoning tokens count against this budget; leave room for the answer.
                body["max_completion_tokens"] = reasoning ? max(maxTokens, 8192) : maxTokens
            } else {
                body["max_tokens"] = maxTokens
            }
        }
        if let stop = options.stopSequences { body["stop"] = stop }
        if let seed = options.seed { body["seed"] = seed }
        
        if let tools = tools {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": Self.openAIFunctionName(for: tool.name),
                        "description": tool.description,
                        "parameters": [
                            "type": tool.parameters.type,
                            "properties": tool.parameters.properties.mapValues { prop in
                                var p: [String: Any] = ["type": prop.type]
                                if let desc = prop.description { p["description"] = desc }
                                if let enumV = prop.enumValues { p["enum"] = enumV }
                                return p
                            },
                            "required": tool.parameters.required
                        ]
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    
    private func checkResponse(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw Self.classifyHTTPError(status: http.statusCode,
                                     retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                     body: body, provider: name)
    }

    /// Turns an HTTP error into a precise error using the provider's JSON body.
    /// A 429 is often not "too many requests": OpenAI, Gemini and others also use
    /// it for an account without API credit (`insufficient_quota`), which no
    /// amount of waiting fixes. OpenRouter uses 402 for the same thing.
    static func classifyHTTPError(status: Int, retryAfter: String?, body: Data, provider: String) -> ModelProviderError {
        let info = providerErrorInfo(from: body)
        let detail = info.message.map { String($0.prefix(300)) }
        let haystack = [info.code, info.type, info.status, info.message].compactMap { $0?.lowercased() }.joined(separator: " ")
        let billing = ["insufficient_quota", "insufficient credits", "insufficient_credits", "exceeded your current quota",
                       "billing", "credit balance", "payment required", "out of credits", "no credits"]
        if status == 402 || billing.contains(where: haystack.contains) {
            return .quotaExceeded(provider: provider, detail: detail)
        }
        // OpenAI: 429 "Request too large for gpt-4o … on tokens per min (TPM)";
        // 400 context_length_exceeded; Anthropic-style 413 request_too_large.
        let tooLarge = ["request too large", "context_length_exceeded", "request_too_large", "maximum context length"]
        if status == 413 || tooLarge.contains(where: haystack.contains) {
            return .requestTooLarge(provider: provider, detail: detail)
        }
        switch status {
        case 401, 403:
            return .authenticationFailed
        case 404 where haystack.contains("model"):
            return .modelNotFound(detail ?? "HTTP 404")
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap(Self.retryDelay), detail: detail)
        case 400..<500:
            return .invalidRequest(detail.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        default:
            return .networkError(detail.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        }
    }

    struct ProviderErrorInfo { var message: String?; var code: String?; var type: String?; var status: String? }

    /// Understands `{"error": {...}}` (OpenAI, xAI, OpenRouter, NVIDIA), Gemini's
    /// `[{"error": {...}}]`, and `{"message": ...}` / `{"detail": ...}`.
    static func providerErrorInfo(from body: Data) -> ProviderErrorInfo {
        var json = try? JSONSerialization.jsonObject(with: body)
        if let array = json as? [Any] { json = array.first }
        guard let root = json as? [String: Any] else {
            let text = String(data: body.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderErrorInfo(message: (text?.isEmpty == false) ? text : nil)
        }
        let error = (root["error"] as? [String: Any]) ?? root
        func string(_ value: Any?) -> String? {
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return nil
        }
        return ProviderErrorInfo(
            message: string(error["message"]) ?? string(root["error"]) ?? string(root["detail"]) ?? string(root["message"]),
            code: string(error["code"]),
            type: string(error["type"]),
            status: string(error["status"])
        )
    }

    private static func retryDelay(from header: String) -> TimeInterval? {
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
    
    private static let openAIDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func parseResponse(_ data: Data, reverseNames: [String: String] = [:]) throws -> ModelResponse {
        let decoded = try Self.openAIDecoder.decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw ModelProviderError.invalidRequest("No choices in response")
        }
        
        let toolCalls = choice.message.toolCalls?.map { tc in
            // Function arguments arrive as a JSON string; decode to [String:String] for our contract.
            let args = decodeArguments(tc.function.arguments)
            let resolvedName = reverseNames[tc.function.name] ?? tc.function.name
            return ToolCall(id: tc.id, name: resolvedName, arguments: args)
        }
        
        let usage = decoded.usage.map { u in
            ModelResponse.Usage(promptTokens: u.promptTokens, completionTokens: u.completionTokens, totalTokens: u.totalTokens)
        }
        
        return ModelResponse(
            content: choice.message.content ?? "",
            toolCalls: toolCalls,
            usage: usage,
            finishReason: choice.finishReason,
            metadata: [:]
        )
    }
}

/// Decode a model-provided JSON arguments string into a flat [String:String] dict.
/// Returns empty dict on parse failure or non-object payload.
private func decodeArguments(_ json: String) -> [String:String] {
    ToolArgumentDecoding.flatten(json)
}

/// Tool arguments arrive as JSON; the tool contract is a flat string map.
enum ToolArgumentDecoding {
    static func flatten(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj.mapValues(Self.string)
    }

    /// JSON booleans decode as NSNumber, so `true` used to become "1" and every
    /// `recursive: true` was read as false. Nested values stay JSON, not Swift dumps.
    static func string(_ value: Any) -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            if String(cString: number.objCType) == "c" { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let flag as Bool:
            return flag ? "true" : "false"
        case is NSNull:
            return ""
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "\(value)"
        }
    }
}

/// Serialize a flat [String:String] back to a JSON object string for the API.
private func jsonString(from dict: [String:String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Response decoding

private struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    let usage: Usage?
    
    struct Choice: Codable {
        let message: Message
        let finishReason: String?
        
        struct Message: Codable {
            let content: String?
            let toolCalls: [ToolCallResponse]?
        }
        
        struct ToolCallResponse: Codable {
            let id: String
            let function: Function
            
            struct Function: Codable {
                let name: String
                let arguments: String
            }
        }
    }
    
    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }
}

private struct StreamChunkResponse: Codable {
    let choices: [StreamChoice]
    
    struct StreamChoice: Codable {
        let delta: Delta
        let finishReason: String?
        
        struct Delta: Codable {
            let content: String?
            let toolCalls: [StreamToolCall]?
        }
        
        struct StreamToolCall: Codable {
            let index: Int
            let id: String?
            let function: StreamFunction?
            
            struct StreamFunction: Codable {
                let name: String?
                let arguments: String?
            }
        }
    }
}

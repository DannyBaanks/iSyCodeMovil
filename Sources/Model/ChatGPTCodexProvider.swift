import Foundation

/// Calls ChatGPT's Codex Responses API (`chatgpt.com/backend-api/codex/responses`) using the user's
/// ChatGPT Plus/Pro OAuth subscription tokens instead of a pay-per-token OpenAI API key.
/// Model list is discovered dynamically from `chatgpt.com/backend-api/codex/models`.
public actor ChatGPTCodexProvider: @preconcurrency ModelProvider {
    public let id = "chatgpt-oauth"
    public let name = "ChatGPT Plus/Pro (OAuth)"
    public let capabilities = ModelProviderCapabilities(
        streaming: true,
        toolCalls: true,
        maxTokens: 16384,
        maxContextTokens: 200000,
        supportsSystemPrompt: true,
        supportsImages: false,
        localOnly: false,
        restrictions: ["Usa tu suscripción ChatGPT Plus/Pro", "Requiere conexión a internet"]
    )
    public private(set) var availableModels: [String] = []

    private static let modelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=0.1.0")!
    private static let responsesEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    public func configure(_ config: ModelConfiguration) async throws {
        let creds = try await ChatGPTOAuthStore.validCredentials()
        let discovered = try await fetchAvailableModels(creds: creds)
        if !discovered.isEmpty {
            availableModels = discovered
            await ChatGPTOAuthStore.updateCachedModels(discovered)
        }
    }

    private func fetchAvailableModels(creds: (accessToken: String, accountID: String)) async throws -> [String] {
        let candidates = [
            Self.modelsEndpoint,
            URL(string: "https://chatgpt.com/backend-api/codex/models")!
        ]
        var lastError = ""
        for endpoint in candidates {
            var req = URLRequest(url: endpoint, timeoutInterval: 20)
            req.httpMethod = "GET"
            req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            if !creds.accountID.isEmpty {
                req.setValue(creds.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            req.setValue("codex_cli_rs/0.1.0", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                lastError = "HTTP \(http.statusCode): \(body)"
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                lastError = "HTTP \(http.statusCode): \(body)"
                continue
            }
            if let slugs = Self.extractModelSlugs(from: data), !slugs.isEmpty {
                return slugs
            }
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            lastError = "Formato inesperado: \(preview)"
        }
        await ChatGPTOAuthStore.setDiscoveryError(lastError.isEmpty ? "Sin modelos devueltos." : lastError)
        throw ModelProviderError.networkError("No pude listar modelos de ChatGPT Codex (\(lastError)).")
    }

    private static func extractModelSlugs(from data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [[String: Any]]
        if let dict = root as? [String: Any] {
            if let m = dict["models"] as? [[String: Any]] {
                list = m
            } else if let d = dict["data"] as? [[String: Any]] {
                list = d
            } else {
                return nil
            }
        } else if let arr = root as? [[String: Any]] {
            list = arr
        } else {
            return nil
        }

        var slugs: [String] = []
        for item in list {
            if let visibility = item["visibility"] as? String, visibility == "hide" || visibility == "hidden" {
                continue
            }
            if let slug = (item["slug"] as? String) ?? (item["id"] as? String) ?? (item["name"] as? String),
               !slug.isEmpty, !slugs.contains(slug) {
                slugs.append(slug)
            }
        }
        if slugs.isEmpty {
            for item in list {
                if let slug = (item["slug"] as? String) ?? (item["id"] as? String) ?? (item["name"] as? String),
                   !slug.isEmpty, !slugs.contains(slug) {
                    slugs.append(slug)
                }
            }
        }
        return slugs
    }

    public func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse {
        var text = ""
        var callsByIndex: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await chunk in generateStream(messages: messages, tools: tools, options: options) {
            if let delta = chunk.delta {
                text += delta
            }
            if let tc = chunk.toolCallDelta {
                var current = callsByIndex[tc.index] ?? (id: tc.id ?? UUID().uuidString, name: tc.name ?? "", args: "")
                if let id = tc.id, !id.isEmpty { current.id = id }
                if let name = tc.name, !name.isEmpty { current.name = name }
                if let args = tc.arguments { current.args += args }
                callsByIndex[tc.index] = current
            }
            if let reason = chunk.finishReason {
                finishReason = reason
            }
        }

        let toolCalls: [ToolCall] = callsByIndex.keys.sorted().compactMap { idx in
            guard let item = callsByIndex[idx], !item.name.isEmpty else { return nil }
            return ToolCall(id: item.id, name: item.name, arguments: Self.parseArguments(item.args))
        }
        return ModelResponse(
            content: text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            usage: nil,
            finishReason: finishReason ?? (toolCalls.isEmpty ? "stop" : "tool_calls")
        )
    }

    public func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let creds = try await ChatGPTOAuthStore.validCredentials()
                    var selectedModel = options.model ?? availableModels.first
                    if selectedModel == nil || selectedModel?.isEmpty == true {
                        let fetched = try await fetchAvailableModels(creds: creds)
                        if !fetched.isEmpty {
                            availableModels = fetched
                            await ChatGPTOAuthStore.updateCachedModels(fetched)
                            selectedModel = fetched.first
                        }
                    }
                    guard let model = selectedModel, !model.isEmpty else {
                        throw ModelProviderError.modelNotFound("ChatGPT Codex no devolvió ningún modelo disponible para tu cuenta.")
                    }

                    var req = URLRequest(url: Self.responsesEndpoint, timeoutInterval: 90)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
                    if !creds.accountID.isEmpty {
                        req.setValue(creds.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                    }
                    req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
                    req.setValue("codex_cli_rs/0.1.0", forHTTPHeaderField: "User-Agent")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (payload, reverseMap) = try Self.buildPayload(model: model, messages: messages, tools: tools)
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ModelProviderError.networkError("Respuesta HTTP inválida de ChatGPT Codex.")
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw ModelProviderError.authenticationFailed
                    }
                    if http.statusCode == 429 {
                        throw ModelProviderError.rateLimited(retryAfter: nil, detail: "Límite de suscripción ChatGPT alcanzado.")
                    }
                    if http.statusCode >= 400 {
                        var errBody = ""
                        for try await line in bytes.lines {
                            errBody += line
                            if errBody.count > 1000 { break }
                        }
                        throw ModelProviderError.invalidRequest("ChatGPT OAuth (\(http.statusCode)): \(errBody)")
                    }

                    var nextToolIndex = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        switch type {
                        case "response.output_text.delta":
                            if let delta = event["delta"] as? String, !delta.isEmpty {
                                continuation.yield(ModelStreamChunk(delta: delta, toolCallDelta: nil, done: false, finishReason: nil))
                            }
                        case "response.output_item.done":
                            if let item = event["item"] as? [String: Any],
                               (item["type"] as? String) == "function_call",
                               let rawName = item["name"] as? String {
                                let name = reverseMap[rawName] ?? rawName
                                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                                let argsStr = (item["arguments"] as? String) ?? "{}"
                                let tcDelta = ModelStreamChunk.ToolCallDelta(index: nextToolIndex, id: callID, name: name, arguments: argsStr)
                                nextToolIndex += 1
                                continuation.yield(ModelStreamChunk(delta: nil, toolCallDelta: tcDelta, done: false, finishReason: nil))
                            }
                        case "response.completed":
                            let reason = nextToolIndex > 0 ? "tool_calls" : "stop"
                            continuation.yield(ModelStreamChunk(delta: nil, toolCallDelta: nil, done: true, finishReason: reason))
                        case "error", "response.failed":
                            let msg = (event["message"] as? String)
                                ?? ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                                ?? "Error en ChatGPT Codex."
                            throw ModelProviderError.networkError(msg)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Payload mapping

    private static func sanitizeToolName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "__")
    }

    private static func buildPayload(
        model: String,
        messages: [ModelMessage],
        tools: [ToolDefinition]?
    ) throws -> ([String: Any], [String: String]) {
        var systemParts: [String] = []
        var inputItems: [[String: Any]] = []
        var nameToWire: [String: String] = [:]
        var wireToName: [String: String] = [:]

        if let tools {
            for t in tools {
                let wire = sanitizeToolName(t.name)
                nameToWire[t.name] = wire
                wireToName[wire] = t.name
            }
        }

        for msg in messages {
            switch msg.role {
            case .system:
                if !msg.content.isEmpty { systemParts.append(msg.content) }
            case .user:
                inputItems.append([
                    "type": "message",
                    "role": "user",
                    "content": msg.content
                ])
            case .assistant:
                if !msg.content.isEmpty {
                    inputItems.append([
                        "type": "message",
                        "role": "assistant",
                        "content": msg.content
                    ])
                }
                if let calls = msg.toolCalls {
                    for call in calls {
                        let wire = nameToWire[call.name] ?? sanitizeToolName(call.name)
                        let argsData = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data("{}".utf8)
                        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                        inputItems.append([
                            "type": "function_call",
                            "call_id": call.id,
                            "name": wire,
                            "arguments": argsJSON
                        ])
                    }
                }
            case .tool:
                inputItems.append([
                    "type": "function_call_output",
                    "call_id": msg.toolCallId ?? UUID().uuidString,
                    "output": msg.content
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "instructions": systemParts.isEmpty ? "You are a helpful coding assistant." : systemParts.joined(separator: "\n\n"),
            "input": inputItems,
            "store": false,
            "stream": true
        ]

        if let tools, !tools.isEmpty {
            var encodedTools: [[String: Any]] = []
            for t in tools {
                let wire = nameToWire[t.name] ?? sanitizeToolName(t.name)
                var props: [String: Any] = [:]
                for (pName, pDef) in t.parameters.properties {
                    var propObj: [String: Any] = ["type": pDef.type, "description": pDef.description ?? ""]
                    if let enums = pDef.enumValues { propObj["enum"] = enums }
                    props[pName] = propObj
                }
                encodedTools.append([
                    "type": "function",
                    "name": wire,
                    "description": t.description,
                    "parameters": [
                        "type": "object",
                        "properties": props,
                        "required": t.parameters.required
                    ]
                ])
            }
            body["tools"] = encodedTools
            body["tool_choice"] = "auto"
        }
        return (body, wireToName)
    }

    private static func parseArguments(_ jsonString: String) -> [String: String] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String {
                out[k] = s
            } else if let n = v as? NSNumber {
                out[k] = n.stringValue
            } else if let b = v as? Bool {
                out[k] = b ? "true" : "false"
            } else if let d = try? JSONSerialization.data(withJSONObject: v),
                      let s = String(data: d, encoding: .utf8) {
                out[k] = s
            }
        }
        return out
    }
}

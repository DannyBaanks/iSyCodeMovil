import Foundation

/// Proveedor de modelo **determinista y offline**: no usa red ni API key.
///
/// Su propósito es permitir que el runtime nativo alternativo (el
/// `AgentLoop` Swift de este proyecto) ejecute una sesión completa
/// end-to-end **sin dependencias externas**, para fines de DEMO y tests.
///
/// El script es una secuencia de respuestas prefijadas. Si el modelo termina
/// las respuestas sin tool calls, el AgentLoop toma la última como final.
///
/// No pretende ser OpenCode ni imitarlo. Sustituye la dependencia de red
/// para que el experimento sea **reproducible y autosuficiente**.
public actor ScriptedModelProvider: @preconcurrency ModelProvider {
    public let id = "scripted"
    public let name = "Scripted (offline)"
    public let capabilities = ModelProviderCapabilities(
        streaming: false,
        toolCalls: true,
        maxTokens: 2048,
        maxContextTokens: 8192,
        supportsSystemPrompt: true,
        supportsImages: false,
        localOnly: true,
        restrictions: ["Determinista", "Sin red", "Para tests y demo offline"]
    )
    public let availableModels: [String] = ["scripted-1"]

    private var script: [ModelResponse]
    private var cursor = 0

    public init(script: [ModelResponse]) {
        self.script = script
    }

    public init(scriptResponses: [String]) {
        self.script = scriptResponses.map { ModelResponse(content: $0) }
    }

    public func configure(_ config: ModelConfiguration) async throws {
        // No-op: no requiere configuración.
    }

    public func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse {
        if cursor >= script.count, !script.isEmpty, messages.last?.role == .user {
            // Un turno nuevo con el guion agotado lo repite desde el principio: la demo
            // sigue mostrando el flujo completo en vez de una sola línea por mensaje.
            cursor = 0
        }
        guard cursor < script.count else {
            // A mitad de turno y sin guion: cerrar el loop con un final legible.
            return ModelResponse(content: "Fin del guion de demo. Elige un proveedor para hablar con un modelo real.")
        }
        let resp = script[cursor]
        cursor += 1
        return resp
    }

    public func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ModelProviderError.unsupportedFeature("scripted provider does not stream"))
        }
    }

    /// Crea un script clásico de demo: lista, lee, modifica, lee de nuevo.
    public static func demoScript() -> [ModelResponse] {
        [
            ModelResponse(
                content: "Voy a listar el workspace para ver qué hay.",
                toolCalls: [ToolCall(id: "call_1", name: "list_directory", arguments: ["path": ""])]
            ),
            ModelResponse(
                content: "Voy a crear `notes.txt` con un contenido inicial para el experimento.",
                toolCalls: [ToolCall(id: "call_2", name: "write_file", arguments: ["path": "notes.txt", "content": "OpenCodeNative demo line 1\n"])]
            ),
            ModelResponse(
                content: "Releo `notes.txt` para confirmar el contenido escrito.",
                toolCalls: [ToolCall(id: "call_3", name: "read_file", arguments: ["path": "notes.txt"])]
            ),
            ModelResponse(
                content: "Añado una segunda línea reescribiendo el archivo.",
                toolCalls: [ToolCall(id: "call_4", name: "write_file", arguments: ["path": "notes.txt", "content": "OpenCodeNative demo line 1\nOpenCodeNative demo line 2\n"])]
            ),
            ModelResponse(
                content: "Verifico el resultado definitivo.",
                toolCalls: [ToolCall(id: "call_5", name: "read_file", arguments: ["path": "notes.txt"])]
            ),
            ModelResponse(
                content: "Hecho. Demostrado el flujo agente → tools → workspace → resultado de forma nativa en iOS, sin red."
            )
        ]
    }
}

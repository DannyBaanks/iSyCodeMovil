import Foundation

public struct SandboxModelProvider: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let keyPlaceholder: String
    public let baseURL: String
    public let preferredModels: [String]
    public let fallbackModel: String
    public let apiKeyURL: URL
    public let supportsGoogleOAuth: Bool
    public let curatedOnly: Bool

    public static let gusLocal = SandboxModelProvider(
        id: "gus-local", name: "GUS local · Qwen 1.5",
        description: "Modelo Qwen fijado y ejecutado en este iPhone. No requiere API key ni envía prompts a un proveedor remoto.",
        keyPlaceholder: "", baseURL: "", preferredModels: ["qwen1.5-1.8b-chat-q4_k_m"], fallbackModel: "qwen1.5-1.8b-chat-q4_k_m",
        apiKeyURL: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/tree/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b")!
    )

    public static let all: [SandboxModelProvider] = [
        .init(id: "nvidia", name: "NVIDIA NIM", description: "Modelos NVIDIA y modelos abiertos servidos por NIM.",
              keyPlaceholder: "nvapi-…", baseURL: "https://integrate.api.nvidia.com/v1",
              preferredModels: [
                  "nvidia/nemotron-3-ultra-550b-a55b",
                  "minimaxai/minimax-m3.1-flash",
                  "stepfun-ai/step-5-preview",
                  "nvidia/nemotron-3.5-super-vl-120b-a12b",
                  "mistralai/mistral-large-4-1t-a52b"
              ],
              fallbackModel: "nvidia/nemotron-3-ultra-550b-a55b",
              apiKeyURL: URL(string: "https://build.nvidia.com/settings/api-keys")!,
              curatedOnly: true),
        .init(id: "xai", name: "xAI · Grok", description: "API de xAI compatible con OpenAI.",
              keyPlaceholder: "xai-…", baseURL: "https://api.x.ai/v1",
              preferredModels: ["grok-4.7", "grok-4.6", "grok-4.5", "grok-4"], fallbackModel: "grok-4.7",
              apiKeyURL: URL(string: "https://console.x.ai/")!),
        .init(id: "openai", name: "OpenAI API", description: "GPT mediante API. La suscripción de ChatGPT no incluye crédito de API.",
              keyPlaceholder: "sk-…", baseURL: "https://api.openai.com/v1",
              preferredModels: ["gpt-4o", "gpt-4o-mini"], fallbackModel: "gpt-4o",
              apiKeyURL: URL(string: "https://platform.openai.com/api-keys")!),
        .init(id: "gemini", name: "Google Gemini", description: "Gemini API con clave de AI Studio; OAuth requiere configurar un cliente de Google Cloud.",
              keyPlaceholder: "AIza…", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
              preferredModels: ["gemini-3.8-flash", "gemini-2.5-flash"], fallbackModel: "gemini-3.8-flash",
              apiKeyURL: URL(string: "https://aistudio.google.com/app/apikey")!, supportsGoogleOAuth: true),
        .init(id: "openrouter", name: "OpenRouter", description: "Un endpoint para modelos de varios proveedores.",
              keyPlaceholder: "sk-or-…", baseURL: "https://openrouter.ai/api/v1",
              preferredModels: [], fallbackModel: "openai/gpt-4o-mini",
              apiKeyURL: URL(string: "https://openrouter.ai/keys")!)
    ]

    public static var sandboxOptions: [SandboxModelProvider] { [gusLocal] + all }

    public init(id: String, name: String, description: String, keyPlaceholder: String,
                baseURL: String, preferredModels: [String], fallbackModel: String,
                apiKeyURL: URL, supportsGoogleOAuth: Bool = false, curatedOnly: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.keyPlaceholder = keyPlaceholder
        self.baseURL = baseURL
        self.preferredModels = preferredModels
        self.fallbackModel = fallbackModel
        self.apiKeyURL = apiKeyURL
        self.supportsGoogleOAuth = supportsGoogleOAuth
        self.curatedOnly = curatedOnly
    }

    public static func provider(id: String) -> SandboxModelProvider? {
        if id == gusLocal.id { return gusLocal }
        return all.first { $0.id == id }
    }
}

/// Keeps the provider's live catalog while placing known-good models first (or filtering to curated
/// models only when `curatedOnly` is true).
public enum SandboxModelCatalog {
    public static func orderedModelIDs(available: [String], preferred: [String], fallback: String, curatedOnly: Bool = false) -> [String] {
        var seen = Set<String>()
        if curatedOnly {
            let curated = preferred.filter { available.contains($0) && !$0.isEmpty && seen.insert($0).inserted }
            return curated.isEmpty ? [fallback] : curated
        }
        let ordered = preferred.filter { available.contains($0) } + available.filter { !preferred.contains($0) }
        let unique = ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? [fallback] : unique
    }
}

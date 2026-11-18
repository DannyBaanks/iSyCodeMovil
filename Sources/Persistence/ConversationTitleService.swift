import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates short 2-4 word conversation titles on-device when Apple Intelligence is available,
/// falling back cleanly to a truncated version of the first prompt.
public enum ConversationTitleService {
    public static func generateTitle(from firstPrompt: String) async -> String {
        let cleaned = firstPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else { return "Nueva conversación" }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if SystemLanguageModel.default.availability == .available {
                do {
                    let session = LanguageModelSession(model: .init(useCase: .general, guardrails: .permissiveContentTransformations))
                    let response = try await session.respond(to: """
                    Resume en 2 a 4 palabras en español el tema de este mensaje, sin comillas ni punto final:
                    "\(cleaned.prefix(240))"
                    """)
                    let title = response.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
                    if !title.isEmpty && title.count <= 44 {
                        return title
                    }
                } catch {
                    // Fall back to prompt prefix below.
                }
            }
        }
        #endif

        return String(cleaned.prefix(44))
    }
}

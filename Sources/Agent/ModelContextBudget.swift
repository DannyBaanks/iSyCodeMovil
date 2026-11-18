import Foundation

/// Keeps what the agent sends each turn valid and bounded.
///
/// The loop used to resend the whole conversation, every file it had read
/// included, on every turn. With a remote API that hits the per-minute token
/// limit (OpenAI answers 429 "Request too large … tokens per min"); with GUS it
/// overflowed the 2K context and every later message failed.
enum ModelContextBudget {
    /// Tool output from earlier turns: the model already acted on it.
    static let olderToolOutputLimit = 1_500
    /// Tool output from the latest step.
    static let latestToolOutputLimit = 24_000
    /// About 24K tokens: below OpenAI's lowest tier TPM limit (30K) for gpt-4o.
    static let remoteCharacterCap = 96_000
    /// Local GUS adds its compact 14-tool contract after this fitter runs.
    /// Reserve enough room for that catalog plus llama.cpp chat-template framing.
    static let localBoundaryReserveCharacters = 2_500

    static let cancelledToolNote = "Cancelled: the user stopped this step before the tool finished."

    /// Character budget for the prompt, from the provider's declared context.
    static func characterBudget(for capabilities: ModelProviderCapabilities, reservedOutputTokens: Int) -> Int {
        let context = capabilities.maxContextTokens ?? 8_192
        let output = min(capabilities.maxTokens ?? reservedOutputTokens, reservedOutputTokens)
        let available = max(context - output, 256)
        if capabilities.localOnly {
            // Small local vocabularies tokenize Spanish poorly (~2.5 chars/token).
            // GUS injects the miniagent tool catalog after fit(), so reserve it here.
            return max(Int(Double(available) * 2.5) - localBoundaryReserveCharacters, 1_000)
        }
        return min(Int(Double(available) * 3.5), remoteCharacterCap)
    }

    /// Every assistant tool call gets a result and no result is left without its
    /// call. OpenAI rejects the whole conversation otherwise, so one Stop in the
    /// middle of a tool used to break a chat for good.
    static func repairToolPairs(_ messages: [ModelMessage]) -> [ModelMessage] {
        var out: [ModelMessage] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            if message.role == .tool { continue } // orphan: its call was not kept
            guard message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty else {
                out.append(message)
                continue
            }
            var results: [ModelMessage] = []
            while index < messages.count, messages[index].role == .tool {
                results.append(messages[index])
                index += 1
            }
            let callIDs = Set(calls.map(\.id))
            var answered = Set<String>()
            out.append(message)
            for result in results {
                guard let id = result.toolCallId, callIDs.contains(id), answered.insert(id).inserted else { continue }
                out.append(result)
            }
            for call in calls where !answered.contains(call.id) {
                out.append(ModelMessage(role: .tool, content: cancelledToolNote, toolCallId: call.id))
            }
        }
        return out
    }

    /// Fits `messages` into `budget` characters: leading system messages and the
    /// latest user request always stay; older steps are shortened, then dropped
    /// whole (a tool call never loses its result).
    static func fit(_ messages: [ModelMessage], budget: Int) -> [ModelMessage] {
        let repaired = repairToolPairs(messages)
        let systemCount = repaired.prefix { $0.role == .system }.count
        let system = Array(repaired.prefix(systemCount))
        var units = Self.units(Array(repaired.dropFirst(systemCount)))
        guard !units.isEmpty else { return system }

        let lastUserUnit = units.lastIndex { $0.first?.role == .user }
        for u in units.indices {
            let limit = u == units.count - 1 ? latestToolOutputLimit : olderToolOutputLimit
            units[u] = units[u].map { shortened($0, limit: limit) }
        }

        func size(_ list: [ModelMessage]) -> Int { list.reduce(0) { $0 + $1.content.count + 16 } }
        var total = size(system) + units.reduce(0) { $0 + size($1) }
        var keep = Array(repeating: true, count: units.count)
        for u in units.indices where total > budget {
            if u == lastUserUnit || u == units.count - 1 { continue }
            keep[u] = false
            total -= size(units[u])
        }
        var kept: [ModelMessage] = system
        for u in units.indices where keep[u] { kept.append(contentsOf: units[u]) }

        // Still too big: a single huge message. Trim the longest non-system ones.
        var overflow = total - budget
        while overflow > 0 {
            guard let longest = kept.indices.filter({ kept[$0].role != .system })
                    .max(by: { kept[$0].content.count < kept[$1].content.count }),
                  kept[longest].content.count > 400 else { break }
            let target = max(kept[longest].content.count - overflow, 400)
            let before = kept[longest].content.count
            kept[longest] = shortened(kept[longest], limit: target, anyRole: true)
            overflow -= before - kept[longest].content.count
        }
        return kept
    }

    /// A user message, a plain assistant message, or an assistant tool call
    /// together with its results.
    private static func units(_ messages: [ModelMessage]) -> [[ModelMessage]] {
        var units: [[ModelMessage]] = []
        for message in messages {
            if message.role == .tool, !units.isEmpty {
                units[units.count - 1].append(message)
            } else {
                units.append([message])
            }
        }
        return units
    }

    private static func shortened(_ message: ModelMessage, limit: Int, anyRole: Bool = false) -> ModelMessage {
        guard anyRole || message.role == .tool, message.content.count > limit else { return message }
        let keep = max(limit - 120, 0)
        let head = String(message.content.prefix(keep))
        let omitted = message.content.count - keep
        let content = head + "\n[… \(omitted) characters omitted to fit the model's context …]"
        return ModelMessage(role: message.role, content: content, name: message.name,
                            toolCallId: message.toolCallId, toolCalls: message.toolCalls, metadata: message.metadata,
                            multimodalParts: message.multimodalParts)
    }
}

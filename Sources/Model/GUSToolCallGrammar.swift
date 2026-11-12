import Foundation

/// Builds the GBNF grammar that constrains a local model's reply to either plain text
/// or one well-formed tool call for a tool exposed in this turn.
///
/// The prompt alone cannot make a small model produce valid JSON with the right tool
/// name, argument names and types. With this grammar the sampler never emits a token
/// that would break the format, so a call that starts is a call that parses.
///
/// Shape of a reply:
/// - optional `<think>…</think>` (reasoning models), then
/// - either text that does not begin with `<`, or
/// - `<GUS_TOOL_CALL>{"name":…,"arguments":{…}}</GUS_TOOL_CALL>` with no whitespace,
///   required arguments in their declared order and optional ones after, alphabetically.
///
/// `scripts/gus_catalog/tool_grammar.gbnf` is this output for the simple tool set; CI
/// checks it against every llama.cpp tokenizer, and a unit test keeps the two in sync.
enum GUSToolCallGrammar {
    static func gbnf(for tools: [ToolDefinition]) -> String? {
        guard !tools.isEmpty else { return nil }
        var lines = [
            // Leading whitespace is bounded: unbounded, a weak model can loop on it forever.
            #"root ::= ws think? (call | answer)"#,
            #"ws ::= [ \t\n]{0,4}"#,
            #"think ::= "<think>" ([^<] | "<" [^/])* "</think>" ws"#,
            #"answer ::= [^< \t\n] [^\x00]*"#
        ]
        let alternatives = tools.indices.map { "t\($0)" }.joined(separator: " | ")
        lines.append(#"call ::= "<GUS_TOOL_CALL>" ("# + alternatives + #") "</GUS_TOOL_CALL>""#)
        for (index, tool) in tools.enumerated() {
            let arguments = argumentsRule(for: tool)
            let head = literal("{\"name\":\"\(tool.name)\",\"arguments\":{")
            lines.append("t\(index) ::= \(head)\(arguments.isEmpty ? "" : " " + arguments) \(literal("}}"))")
        }
        lines.append(contentsOf: [
            #"string ::= "\"" char* "\"""#,
            #"char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)"#,
            #"hex ::= [0-9a-fA-F]"#,
            #"integer ::= "-"? [0-9]+"#,
            #"number ::= "-"? [0-9]+ ("." [0-9]+)?"#,
            #"boolean ::= "true" | "false""#
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    /// Argument names in the order the grammar expects them: required as declared, then
    /// optional alphabetically. The prompt lists them the same way.
    static func orderedArguments(for tool: ToolDefinition) -> (required: [String], optional: [String]) {
        let properties = tool.parameters.properties
        var required: [String] = []
        for key in tool.parameters.required where properties[key] != nil && !required.contains(key) {
            required.append(key)
        }
        let optional = properties.keys.filter { !required.contains($0) }.sorted()
        return (required, optional)
    }

    private static func argumentsRule(for tool: ToolDefinition) -> String {
        let order = orderedArguments(for: tool)
        func pair(_ key: String) -> String {
            let schema = tool.parameters.properties[key]
            return literal("\"\(key)\":") + " " + valueRule(type: schema?.type ?? "string", enumValues: schema?.enumValues)
        }
        let comma = literal(",")
        if !order.required.isEmpty {
            let required = order.required.map(pair).joined(separator: " \(comma) ")
            let optional = order.optional.map { " (\(comma) \(pair($0)))?" }.joined()
            return required + optional
        }
        guard !order.optional.isEmpty else { return "" }
        // No required argument: any optional one may come first, the rest follow in order.
        let chains = order.optional.indices.map { start -> String in
            let rest = order.optional[(start + 1)...].map { " (\(comma) \(pair($0)))?" }.joined()
            return pair(order.optional[start]) + rest
        }
        return "(" + chains.joined(separator: " | ") + ")?"
    }

    private static func valueRule(type: String, enumValues: [String]?) -> String {
        if let enumValues, !enumValues.isEmpty {
            return "(" + enumValues.map { literal("\"\($0)\"") }.joined(separator: " | ") + ")"
        }
        switch type {
        case "integer": return "integer"
        case "number": return "number"
        case "boolean": return "boolean"
        default: return "string"
        }
    }

    /// A GBNF string literal for `text`.
    private static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

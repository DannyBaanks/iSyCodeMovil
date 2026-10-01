import CoreFoundation
import Foundation

/// Fail-closed parser for GUS's local tool proposal format. It accepts exactly
/// one tagged JSON object matching the current per-turn tool allowlist.
enum GUSLocalToolCallParser {
    private static let openingTag = "<GUS_TOOL_CALL>"
    private static let closingTag = "</GUS_TOOL_CALL>"
    private static let maximumPayloadBytes = 8_192

    static func parse(_ output: String, allowedTools: [ToolDefinition]) -> ToolCall? {
        let candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix(openingTag), candidate.hasSuffix(closingTag),
              let opening = candidate.range(of: openingTag),
              let closing = candidate.range(of: closingTag, range: opening.upperBound..<candidate.endIndex) else {
            return nil
        }
        let payload = String(candidate[opening.upperBound..<closing.lowerBound])
        guard let data = payload.data(using: .utf8), data.count <= maximumPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any], Set(root.keys) == Set(["name", "arguments"]),
              let name = root["name"] as? String,
              let arguments = root["arguments"] as? [String: Any],
              let definition = allowedTools.first(where: { $0.name == name }),
              Set(arguments.keys).isSubset(of: Set(definition.parameters.properties.keys)),
              definition.parameters.required.allSatisfy({ arguments[$0] != nil }) else {
            return nil
        }

        var normalized: [String: String] = [:]
        for (key, value) in arguments {
            guard let schema = definition.parameters.properties[key],
                  let scalar = scalar(value, expectedType: schema.type) else { return nil }
            if let allowedValues = schema.enumValues, !allowedValues.contains(scalar) { return nil }
            normalized[key] = scalar
        }
        return ToolCall(name: name, arguments: normalized)
    }

    private static func scalar(_ value: Any, expectedType: String) -> String? {
        if let string = value as? String, expectedType == "string" { return string }
        guard let number = value as? NSNumber else { return nil }
        switch expectedType {
        case "boolean":
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue ? "true" : "false"
        case "integer":
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.stringValue
        case "number":
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.stringValue
        default:
            return nil
        }
    }
}

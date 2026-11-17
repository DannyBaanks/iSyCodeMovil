import Foundation

/// One block of an assistant message. The chat used to hand the whole message to `AttributedString(markdown:)` and
/// show it in a single `Text`; SwiftUI keeps the inline styling there but drops the block structure, so paragraph
/// breaks and list items ran together ("…sandboxQue la calculadora…"). Splitting the message into blocks first and
/// drawing each one on its own keeps every line break the model wrote.
public enum ChatMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: Int, text: String)
    case quote(String)
    case code(language: String, text: String)
    case table([String])
    case rule
}

/// Splits Markdown into blocks. Pure and forgiving: a message that is still streaming (an unclosed code fence, a
/// half-written list) always yields something sensible instead of failing.
public enum ChatMarkdownParser {
    public static func parse(_ markdown: String) -> [ChatMarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var table: [String] = []
        var quote: [String] = []
        var fence: (language: String, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            blocks.append(.table(table))
            table = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushText() {
            flushParagraph()
            flushTable()
            flushQuote()
        }

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = fence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushText()
                fence = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if trimmed.isEmpty {
                flushText()
                continue
            }
            if isRule(trimmed) {
                flushText()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flushText()
                blocks.append(heading)
                continue
            }
            if trimmed.count > 1, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                flushParagraph()
                flushQuote()
                table.append(trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushText()
                blocks.append(item)
                continue
            }
            flushTable()
            flushQuote()
            paragraph.append(trimmed)
        }

        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flushText()
        return blocks
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func heading(_ trimmed: String) -> ChatMarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes.count, text: text)
    }

    /// Bullets (`-`, `*`, `+`, `•`) and numbered items (`1.` or `1)`), with their indentation in steps of two spaces.
    private static func listItem(_ line: String) -> ChatMarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }
        let indent = spaces.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(spaces.count)

        for marker in ["- ", "* ", "+ ", "• "] where body.hasPrefix(marker) {
            let text = body.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .bullet(indent: indent, text: text)
        }
        let digits = body.prefix { $0.isNumber && $0.isASCII }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
        let afterSeparator = afterDigits.dropFirst()
        guard afterSeparator.first == " " else { return nil }
        let text = afterSeparator.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .numbered(indent: indent, number: number, text: text)
    }
}

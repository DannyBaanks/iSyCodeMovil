import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses WDA's XML accessibility tree and provides the same model-facing descriptions as
/// `ictl-wda` / `ictl-daemon` when `IPHONE_CONTROL_LANG=en`.
public struct WdaElementReader: WdaElementReading {
    public init() {}

    public func parse(xml: String) -> [LocalElement] {
        let delegate = WdaXMLTreeParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.elements
    }

    public func format(_ elements: [LocalElement], limit: Int) -> String {
        let shownCount = min(elements.count, max(0, limit))
        var lines = elements.prefix(shownCount).map(Self.describe)

        if lines.isEmpty {
            lines.append("No elements with text found")
        }
        if elements.count > shownCount {
            lines.append("…\(elements.count - shownCount) more not listed, narrow it down with filter")
        }
        return lines.joined(separator: "\n")
    }

    public func resolveTap(text: String, index: Int, in elements: [LocalElement]) throws -> (x: Double, y: Double) {
        let exact = elements.filter { $0.label == text || $0.name == text }
        let matches: [LocalElement]
        if !exact.isEmpty {
            matches = exact
        } else {
            let needle = text.lowercased()
            matches = elements.filter {
                [$0.label, $0.name, $0.value].contains { $0.lowercased().contains(needle) }
            }
        }

        guard !matches.isEmpty else {
            throw WdaElementReaderError.noMatch(text)
        }
        guard index >= 0, index < matches.count else {
            throw WdaElementReaderError.indexOutOfRange(matches.map(Self.describe))
        }
        let element = matches[index]
        return (Double(element.centerX), Double(element.centerY))
    }

    private static func describe(_ element: LocalElement) -> String {
        let fullText = element.text
        let text = clip(fullText, maximum: 80, keep: 60, includeCharacterCount: true)
        var line = "\(element.kind) \"\(text)\""

        if !element.name.isEmpty, !element.label.isEmpty, element.name != element.label {
            let identifier = scalarCount(element.name) > 48 ? scalarPrefix(element.name, 40) + "…" : element.name
            line += " id=\"\(identifier)\""
        }
        if !element.value.isEmpty, element.value != element.label, element.value != element.name {
            line += " value=\"\(scalarPrefix(element.value, 60))\""
        }
        line += " @(\(element.centerX),\(element.centerY)) \(element.width)x\(element.height)"
        return line
    }

    private static func clip(_ text: String, maximum: Int, keep: Int, includeCharacterCount: Bool) -> String {
        let count = scalarCount(text)
        guard count > maximum else { return text }
        let suffix = includeCharacterCount ? "…(\(count) characters)" : "…"
        return scalarPrefix(text, keep) + suffix
    }

    private static func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }

    private static func scalarPrefix(_ text: String, _ count: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars.prefix(count) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

public enum WdaElementReaderError: Error, LocalizedError, Sendable {
    case noMatch(String)
    case indexOutOfRange([String])

    public var errorDescription: String? {
        switch self {
        case .noMatch(let text):
            return "Not found: no element contains \"\(text)\"; look at the screen with iphone_list_elements or a screenshot first"
        case .indexOutOfRange(let descriptions):
            return "Only matched \(descriptions.count) (index out of range):\n\(descriptions.joined(separator: "\n"))"
        }
    }
}

private struct WdaRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct WdaNode {
    let kind: String
    let label: String
    let name: String
    let value: String
    let rect: WdaRect
    let ancestors: [Int]
    let inStatusBar: Bool
    let scrollAncestorIndex: Int?
}

private struct WdaNodeFrame {
    let nodeIndex: Int
    let absoluteRect: WdaRect
    let offsetX: Double
    let offsetY: Double
    let inStatusBar: Bool
    let scrollAncestorIndex: Int?
    let ancestors: [Int]
}

private struct WdaElementKey: Hashable {
    let text: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private final class WdaXMLTreeParser: NSObject, XMLParserDelegate {
    private static let scrollers: Set<String> = ["ScrollView", "Table", "CollectionView", "WebView", "TextView"]
    private static let containers: Set<String> = [
        "Button", "Cell", "Link", "Icon", "MenuItem", "SearchField", "TextField", "Switch", "Tab", "Key"
    ]

    private(set) var nodes: [WdaNode] = []
    private var stack: [WdaNodeFrame] = []
    private var screenWidth: Double?
    private var screenHeight: Double?
    private var hasApplicationFrame = false

    var elements: [LocalElement] {
        makeElements()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributesDict: [String: String]
    ) {
        let parent = stack.last
        let fullKind = attributesDict["type"] ?? elementName
        let kind = fullKind.hasPrefix("XCUIElementType") ? String(fullKind.dropFirst("XCUIElementType".count)) : fullKind
        let label = trimmed(attributesDict["label"])
        let name = trimmed(attributesDict["name"])
        let value = trimmed(attributesDict["value"])
        let raw = WdaRect(
            x: number(attributesDict["x"]),
            y: number(attributesDict["y"]),
            width: number(attributesDict["width"]),
            height: number(attributesDict["height"])
        )

        var offsetX = parent?.offsetX ?? 0
        var offsetY = parent?.offsetY ?? 0
        if let parent,
           raw.x == 0,
           raw.y == 0,
           abs(raw.width - parent.absoluteRect.width) < 1,
           abs(raw.height - parent.absoluteRect.height) < 1,
           (parent.absoluteRect.x != 0 || parent.absoluteRect.y != 0) {
            offsetX = parent.absoluteRect.x
            offsetY = parent.absoluteRect.y
        }
        let absoluteRect = WdaRect(
            x: raw.x + offsetX,
            y: raw.y + offsetY,
            width: raw.width,
            height: raw.height
        )
        let inStatusBar = kind == "StatusBar" || (parent?.inStatusBar ?? false)
        let ancestors = parent.map { $0.ancestors + [$0.nodeIndex] } ?? []
        let scrollAncestorIndex = Self.scrollers.contains(kind) ? nodes.count : parent?.scrollAncestorIndex
        let node = WdaNode(
            kind: kind,
            label: label,
            name: name,
            value: value,
            rect: absoluteRect,
            ancestors: ancestors,
            inStatusBar: inStatusBar,
            scrollAncestorIndex: scrollAncestorIndex
        )
        let index = nodes.count
        nodes.append(node)

        if kind == "Application", raw.width > 0, raw.height > 0 {
            screenWidth = raw.x + raw.width
            screenHeight = raw.y + raw.height
            hasApplicationFrame = true
        } else if !hasApplicationFrame, kind == "Window", raw.width > 0, raw.height > 0, screenWidth == nil {
            screenWidth = raw.x + raw.width
            screenHeight = raw.y + raw.height
        }

        stack.append(WdaNodeFrame(
            nodeIndex: index,
            absoluteRect: absoluteRect,
            offsetX: offsetX,
            offsetY: offsetY,
            inStatusBar: inStatusBar,
            scrollAncestorIndex: scrollAncestorIndex,
            ancestors: ancestors
        ))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    private func makeElements() -> [LocalElement] {
        var sw = screenWidth ?? 0
        var sh = screenHeight ?? 0
        if sw <= 0 || sh <= 0 {
            sw = max(sw, nodes.map { $0.rect.x + $0.rect.width }.max() ?? 0)
            sh = max(sh, nodes.map { $0.rect.y + $0.rect.height }.max() ?? 0)
        }
        guard sw > 0, sh > 0 else { return [] }

        var seen = Set<WdaElementKey>()
        var keptNodeIndices = Set<Int>()
        var result: [LocalElement] = []
        for (nodeIndex, node) in nodes.enumerated() {
            let rect = node.rect
            guard rect.width > 0, rect.height > 0,
                  rect.x < sw, rect.y < sh,
                  rect.x + rect.width > 0, rect.y + rect.height > 0 else { continue }

            let visibleX = max(0, rect.x)
            let visibleY = max(0, rect.y)
            let visibleWidth = min(rect.x + rect.width, sw) - visibleX
            let visibleHeight = min(rect.y + rect.height, sh) - visibleY
            guard visibleWidth > 0, visibleHeight > 0,
                  !(rect.width >= sw && rect.height >= sh) else { continue }

            let hasText = !node.label.isEmpty || !node.name.isEmpty || !node.value.isEmpty
            guard hasText else { continue }
            if node.inStatusBar && node.kind != "Button" { continue }

            let text = [node.label, node.name, node.value].first(where: { !$0.isEmpty }) ?? ""

            if (node.kind == "Other" || node.kind == "Image"), node.value.isEmpty,
               (node.label.isEmpty || node.label == node.name), looksLikeIdentifier(node.name) {
                continue
            }

            if (node.kind == "StaticText" || node.kind == "Image"),
               node.ancestors.contains(where: { ancestorIndex in
                   let ancestor = nodes[ancestorIndex]
                   return keptNodeIndices.contains(ancestorIndex)
                       && Self.containers.contains(ancestor.kind)
                       && !ancestor.label.isEmpty
                       && (node.kind == "Image" || ancestor.label.contains(text))
               }) {
                continue
            }

            let scrollArea: (Double, Double) = node.scrollAncestorIndex.map {
                (nodes[$0].rect.width, nodes[$0].rect.height)
            } ?? (sw, sh)
            if isScrollBar(node, width: rect.width, height: rect.height, within: scrollArea) { continue }

            let key = WdaElementKey(
                text: text,
                x: rounded(rect.x),
                y: rounded(rect.y),
                width: rounded(rect.width),
                height: rounded(rect.height)
            )
            guard seen.insert(key).inserted else { continue }

            keptNodeIndices.insert(nodeIndex)
            result.append(LocalElement(
                kind: node.kind,
                label: node.label,
                name: node.name,
                value: node.value,
                centerX: rounded(visibleX + visibleWidth / 2),
                centerY: rounded(visibleY + visibleHeight / 2),
                width: rounded(rect.width),
                height: rounded(rect.height)
            ))
        }
        return result
    }

    private func isScrollBar(_ node: WdaNode, width: Double, height: Double, within: (Double, Double)) -> Bool {
        let label = node.label.lowercased()
        if node.kind == "Other", (node.label.contains("滚动条") || label.contains("scroll bar")) { return true }
        guard node.kind == "Other", isPercentage(node.value) else { return false }
        let thick = min(width, height)
        let long = max(width, height)
        let room = height >= width ? within.1 : within.0
        return (24...32).contains(thick) && long >= room * 0.6
    }

    private func isPercentage(_ value: String) -> Bool {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasSuffix("%") { candidate.removeLast() }
        else if candidate.hasPrefix("%") { candidate.removeFirst() }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !candidate.isEmpty && candidate.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private func looksLikeIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return scalars.count >= 3
            && scalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }
            && value.contains(where: { "_-.:".contains($0) })
    }

    private func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded(.toNearestOrEven)
        guard rounded >= Double(Int.min), rounded <= Double(Int.max) else { return 0 }
        return Int(rounded)
    }

    private func number(_ raw: String?) -> Double {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return 0 }
        return value
    }

    private func trimmed(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

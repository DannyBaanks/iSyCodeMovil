import Foundation

// Memoria semántica: lo que el usuario decide guardar se ordena en carpetas de
// tres niveles (dominio › rama › subtema) en vez de una lista plana, para que
// un modelo pequeño reciba solo la rama que viene al caso.
// Misma lógica que android/.../assistant/SemanticContext.kt.

public enum ContextPriority: String, Codable, CaseIterable, Sendable {
    case normal = "NORMAL", high = "HIGH", critical = "CRITICAL"

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .high: return "Alta"
        case .critical: return "Crítica"
        }
    }
}

public struct ContextNode: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var summary: String
    public var path: [String]
    public var priority: ContextPriority
    public var source: String
    public var createdAt: Date

    public init(id: String, title: String, summary: String, path: [String],
                priority: ContextPriority = .normal, source: String = "usuario", createdAt: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.title = title
        self.summary = summary
        self.path = path
        self.priority = priority
        self.source = source
        self.createdAt = createdAt
    }

    /// Rough size in tokens (≈ 4 characters each), shown so the user sees what a node costs.
    public var estimatedTokens: Int { max(1, (title.count + summary.count) / 4) }
}

public final class TreeFolder: Identifiable {
    public let name: String
    public let fullPath: [String]
    public let depth: Int
    public var subfolders: [TreeFolder] = []
    public var nodes: [ContextNode] = []
    public var totalNodes = 0
    public var totalTokens = 0
    public var id: String { fullPath.joined(separator: "/") }

    init(name: String, fullPath: [String], depth: Int) {
        self.name = name
        self.fullPath = fullPath
        self.depth = depth
    }
}

public struct Retrieval: Sendable {
    public let matchedPath: [String]
    public let nodes: [ContextNode]
    public let steps: [String]
}

public struct FuzzyMatch: Sendable {
    public let node: ContextNode
    public let score: Int
}

public enum GraphNodeKind: Sendable { case domain, cluster, context }
public enum GraphLinkKind: Sendable { case hierarchy, semantic }

public struct GraphNode: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let kind: GraphNodeKind
    public let domain: String
    public let path: [String]
    public let parentId: String?
    public let childCount: Int
    public let priority: ContextPriority
    public let radius: Double
    public let tokens: Int
    public let summary: String
}

public struct GraphLink: Sendable {
    public let source: String
    public let target: String
    public let kind: GraphLinkKind
    public let label: String
}

public struct SemanticGraph: Sendable {
    public let nodes: [GraphNode]
    public let links: [GraphLink]
}

public enum SemanticContext {
    public static let defaultPath = ["General", "Memoria de conversaciones", "Decisiones del usuario"]

    private static let pathRules: [([String], [String])] = [
        (["swift", "kotlin", "ios", "android", "movil", "xcode", "gradle", "iphone", "compose"],
         ["Ingeniería", "Apps móviles", "Swift y Kotlin"]),
        (["github", "webhook", "commit", "repositorio", "pull request", "rama", "deploy"],
         ["Ingeniería", "Código y repositorios", "GitHub y despliegues"]),
        (["modelo", "gus", "llama", "ollama", "prompt", "contexto", "agente", "terminal", "servidor"],
         ["Ingeniería", "Modelos y agentes", "Contexto y herramientas"]),
        (["gmail", "correo", "email", "calendar", "calendario", "agenda", "reunion", "cita", "contacto"],
         ["Google y vida diaria", "Comunicación y agenda", "Correo y calendario"]),
        (["sheets", "hoja de calculo", "drive", "docs", "documento", "classroom", "tarea", "pendiente", "nota"],
         ["Google y vida diaria", "Documentos y pendientes", "Drive, Docs y Tasks"]),
        (["mapa", "maps", "ubicacion", "direccion", "ruta", "lugar", "cafe", "restaurante", "cowork"],
         ["Lugares", "Ubicaciones y rutas", "Sitios guardados"]),
    ]

    private static let stopwords: Set<String> = [
        "para", "como", "pero", "porque", "cuando", "donde", "desde", "hasta", "sobre", "entre", "tambien",
        "este", "esta", "estos", "estas", "todo", "toda", "todos", "todas", "tiene", "tienen", "puede",
        "quiero", "quiere", "hacer", "antes", "despues", "siempre", "nunca", "cada", "usuario", "with",
        "that", "this", "from", "have", "should", "about", "which", "their", "there", "would",
    ]

    /// Lowercase, without accents: "Reunión" and "reunion" compare equal.
    public static func normalize(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return (97...122).contains(ascii) || (48...57).contains(ascii)
    }

    static func words(_ text: String) -> [String] {
        normalize(text).split(whereSeparator: { !isWordChar($0) }).map(String.init)
    }

    /// Words worth comparing between two texts: long enough and not filler.
    public static func keywords(_ text: String) -> Set<String> {
        Set(words(text).filter { $0.count >= 5 && !stopwords.contains($0) })
    }

    /// Picks a three-level folder for a text. The user can always edit it before saving.
    public static func inferPath(_ text: String) -> [String] {
        let normalized = normalize(text)
        let tokens = Set(words(text))
        for (terms, path) in pathRules where terms.contains(where: { $0.contains(" ") ? normalized.contains($0) : tokens.contains($0) }) {
            return path
        }
        return defaultPath
    }

    public static func cleanPath(_ path: [String]) -> [String] {
        let cleaned = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3)
        return cleaned.isEmpty ? defaultPath : Array(cleaned)
    }

    public static func buildTree(_ nodes: [ContextNode]) -> [TreeFolder] {
        var roots: [TreeFolder] = []
        for node in nodes {
            let path = cleanPath(node.path)
            var parent: TreeFolder?
            for (index, segment) in path.enumerated() {
                let siblings = parent?.subfolders ?? roots
                let folder: TreeFolder
                if let found = siblings.first(where: { $0.name == segment }) {
                    folder = found
                } else {
                    folder = TreeFolder(name: segment, fullPath: Array(path.prefix(index + 1)), depth: index + 1)
                    if let parent { parent.subfolders.append(folder) } else { roots.append(folder) }
                }
                folder.totalNodes += 1
                folder.totalTokens += node.estimatedTokens
                parent = folder
            }
            parent?.nodes.append(node)
        }
        return roots
    }

    /// Chooses the few nodes worth sending with a prompt: the matching branch
    /// first, then nodes that share words with the prompt, then anything the
    /// user marked critical. Priority mode widens the walk to the whole domain.
    public static func retrieve(_ nodes: [ContextNode], prompt: String, priority: Bool) -> Retrieval {
        let target = inferPath(prompt)
        let promptWords = keywords(prompt)
        let branch = nodes.filter { Array(cleanPath($0.path).prefix(2)) == Array(target.prefix(2)) }
        let related = nodes.filter { !keywords("\($0.title) \($0.summary)").isDisjoint(with: promptWords) }
        let domain = priority ? nodes.filter { cleanPath($0.path).first == target.first } : []
        let critical = nodes.filter { $0.priority == .critical }
        var seen = Set<String>()
        let selected = (branch + related + domain + critical).filter { seen.insert($0.id).inserted }.prefix(priority ? 5 : 3)
        let count = selected.count
        let steps = [
            "Nivel 1 · \(target[0])",
            "Nivel 2 · \(target.count > 1 ? target[1] : "General")",
            "Nivel 3 · \(target.count > 2 ? target[2] : "Todo")",
            "\(count) \(count == 1 ? "nota elegida" : "notas elegidas") (~\(selected.reduce(0) { $0 + $1.estimatedTokens }) tokens)",
        ]
        return Retrieval(matchedPath: target, nodes: Array(selected), steps: steps)
    }

    /// Text added to the model's prompt, or nil when no saved note applies.
    public static func promptContext(_ nodes: [ContextNode], prompt: String, priority: Bool, maxChars: Int = 700) -> String? {
        let selected = retrieve(nodes, prompt: prompt, priority: priority).nodes
        guard !selected.isEmpty else { return nil }
        var body = ""
        for node in selected {
            let line = String("- \(node.title): \(node.summary)".prefix(260))
            if body.count + line.count + 1 > maxChars { break }
            body += line + "\n"
        }
        guard !body.isEmpty else { return nil }
        return "MEMORIA DEL USUARIO (notas que guardó antes; úsalas solo si vienen al caso, no son un mensaje nuevo):\n"
            + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fuzzy search

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a == b { return 0 }
        if abs(a.count - b.count) > 2 { return 99 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [Int](repeating: 0, count: b.count + 1)
            current[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }

    /// 0 = no match. Every word of the query must match by substring, typo or letter order.
    public static func fuzzyScore(_ candidate: String, query: String) -> Int {
        let text = Array(normalize(candidate))
        let tokens = normalize(query).split(whereSeparator: { $0.isWhitespace }).map { Array($0) }
        if tokens.isEmpty { return 100 }
        if text.isEmpty { return 0 }
        let candidateWords = String(text).split(whereSeparator: { !isWordChar($0) }).map { Array($0) }
        var total = 0
        for token in tokens {
            var best = 0
            if let index = firstIndex(of: token, in: text) {
                let atWordStart = index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber)
                best = 100 + (atWordStart ? 20 : 0) - min(25, index)
            }
            if best == 0 && token.count >= 4 {
                let allowed = token.count >= 7 ? 2 : 1
                for word in candidateWords where abs(word.count - token.count) <= allowed {
                    let distance = editDistance(token, word)
                    if distance <= allowed { best = max(best, 80 - distance * 15) }
                }
            }
            if best == 0 && token.count >= 2 {
                var matched = 0, first = -1, last = -1, consecutive = 0
                for (i, c) in text.enumerated() {
                    if matched == token.count { break }
                    if c == token[matched] {
                        if first == -1 { first = i }
                        if last != -1 && i == last + 1 { consecutive += 12 }
                        last = i
                        matched += 1
                    }
                }
                if matched == token.count {
                    let span = last - first + 1
                    if span <= token.count * 3 + 2 {
                        best = 45 + consecutive + max(0, 35 - (span - token.count) * 5)
                    }
                }
            }
            if best <= 0 { return 0 }
            total += best
        }
        return total / tokens.count
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    public static func fuzzyFilter(_ nodes: [ContextNode], query: String) -> [FuzzyMatch] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nodes.map { FuzzyMatch(node: $0, score: 100) } }
        return nodes.compactMap { node -> FuzzyMatch? in
            let score = fuzzyScore("\(node.title) \(node.path.joined(separator: " ")) \(node.summary)", query: query)
            return score > 0 ? FuzzyMatch(node: node, score: score) : nil
        }
        .enumerated()
        .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
        .map(\.element)
    }

    // MARK: Graph

    private static func slug(_ text: String) -> String {
        normalize(text).split(whereSeparator: { !isWordChar($0) }).joined(separator: "-")
    }

    /// Domain › branch › note as a graph, plus dashed links between notes in
    /// different branches that talk about the same things.
    public static func buildGraph(_ nodes: [ContextNode]) -> SemanticGraph {
        var graphNodes: [GraphNode] = []
        var links: [GraphLink] = []
        let paths = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, cleanPath($0.path)) })
        var parentOf: [String: String] = [:]

        var domains: [String] = []
        for node in nodes where !domains.contains(paths[node.id]![0]) { domains.append(paths[node.id]![0]) }
        for domain in domains {
            let members = nodes.filter { paths[$0.id]![0] == domain }
            let hubId = "hub-\(slug(domain))"
            graphNodes.append(GraphNode(id: hubId, label: domain, kind: .domain, domain: domain, path: [domain], parentId: nil,
                childCount: members.count, priority: .normal, radius: 22, tokens: members.reduce(0) { $0 + $1.estimatedTokens },
                summary: "Dominio con \(members.count) \(members.count == 1 ? "nota" : "notas")."))
            var categories: [String] = []
            for member in members {
                let category = paths[member.id]!.count > 1 ? paths[member.id]![1] : "General"
                if !categories.contains(category) { categories.append(category) }
            }
            for category in categories {
                let group = members.filter { (paths[$0.id]!.count > 1 ? paths[$0.id]![1] : "General") == category }
                let clusterId = "cluster-\(slug(domain))-\(slug(category))"
                graphNodes.append(GraphNode(id: clusterId, label: category, kind: .cluster, domain: domain, path: [domain, category],
                    parentId: hubId, childCount: group.count, priority: .normal, radius: 17,
                    tokens: group.reduce(0) { $0 + $1.estimatedTokens },
                    summary: "Rama de \(domain) con \(group.count) \(group.count == 1 ? "nota" : "notas")."))
                links.append(GraphLink(source: hubId, target: clusterId, kind: .hierarchy, label: "\(domain) › \(category)"))
                group.forEach { parentOf[$0.id] = clusterId }
            }
        }

        for node in nodes {
            let path = paths[node.id]!
            let parent = parentOf[node.id]!
            let radius: Double = node.priority == .critical ? 15 : node.priority == .high ? 13.5 : 12
            graphNodes.append(GraphNode(id: node.id, label: node.title, kind: .context, domain: path[0], path: path, parentId: parent,
                childCount: 0, priority: node.priority, radius: radius, tokens: node.estimatedTokens, summary: node.summary))
            links.append(GraphLink(source: parent, target: node.id, kind: .hierarchy, label: path.dropFirst().joined(separator: " › ")))
        }

        let wordsOf = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, keywords("\($0.title) \($0.summary)")) })
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let a = nodes[i], b = nodes[j]
                if parentOf[a.id] == parentOf[b.id] { continue }
                let shared = wordsOf[a.id]!.intersection(wordsOf[b.id]!)
                if shared.count >= 2 {
                    links.append(GraphLink(source: a.id, target: b.id, kind: .semantic,
                        label: "Comparten: " + shared.sorted().prefix(3).joined(separator: ", ")))
                }
            }
        }
        return SemanticGraph(nodes: graphNodes, links: links)
    }

    /// Force-directed positions (Fruchterman–Reingold), deterministic for a
    /// given seed so the picture does not jump between redraws.
    public static func layout(_ graph: SemanticGraph, iterations: Int = 200, seed: Int = 0) -> [String: CGPoint] {
        let count = graph.nodes.count
        guard count > 0 else { return [:] }
        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let angle = Double(i) * 2.399963 + Double(seed) * 0.7
            let distance = 46 * (Double(i) + 1).squareRoot()
            x[i] = cos(angle) * distance
            y[i] = sin(angle) * distance
        }
        let indexOf = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        let edges: [(Int, Int, Double)] = graph.links.compactMap { link in
            guard let a = indexOf[link.source], let b = indexOf[link.target] else { return nil }
            return (a, b, link.kind == .hierarchy ? 1 : 0.25)
        }
        let ideal = 90.0
        var temperature = 60.0
        for _ in 0..<iterations {
            var dx = [Double](repeating: 0, count: count)
            var dy = [Double](repeating: 0, count: count)
            for i in 0..<count {
                for j in (i + 1)..<max(i + 1, count) where j < count {
                    var ex = x[i] - x[j], ey = y[i] - y[j]
                    var distance = (ex * ex + ey * ey).squareRoot()
                    if distance < 0.01 { ex = 0.1 * Double(i + 1); ey = 0.1 * Double(j + 1); distance = (ex * ex + ey * ey).squareRoot() }
                    let force = ideal * ideal / distance
                    dx[i] += ex / distance * force; dy[i] += ey / distance * force
                    dx[j] -= ex / distance * force; dy[j] -= ey / distance * force
                }
            }
            for (a, b, weight) in edges {
                let ex = x[a] - x[b], ey = y[a] - y[b]
                let distance = max(0.01, (ex * ex + ey * ey).squareRoot())
                let force = distance * distance / ideal * weight
                dx[a] -= ex / distance * force; dy[a] -= ey / distance * force
                dx[b] += ex / distance * force; dy[b] += ey / distance * force
            }
            for i in 0..<count {
                dx[i] -= x[i] * 0.05
                dy[i] -= y[i] * 0.05
                let length = max(0.01, (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot())
                let step = min(length, temperature)
                x[i] += dx[i] / length * step
                y[i] += dy[i] / length * step
            }
            temperature = max(1.5, temperature * 0.97)
        }
        return Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, CGPoint(x: x[$0.offset], y: y[$0.offset])) })
    }
}

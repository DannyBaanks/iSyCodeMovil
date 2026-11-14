package dev.iyscode.movil.assistant

import kotlinx.serialization.Serializable
import java.text.Normalizer
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// Memoria semántica: lo que el usuario decide guardar se ordena en carpetas de
// tres niveles (dominio › rama › subtema) en vez de una lista plana, para que
// un modelo pequeño reciba solo la rama que viene al caso.
// Misma lógica que Sources/Assistant/SemanticContext.swift en iOS.

@Serializable
enum class ContextPriority(val label: String) { NORMAL("Normal"), HIGH("Alta"), CRITICAL("Crítica") }

@Serializable
data class ContextNode(
    val id: String,
    val title: String,
    val summary: String,
    val path: List<String>,
    val priority: ContextPriority = ContextPriority.NORMAL,
    val source: String = "usuario",
    val createdAt: Long = 0,
) {
    /** Rough size in tokens (≈ 4 characters each), shown so the user sees what a node costs. */
    val estimatedTokens: Int get() = max(1, (title.length + summary.length) / 4)
}

class TreeFolder(val name: String, val fullPath: List<String>, val depth: Int) {
    val subfolders = mutableListOf<TreeFolder>()
    val nodes = mutableListOf<ContextNode>()
    var totalNodes = 0
    var totalTokens = 0
}

data class Retrieval(val matchedPath: List<String>, val nodes: List<ContextNode>, val steps: List<String>)

data class FuzzyMatch(val node: ContextNode, val score: Int)

enum class GraphNodeKind { DOMAIN, CLUSTER, CONTEXT }
enum class GraphLinkKind { HIERARCHY, SEMANTIC }

data class GraphNode(
    val id: String,
    val label: String,
    val kind: GraphNodeKind,
    val domain: String,
    val path: List<String>,
    val parentId: String?,
    val childCount: Int,
    val priority: ContextPriority,
    val radius: Float,
    val tokens: Int,
    val summary: String,
)

data class GraphLink(val source: String, val target: String, val kind: GraphLinkKind, val label: String)
data class Graph(val nodes: List<GraphNode>, val links: List<GraphLink>)
data class GraphPoint(val x: Float, val y: Float)

object SemanticContext {
    val defaultPath = listOf("General", "Memoria de conversaciones", "Decisiones del usuario")

    private val pathRules: List<Pair<List<String>, List<String>>> = listOf(
        listOf("swift", "kotlin", "ios", "android", "movil", "xcode", "gradle", "iphone", "compose") to
            listOf("Ingeniería", "Apps móviles", "Swift y Kotlin"),
        listOf("github", "webhook", "commit", "repositorio", "pull request", "rama", "deploy") to
            listOf("Ingeniería", "Código y repositorios", "GitHub y despliegues"),
        listOf("modelo", "gus", "llama", "ollama", "prompt", "contexto", "agente", "terminal", "servidor") to
            listOf("Ingeniería", "Modelos y agentes", "Contexto y herramientas"),
        listOf("gmail", "correo", "email", "calendar", "calendario", "agenda", "reunion", "cita", "contacto") to
            listOf("Google y vida diaria", "Comunicación y agenda", "Correo y calendario"),
        listOf("sheets", "hoja de calculo", "drive", "docs", "documento", "classroom", "tarea", "pendiente", "nota") to
            listOf("Google y vida diaria", "Documentos y pendientes", "Drive, Docs y Tasks"),
        listOf("mapa", "maps", "ubicacion", "direccion", "ruta", "lugar", "cafe", "restaurante", "cowork") to
            listOf("Lugares", "Ubicaciones y rutas", "Sitios guardados"),
    )

    private val stopwords = setOf(
        "para", "como", "pero", "porque", "cuando", "donde", "desde", "hasta", "sobre", "entre", "tambien",
        "este", "esta", "estos", "estas", "todo", "toda", "todos", "todas", "tiene", "tienen", "puede",
        "quiero", "quiere", "hacer", "antes", "despues", "siempre", "nunca", "cada", "usuario", "with",
        "that", "this", "from", "have", "should", "about", "which", "their", "there", "would",
    )

    /** Lowercase, without accents: "Reunión" and "reunion" compare equal. */
    fun normalize(input: String): String =
        Normalizer.normalize(input, Normalizer.Form.NFD)
            .replace(Regex("[\\u0300-\\u036f]"), "")
            .lowercase()
            .trim()

    private fun words(text: String): List<String> =
        normalize(text).split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }

    /** Words worth comparing between two texts: long enough and not filler. */
    fun keywords(text: String): Set<String> =
        words(text).filter { it.length >= 5 && it !in stopwords }.toSet()

    /** Picks a three-level folder for a text. The user can always edit it before saving. */
    fun inferPath(text: String): List<String> {
        val normalized = normalize(text)
        val tokens = words(text).toSet()
        for ((terms, path) in pathRules) {
            if (terms.any { if (it.contains(' ')) normalized.contains(it) else it in tokens }) return path
        }
        return defaultPath
    }

    fun cleanPath(path: List<String>): List<String> {
        val cleaned = path.map { it.trim() }.filter { it.isNotEmpty() }.take(3)
        return if (cleaned.isEmpty()) defaultPath else cleaned
    }

    fun buildTree(nodes: List<ContextNode>): List<TreeFolder> {
        val roots = mutableListOf<TreeFolder>()
        for (node in nodes) {
            val path = cleanPath(node.path)
            var list = roots
            var folder: TreeFolder? = null
            path.forEachIndexed { index, segment ->
                val found = list.firstOrNull { it.name == segment }
                    ?: TreeFolder(segment, path.take(index + 1), index + 1).also { list.add(it) }
                found.totalNodes += 1
                found.totalTokens += node.estimatedTokens
                folder = found
                list = found.subfolders
            }
            folder?.nodes?.add(node)
        }
        return roots
    }

    /**
     * Chooses the few nodes worth sending with a prompt: the matching branch
     * first, then nodes that share words with the prompt, then anything the
     * user marked critical. Priority mode widens the walk to the whole domain.
     */
    fun retrieve(nodes: List<ContextNode>, prompt: String, priority: Boolean): Retrieval {
        val target = inferPath(prompt)
        val promptWords = keywords(prompt)
        val branch = nodes.filter { cleanPath(it.path).take(2) == target.take(2) }
        val related = nodes.filter { node -> keywords("${node.title} ${node.summary}").any { it in promptWords } }
        val domain = if (priority) nodes.filter { cleanPath(it.path).first() == target.first() } else emptyList()
        val critical = nodes.filter { it.priority == ContextPriority.CRITICAL }
        val selected = (branch + related + domain + critical).distinctBy { it.id }.take(if (priority) 5 else 3)
        val steps = listOf(
            "Nivel 1 · ${target[0]}",
            "Nivel 2 · ${target.getOrElse(1) { "General" }}",
            "Nivel 3 · ${target.getOrElse(2) { "Todo" }}",
            "${selected.size} ${if (selected.size == 1) "nota elegida" else "notas elegidas"} (~${selected.sumOf { it.estimatedTokens }} tokens)",
        )
        return Retrieval(target, selected, steps)
    }

    /** Text added to the model's prompt, or null when no saved note applies. */
    fun promptContext(nodes: List<ContextNode>, prompt: String, priority: Boolean, maxChars: Int = 700): String? {
        val selected = retrieve(nodes, prompt, priority).nodes
        if (selected.isEmpty()) return null
        val body = StringBuilder()
        for (node in selected) {
            val line = "- ${node.title}: ${node.summary}".take(260)
            if (body.length + line.length + 1 > maxChars) break
            body.append(line).append('\n')
        }
        if (body.isEmpty()) return null
        return "MEMORIA DEL USUARIO (notas que guardó antes; úsalas solo si vienen al caso, no son un mensaje nuevo):\n" +
            body.toString().trimEnd()
    }

    // ── Fuzzy search ────────────────────────────────────────────────────────

    private fun editDistance(a: String, b: String): Int {
        if (a == b) return 0
        if (abs(a.length - b.length) > 2) return 99
        var previous = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val current = IntArray(b.length + 1)
            current[0] = i
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                current[j] = min(min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.length]
    }

    /** 0 = no match. Every word of the query must match by substring, typo or letter order. */
    fun fuzzyScore(candidate: String, query: String): Int {
        val text = normalize(candidate)
        val tokens = normalize(query).split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return 100
        if (text.isEmpty()) return 0
        val candidateWords = text.split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }
        var total = 0
        for (token in tokens) {
            var best = 0
            val index = text.indexOf(token)
            if (index >= 0) {
                val atWordStart = index == 0 || !text[index - 1].isLetterOrDigit()
                best = 100 + (if (atWordStart) 20 else 0) - min(25, index)
            }
            if (best == 0 && token.length >= 4) {
                val allowed = if (token.length >= 7) 2 else 1
                for (word in candidateWords) {
                    if (abs(word.length - token.length) > allowed) continue
                    val distance = editDistance(token, word)
                    if (distance <= allowed) best = max(best, 80 - distance * 15)
                }
            }
            if (best == 0 && token.length >= 2) {
                var matched = 0
                var first = -1
                var last = -1
                var consecutive = 0
                for (i in text.indices) {
                    if (matched == token.length) break
                    if (text[i] == token[matched]) {
                        if (first == -1) first = i
                        if (last != -1 && i == last + 1) consecutive += 12
                        last = i
                        matched += 1
                    }
                }
                if (matched == token.length) {
                    val span = last - first + 1
                    if (span <= token.length * 3 + 2) {
                        best = 45 + consecutive + max(0, 35 - (span - token.length) * 5)
                    }
                }
            }
            if (best <= 0) return 0
            total += best
        }
        return total / tokens.size
    }

    fun fuzzyFilter(nodes: List<ContextNode>, query: String): List<FuzzyMatch> {
        if (query.isBlank()) return nodes.map { FuzzyMatch(it, 100) }
        return nodes.mapNotNull { node ->
            val score = fuzzyScore("${node.title} ${node.path.joinToString(" ")} ${node.summary}", query)
            if (score > 0) FuzzyMatch(node, score) else null
        }.sortedByDescending { it.score }
    }

    // ── Graph ───────────────────────────────────────────────────────────────

    private fun slug(text: String) = normalize(text).replace(Regex("[^a-z0-9]+"), "-").trim('-')

    /**
     * Domain › branch › note as a graph, plus dashed links between notes in
     * different branches that talk about the same things.
     */
    fun buildGraph(nodes: List<ContextNode>): Graph {
        val graphNodes = mutableListOf<GraphNode>()
        val links = mutableListOf<GraphLink>()
        val paths = nodes.associate { it.id to cleanPath(it.path) }
        val byDomain = nodes.groupBy { paths.getValue(it.id)[0] }
        val parentOf = mutableMapOf<String, String>()

        for ((domain, members) in byDomain) {
            val hubId = "hub-${slug(domain)}"
            graphNodes += GraphNode(hubId, domain, GraphNodeKind.DOMAIN, domain, listOf(domain), null, members.size,
                ContextPriority.NORMAL, 22f, members.sumOf { it.estimatedTokens },
                "Dominio con ${members.size} ${if (members.size == 1) "nota" else "notas"}.")
            for ((category, group) in members.groupBy { paths.getValue(it.id).getOrElse(1) { "General" } }) {
                val clusterId = "cluster-${slug(domain)}-${slug(category)}"
                graphNodes += GraphNode(clusterId, category, GraphNodeKind.CLUSTER, domain, listOf(domain, category), hubId,
                    group.size, ContextPriority.NORMAL, 17f, group.sumOf { it.estimatedTokens },
                    "Rama de $domain con ${group.size} ${if (group.size == 1) "nota" else "notas"}.")
                links += GraphLink(hubId, clusterId, GraphLinkKind.HIERARCHY, "$domain › $category")
                group.forEach { parentOf[it.id] = clusterId }
            }
        }

        for (node in nodes) {
            val path = paths.getValue(node.id)
            val parent = parentOf.getValue(node.id)
            val radius = when (node.priority) {
                ContextPriority.CRITICAL -> 15f
                ContextPriority.HIGH -> 13.5f
                ContextPriority.NORMAL -> 12f
            }
            graphNodes += GraphNode(node.id, node.title, GraphNodeKind.CONTEXT, path[0], path, parent, 0,
                node.priority, radius, node.estimatedTokens, node.summary)
            links += GraphLink(parent, node.id, GraphLinkKind.HIERARCHY, path.drop(1).joinToString(" › "))
        }

        val wordsOf = nodes.associate { it.id to keywords("${it.title} ${it.summary}") }
        for (i in nodes.indices) {
            for (j in i + 1 until nodes.size) {
                val a = nodes[i]
                val b = nodes[j]
                if (parentOf[a.id] == parentOf[b.id]) continue
                val shared = wordsOf.getValue(a.id).intersect(wordsOf.getValue(b.id))
                if (shared.size >= 2) {
                    links += GraphLink(a.id, b.id, GraphLinkKind.SEMANTIC,
                        "Comparten: ${shared.sorted().take(3).joinToString(", ")}")
                }
            }
        }
        return Graph(graphNodes, links)
    }

    /**
     * Force-directed positions (Fruchterman–Reingold), deterministic for a
     * given seed so the picture does not jump between redraws. The result is
     * centered and scaled so every node lies within [fit] dp of the origin;
     * without that, repulsion spreads a dozen nodes far past the canvas.
     */
    fun layout(graph: Graph, iterations: Int = 200, seed: Int = 0, fit: Float = 120f): Map<String, GraphPoint> {
        val count = graph.nodes.size
        if (count == 0) return emptyMap()
        val x = FloatArray(count)
        val y = FloatArray(count)
        for (i in 0 until count) {
            val angle = i * 2.399963f + seed * 0.7f
            val distance = 46f * sqrt(i + 1f)
            x[i] = cos(angle) * distance
            y[i] = sin(angle) * distance
        }
        val indexOf = graph.nodes.withIndex().associate { it.value.id to it.index }
        val edges = graph.links.mapNotNull { link ->
            val a = indexOf[link.source]
            val b = indexOf[link.target]
            if (a == null || b == null) null else Triple(a, b, if (link.kind == GraphLinkKind.HIERARCHY) 1f else 0.25f)
        }
        val ideal = 90f
        var temperature = 60f
        val dx = FloatArray(count)
        val dy = FloatArray(count)
        repeat(iterations) {
            dx.fill(0f)
            dy.fill(0f)
            for (i in 0 until count) {
                for (j in i + 1 until count) {
                    var ex = x[i] - x[j]
                    var ey = y[i] - y[j]
                    var distance = sqrt(ex * ex + ey * ey)
                    if (distance < 0.01f) { ex = 0.1f * (i + 1); ey = 0.1f * (j + 1); distance = sqrt(ex * ex + ey * ey) }
                    val force = ideal * ideal / distance
                    dx[i] += ex / distance * force; dy[i] += ey / distance * force
                    dx[j] -= ex / distance * force; dy[j] -= ey / distance * force
                }
            }
            for ((a, b, weight) in edges) {
                val ex = x[a] - x[b]
                val ey = y[a] - y[b]
                val distance = max(0.01f, sqrt(ex * ex + ey * ey))
                val force = distance * distance / ideal * weight
                dx[a] -= ex / distance * force; dy[a] -= ey / distance * force
                dx[b] += ex / distance * force; dy[b] += ey / distance * force
            }
            for (i in 0 until count) {
                // Strong pull to the center keeps the domains (which have no links
                // between them) close together; otherwise fitting the far-apart
                // domains crushes each one and the labels overlap.
                dx[i] -= x[i] * 2f
                dy[i] -= y[i] * 2f
                val length = max(0.01f, sqrt(dx[i] * dx[i] + dy[i] * dy[i]))
                val step = min(length, temperature)
                x[i] += dx[i] / length * step
                y[i] += dy[i] / length * step
            }
            temperature = max(1.5f, temperature * 0.97f)
        }
        val cx = x.average().toFloat()
        val cy = y.average().toFloat()
        val reach = (0 until count).maxOf { max(abs(x[it] - cx), abs(y[it] - cy)) }
        val k = if (reach > 0f) fit / reach else 1f
        return graph.nodes.withIndex().associate { it.value.id to GraphPoint((x[it.index] - cx) * k, (y[it.index] - cy) * k) }
    }
}

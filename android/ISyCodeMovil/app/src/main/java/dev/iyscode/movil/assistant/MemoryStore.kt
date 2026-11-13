package dev.iyscode.movil.assistant

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/**
 * The user's semantic memory, kept in one private JSON file on the phone.
 * Shared by the assistant screens and by GUS, so a note saved in one place is
 * available to the model everywhere.
 */
class MemoryStore(private val file: File, private val clock: () -> Long = System::currentTimeMillis) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val serializer = ListSerializer(ContextNode.serializer())
    private val _nodes = MutableStateFlow(load())
    val nodes: StateFlow<List<ContextNode>> = _nodes.asStateFlow()

    private fun load(): List<ContextNode> =
        runCatching { json.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyList())

    private fun persist(nodes: List<ContextNode>) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(json.encodeToString(serializer, nodes))
        if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
        _nodes.value = nodes
    }

    fun save(title: String, summary: String, path: List<String>, priority: ContextPriority, source: String): ContextNode {
        val node = ContextNode(
            id = "ctx_" + UUID.randomUUID().toString().take(8),
            title = title.trim().take(120).ifEmpty { summary.trim().take(60) },
            summary = summary.trim().take(1200),
            path = SemanticContext.cleanPath(path),
            priority = priority,
            source = source,
            createdAt = clock(),
        )
        persist(listOf(node) + _nodes.value)
        return node
    }

    fun delete(id: String) = persist(_nodes.value.filterNot { it.id == id })

    fun clear() = persist(emptyList())
}

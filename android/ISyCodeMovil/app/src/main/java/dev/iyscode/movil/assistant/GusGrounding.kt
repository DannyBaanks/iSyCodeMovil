package dev.iyscode.movil.assistant

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/**
 * Google tools for GUS on Android.
 *
 * Small local models are unreliable at emitting tool calls, so the read tools
 * run *before* the model: the request is routed with [AssistantCatalog.selectTools],
 * the matching Google data is fetched with the user's token, and the result is
 * added to the prompt. The model then answers with real data instead of
 * inventing it. Writes never run from here: GUS points the user to the
 * Asistente, where every write is confirmed.
 */
class GusGrounding(
    private val client: GoogleClient,
    private val grantedScopes: () -> Set<String>,
    private val now: () -> ZonedDateTime = { ZonedDateTime.now() },
) {
    data class Result(val context: String?, val toolsUsed: List<String>, val writeTool: AssistantTool?, val errors: List<String>)

    /** Read tools that would run for this message, given the granted permissions. */
    fun plannedReads(prompt: String): List<AssistantTool> {
        val scopes = grantedScopes()
        return AssistantCatalog.selectTools(prompt)
            .mapNotNull(AssistantCatalog::tool)
            .filter { it.mode == ToolMode.READ && it.service != null && it.service.isGranted(scopes) && it.service != GoogleService.SHEETS }
            .distinctBy { it.id }
            .take(3)
    }

    suspend fun ground(prompt: String, maxChars: Int = 900): Result {
        val writeTool = AssistantCatalog.selectTools(prompt).mapNotNull(AssistantCatalog::tool)
            .firstOrNull { it.mode == ToolMode.WRITE_CONFIRMED && it.service != null }
        val used = mutableListOf<String>()
        val errors = mutableListOf<String>()
        val sections = mutableListOf<String>()
        for (tool in plannedReads(prompt)) {
            try {
                val text = withTimeout(12_000) { read(tool.id) } ?: continue
                sections += "[${tool.serviceTitle}]\n$text"
                used += tool.id
            } catch (e: TimeoutCancellationException) {
                errors += "${tool.serviceTitle}: tardó demasiado"
            } catch (e: Exception) {
                errors += "${tool.serviceTitle}: ${e.message ?: "falló"}"
            }
        }
        val body = sections.joinToString("\n\n").take(maxChars)
        val context = if (body.isBlank()) null else
            "DATOS DE GOOGLE DEL USUARIO (consultados ahora con su permiso; respóndele con esto y no inventes otros):\n$body"
        return Result(context, used, writeTool, errors)
    }

    private suspend fun read(id: String): String? = when (id) {
        "gmail.read.inbox" -> client.recentMail(max = 5).takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.subject} — de ${it.from}: ${it.snippet.take(120)}" } ?: "Sin correos recientes."
        "googlecalendar.read.events" -> client.upcomingEvents(now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME), max = 6)
            .takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.start.replace('T', ' ').take(16)} ${it.title}${if (it.location.isBlank()) "" else " (${it.location})"}" }
            ?: "Sin eventos próximos."
        "googletasks.read.list" -> client.openTasks(max = 10).takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.title}" } ?: "Sin pendientes abiertos."
        "googledrive.read.files" -> client.recentFiles(max = 6).takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.name} (${it.modified.take(10)})" } ?: "Sin archivos recientes."
        "googlecontacts.read.lookup" -> client.contacts(max = 15).takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.name} <${it.email}>" } ?: "Sin contactos."
        "googleclassroom.read.courses" -> client.courses().takeIf { it.isNotEmpty() }
            ?.joinToString("\n") { "- ${it.name}" } ?: "Sin cursos activos."
        else -> null
    }
}

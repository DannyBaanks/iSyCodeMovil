package dev.iyscode.movil.assistant

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

// Monitor tipo raw.github: el daemon de iSyCode / IsyMCP en tu PC publica un
// manifiesto JSON (por ejemplo en raw.githubusercontent.com o en tu red local)
// y el teléfono lo consulta con ETag. Cada tarea nueva llega como notificación.
// El formato está en docs/GOOGLE_ASSISTANT.md y es el mismo en iOS.

@Serializable
data class DaemonTask(
    val id: String,
    val title: String,
    val body: String = "",
    val source: String = "pc",
    val status: String = "completed",
    val createdAt: String = "",
)

sealed interface ManifestPoll {
    data class Changed(val tasks: List<DaemonTask>, val etag: String?) : ManifestPoll
    data object NotModified : ManifestPoll
}

object DaemonManifest {
    private val json = Json { ignoreUnknownKeys = true }
    const val MAX_TASKS = 50

    /** Accepts `{"tasks":[…]}` or a bare array. Entries without id or title are skipped. */
    fun parse(body: String): List<DaemonTask> {
        val root = json.parseToJsonElement(body)
        val items: List<JsonElement> = when (root) {
            is JsonArray -> root
            is JsonObject -> (root["tasks"] as? JsonArray) ?: emptyList()
            else -> emptyList()
        }
        return items.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            fun field(key: String) = (obj[key] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
            val id = field("id")
            val title = field("title")
            if (id.isEmpty() || title.isEmpty()) return@mapNotNull null
            DaemonTask(
                id = id.take(120),
                title = title.take(200),
                body = field("body").ifEmpty { field("summary") }.take(1000),
                source = field("source").ifEmpty { "pc" }.take(40),
                status = field("status").ifEmpty { "completed" }.take(40),
                createdAt = field("createdAt").take(40),
            )
        }.take(MAX_TASKS)
    }

    /** Tasks the phone has not announced yet, in manifest order. */
    fun newTasks(seenIds: Set<String>, incoming: List<DaemonTask>): List<DaemonTask> =
        incoming.filter { it.id !in seenIds }

    /** Only https, or http inside the local network where the PC daemon usually lives. */
    fun isAllowedUrl(value: String): Boolean {
        val url = value.trim()
        if (url.startsWith("https://")) return url.length > "https://".length + 3
        if (!url.startsWith("http://")) return false
        val host = url.removePrefix("http://").substringBefore('/').substringBefore(':')
        return host == "localhost" || host.endsWith(".local") || host.startsWith("192.168.") ||
            host.startsWith("10.") || Regex("^172\\.(1[6-9]|2\\d|3[01])\\.").containsMatchIn(host)
    }
}

class DaemonManifestClient(
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build(),
) {
    suspend fun poll(url: String, etag: String?): ManifestPoll = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url.trim()).header("Cache-Control", "no-cache").apply {
            if (!etag.isNullOrEmpty()) header("If-None-Match", etag)
        }.build()
        http.newCall(request).execute().use { response ->
            when {
                response.code == 304 -> ManifestPoll.NotModified
                response.isSuccessful -> ManifestPoll.Changed(
                    DaemonManifest.parse(response.body?.string().orEmpty()), response.header("ETag"))
                else -> throw GoogleApiException(response.code, "El manifiesto respondió HTTP ${response.code}.")
            }
        }
    }
}

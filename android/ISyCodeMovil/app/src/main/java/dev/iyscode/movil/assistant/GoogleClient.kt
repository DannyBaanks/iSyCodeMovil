package dev.iyscode.movil.assistant

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * Calls Google's REST APIs with the user's own OAuth token. Every write
 * method is only reached after the UI showed a confirmation dialog.
 * Same endpoints as Sources/Assistant/GoogleClient.swift.
 */
class GoogleClient(
    private val tokenProvider: suspend () -> String,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build(),
    private val baseOverride: String? = null,
) {
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private fun url(host: String, path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        val base = (baseOverride ?: "https://$host").trimEnd('/')
        val builder = "$base$path".toHttpUrl().newBuilder()
        query.forEach { (key, value) -> builder.addQueryParameter(key, value) }
        return builder.build()
    }

    private suspend fun call(url: HttpUrl, method: String = "GET", body: String? = null): String =
        withContext(Dispatchers.IO) {
            val token = tokenProvider()
            val request = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer $token")
                .method(method, body?.toRequestBody(jsonType))
                .build()
            http.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    val reason = GoogleParsers.errorMessage(text) ?: "HTTP ${response.code}"
                    throw GoogleApiException(response.code, when (response.code) {
                        401 -> "Tu sesión de Google expiró. Vuelve a conectar tu cuenta."
                        403 -> "Google rechazó el permiso: $reason. Revisa que la API esté habilitada y que diste acceso."
                        else -> reason
                    })
                }
                text
            }
        }

    // ── Gmail ───────────────────────────────────────────────────────────────

    suspend fun recentMail(max: Int = 6, query: String = "in:inbox"): List<MailSummary> {
        val list = call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages",
            mapOf("maxResults" to max.toString(), "q" to query)))
        return GoogleParsers.messageIds(list).map { id ->
            GoogleParsers.message(call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages/$id",
                mapOf("format" to "metadata", "metadataHeaders" to "From"))
                .newBuilder().addQueryParameter("metadataHeaders", "Subject").addQueryParameter("metadataHeaders", "Date").build()))
        }
    }

    suspend fun sendMail(to: String, subject: String, body: String) {
        val payload = buildJsonObject { put("raw", AssistantCatalog.encodeGmailRaw(to, subject, body)) }
        call(url("gmail.googleapis.com", "/gmail/v1/users/me/messages/send"), "POST", payload.toString())
    }

    // ── Calendar ────────────────────────────────────────────────────────────

    suspend fun upcomingEvents(nowIso: String, max: Int = 8): List<EventSummary> =
        GoogleParsers.events(call(url("www.googleapis.com", "/calendar/v3/calendars/primary/events", mapOf(
            "timeMin" to nowIso, "maxResults" to max.toString(), "singleEvents" to "true", "orderBy" to "startTime"))))

    suspend fun createEvent(title: String, startIso: String, endIso: String, location: String, timeZone: String): EventSummary {
        val payload = buildJsonObject {
            put("summary", title)
            if (location.isNotBlank()) put("location", location)
            putJsonObject("start") { put("dateTime", startIso); put("timeZone", timeZone) }
            putJsonObject("end") { put("dateTime", endIso); put("timeZone", timeZone) }
        }
        val created = call(url("www.googleapis.com", "/calendar/v3/calendars/primary/events"), "POST", payload.toString())
        return GoogleParsers.events("{\"items\":[$created]}").first()
    }

    // ── Tasks ───────────────────────────────────────────────────────────────

    suspend fun openTasks(max: Int = 20): List<TaskItem> =
        GoogleParsers.tasks(call(url("tasks.googleapis.com", "/tasks/v1/lists/@default/tasks",
            mapOf("maxResults" to max.toString(), "showCompleted" to "false"))))

    suspend fun createTask(title: String, notes: String) {
        val payload = buildJsonObject { put("title", title); if (notes.isNotBlank()) put("notes", notes) }
        call(url("tasks.googleapis.com", "/tasks/v1/lists/@default/tasks"), "POST", payload.toString())
    }

    // ── Drive / Docs ────────────────────────────────────────────────────────

    suspend fun recentFiles(max: Int = 8): List<DriveFile> =
        GoogleParsers.files(call(url("www.googleapis.com", "/drive/v3/files", mapOf(
            "pageSize" to max.toString(), "orderBy" to "modifiedTime desc", "q" to "trashed = false",
            "fields" to "files(id,name,mimeType,modifiedTime,webViewLink)"))))

    /** Creates a Google Doc and writes the text into it. Returns the document ID. */
    suspend fun createDoc(title: String, text: String): String {
        val created = call(url("docs.googleapis.com", "/v1/documents"), "POST", buildJsonObject { put("title", title) }.toString())
        val id = GoogleParsers.documentId(created)
        if (text.isNotBlank()) {
            val update = buildJsonObject {
                putJsonArray("requests") {
                    add(buildJsonObject {
                        putJsonObject("insertText") {
                            putJsonObject("location") { put("index", 1) }
                            put("text", text)
                        }
                    })
                }
            }
            call(url("docs.googleapis.com", "/v1/documents/$id:batchUpdate"), "POST", update.toString())
        }
        return id
    }

    // ── Contacts / Classroom / Sheets ───────────────────────────────────────

    suspend fun contacts(max: Int = 20): List<Contact> =
        GoogleParsers.contacts(call(url("people.googleapis.com", "/v1/people/me/connections", mapOf(
            "pageSize" to max.toString(), "personFields" to "names,emailAddresses,organizations", "sortOrder" to "LAST_MODIFIED_DESCENDING"))))

    suspend fun courses(): List<Course> =
        GoogleParsers.courses(call(url("classroom.googleapis.com", "/v1/courses", mapOf("courseStates" to "ACTIVE", "pageSize" to "10"))))

    suspend fun postAnnouncement(courseId: String, text: String) {
        call(url("classroom.googleapis.com", "/v1/courses/$courseId/announcements"), "POST",
            buildJsonObject { put("text", text); put("state", "PUBLISHED") }.toString())
    }

    private fun a1(tab: String, range: String) = "'${tab.replace("'", "''")}'!$range"

    /** Reads the first rows of the first tab. The tab name comes from the file, not a guess. */
    suspend fun readSheet(spreadsheet: String, range: String = "A1:E15"): SheetData {
        val id = GoogleParsers.spreadsheetId(spreadsheet)
        val tab = GoogleParsers.firstSheetTitle(call(url("sheets.googleapis.com", "/v4/spreadsheets/$id",
            mapOf("fields" to "sheets.properties.title")))).ifEmpty { "Sheet1" }
        val rows = GoogleParsers.sheetRows(call(url("sheets.googleapis.com",
            "/v4/spreadsheets/$id/values/${URLEncoder.encode(a1(tab, range), "UTF-8").replace("+", "%20")}")))
        return SheetData(tab, rows)
    }

    suspend fun appendRow(spreadsheet: String, values: List<String>) {
        val id = GoogleParsers.spreadsheetId(spreadsheet)
        val tab = GoogleParsers.firstSheetTitle(call(url("sheets.googleapis.com", "/v4/spreadsheets/$id",
            mapOf("fields" to "sheets.properties.title")))).ifEmpty { "Sheet1" }
        val payload = buildJsonObject {
            put("values", buildJsonArray { add(JsonArray(values.map { JsonPrimitive(it) })) })
        }
        val range = URLEncoder.encode(a1(tab, "A1"), "UTF-8").replace("+", "%20")
        call(url("sheets.googleapis.com", "/v4/spreadsheets/$id/values/$range:append",
            mapOf("valueInputOption" to "USER_ENTERED")), "POST", payload.toString())
    }

    companion object {
        /** Exchanges the authorization code (PKCE, no client secret). */
        suspend fun exchangeCode(http: OkHttpClient, clientId: String, code: String, verifier: String,
                                 redirectUri: String, now: Long): GoogleToken = withContext(Dispatchers.IO) {
            val form = FormBody.Builder()
                .add("client_id", clientId.trim()).add("code", code).add("code_verifier", verifier)
                .add("grant_type", "authorization_code").add("redirect_uri", redirectUri).build()
            http.newCall(Request.Builder().url(GoogleOAuth.TOKEN_ENDPOINT).post(form).build()).execute().use {
                GoogleOAuth.parseToken(it.body?.string().orEmpty(), now)
            }
        }

        suspend fun refresh(http: OkHttpClient, clientId: String, token: GoogleToken, now: Long): GoogleToken =
            withContext(Dispatchers.IO) {
                val refresh = token.refreshToken ?: throw GoogleApiException(401, "Vuelve a conectar tu cuenta de Google.")
                val form = FormBody.Builder()
                    .add("client_id", clientId.trim()).add("refresh_token", refresh).add("grant_type", "refresh_token").build()
                http.newCall(Request.Builder().url(GoogleOAuth.TOKEN_ENDPOINT).post(form).build()).execute().use {
                    GoogleOAuth.parseToken(it.body?.string().orEmpty(), now, token)
                }
            }

        suspend fun revoke(http: OkHttpClient, token: GoogleToken) = withContext(Dispatchers.IO) {
            runCatching {
                val form = FormBody.Builder().add("token", token.refreshToken ?: token.accessToken).build()
                http.newCall(Request.Builder().url(GoogleOAuth.REVOKE_ENDPOINT).post(form).build()).execute().close()
            }
        }
    }
}

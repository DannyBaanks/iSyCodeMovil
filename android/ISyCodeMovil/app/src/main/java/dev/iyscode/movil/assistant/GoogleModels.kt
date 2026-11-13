package dev.iyscode.movil.assistant

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

// Inicio de sesión con Google sin SDK: OAuth 2.0 para apps instaladas con PKCE.
// No hay secreto de cliente; el ID de cliente lo crea el usuario en Google Cloud
// (ver docs/GOOGLE_ASSISTANT.md). Misma lógica que Sources/Assistant/GoogleOAuth.swift.

@Serializable
data class GoogleToken(
    val accessToken: String,
    val refreshToken: String? = null,
    val expiresAt: Long = 0,
    val scopes: Set<String> = emptySet(),
    val email: String? = null,
) {
    fun isFresh(now: Long) = accessToken.isNotEmpty() && now < expiresAt - 60_000
}

object GoogleOAuth {
    const val AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    const val TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
    const val REVOKE_ENDPOINT = "https://oauth2.googleapis.com/revoke"
    /** Android clients redirect to the package name (enable "custom URI scheme" on the client). */
    const val ANDROID_REDIRECT = "dev.iyscode.movil:/oauth2redirect"
    private const val CLIENT_SUFFIX = ".apps.googleusercontent.com"
    private val baseScopes = listOf("openid", "email")
    private val json = Json { ignoreUnknownKeys = true }

    fun isPlausibleClientId(value: String): Boolean {
        val trimmed = value.trim()
        return trimmed.endsWith(CLIENT_SUFFIX) && trimmed.length > CLIENT_SUFFIX.length && !trimmed.contains(' ')
    }

    /** iOS clients redirect to the reversed client ID. */
    fun iosRedirect(clientId: String): String? {
        val trimmed = clientId.trim()
        if (!isPlausibleClientId(trimmed)) return null
        return "com.googleusercontent.apps.${trimmed.removeSuffix(CLIENT_SUFFIX)}:/oauth2redirect"
    }

    fun scopes(services: Collection<GoogleService>): List<String> =
        (baseScopes + services.flatMap { it.scopes }).distinct()

    private fun base64Url(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun newVerifier(): String = base64Url(ByteArray(32).also { SecureRandom().nextBytes(it) })

    fun challenge(verifier: String): String =
        base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))

    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8")

    fun authUrl(clientId: String, redirectUri: String, scopes: List<String>, challenge: String, state: String): String =
        AUTH_ENDPOINT + "?" + listOf(
            "client_id" to clientId.trim(),
            "redirect_uri" to redirectUri,
            "response_type" to "code",
            "scope" to scopes.joinToString(" "),
            "code_challenge" to challenge,
            "code_challenge_method" to "S256",
            "state" to state,
            "access_type" to "offline",
            "prompt" to "consent",
        ).joinToString("&") { (key, value) -> "$key=${enc(value)}" }

    private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull

    /** The e-mail inside an ID token. Display only: the token came straight from Google over TLS. */
    fun emailFromIdToken(idToken: String?): String? {
        val payload = idToken?.split(".")?.getOrNull(1) ?: return null
        return runCatching {
            val decoded = String(Base64.getUrlDecoder().decode(payload), Charsets.UTF_8)
            json.parseToJsonElement(decoded).jsonObject.string("email")
        }.getOrNull()
    }

    /** Parses a token response; a refresh keeps the previous refresh token, scopes and e-mail. */
    fun parseToken(body: String, now: Long, previous: GoogleToken? = null): GoogleToken {
        val obj = json.parseToJsonElement(body).jsonObject
        obj.string("error")?.let { error ->
            throw GoogleApiException(400, obj.string("error_description") ?: error)
        }
        val access = obj.string("access_token") ?: throw GoogleApiException(400, "Google no devolvió un token de acceso.")
        val expiresIn = (obj["expires_in"] as? JsonPrimitive)?.contentOrNull?.toLongOrNull() ?: 3600
        val scopes = obj.string("scope")?.split(" ")?.filter { it.isNotEmpty() }?.toSet()
        return GoogleToken(
            accessToken = access,
            refreshToken = obj.string("refresh_token") ?: previous?.refreshToken,
            expiresAt = now + expiresIn * 1000,
            scopes = scopes ?: previous?.scopes ?: emptySet(),
            email = emailFromIdToken(obj.string("id_token")) ?: previous?.email,
        )
    }
}

class GoogleApiException(val status: Int, message: String) : Exception(message)

data class MailSummary(val id: String, val from: String, val subject: String, val date: String, val snippet: String)
data class EventSummary(val id: String, val title: String, val start: String, val end: String, val location: String, val link: String)
data class TaskItem(val id: String, val title: String, val notes: String, val due: String)
data class DriveFile(val id: String, val name: String, val mimeType: String, val modified: String, val link: String)
data class Contact(val name: String, val email: String, val organization: String)
data class Course(val id: String, val name: String, val section: String)
data class SheetData(val tab: String, val rows: List<List<String>>)

/** Turns Google's JSON into the few fields the app shows. Missing fields become empty strings. */
object GoogleParsers {
    private val json = Json { ignoreUnknownKeys = true }

    private fun root(body: String): JsonObject = json.parseToJsonElement(body).jsonObject
    private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull ?: ""
    private fun JsonObject.obj(key: String) = this[key] as? JsonObject
    private fun JsonObject.objects(key: String): List<JsonObject> =
        (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
    private fun JsonElement.text() = (this as? JsonPrimitive)?.contentOrNull ?: ""

    fun messageIds(body: String): List<String> = root(body).objects("messages").map { it.string("id") }.filter { it.isNotEmpty() }

    fun message(body: String): MailSummary {
        val obj = root(body)
        val headers = obj.obj("payload")?.objects("headers").orEmpty()
        fun header(name: String) = headers.firstOrNull { it.string("name").equals(name, ignoreCase = true) }?.string("value") ?: ""
        return MailSummary(obj.string("id"), header("From"), header("Subject").ifEmpty { "(sin asunto)" }, header("Date"), obj.string("snippet"))
    }

    fun events(body: String): List<EventSummary> = root(body).objects("items").map { item ->
        fun time(key: String) = item.obj(key)?.let { it.string("dateTime").ifEmpty { it.string("date") } } ?: ""
        EventSummary(item.string("id"), item.string("summary").ifEmpty { "(sin título)" }, time("start"), time("end"),
            item.string("location"), item.string("htmlLink"))
    }

    fun tasks(body: String): List<TaskItem> = root(body).objects("items")
        .map { TaskItem(it.string("id"), it.string("title"), it.string("notes"), it.string("due")) }
        .filter { it.title.isNotBlank() }

    fun files(body: String): List<DriveFile> = root(body).objects("files").map {
        DriveFile(it.string("id"), it.string("name"), it.string("mimeType"), it.string("modifiedTime"), it.string("webViewLink"))
    }

    fun contacts(body: String): List<Contact> = root(body).objects("connections").map { person ->
        Contact(
            person.objects("names").firstOrNull()?.string("displayName") ?: "",
            person.objects("emailAddresses").firstOrNull()?.string("value") ?: "",
            person.objects("organizations").firstOrNull()?.string("name") ?: "",
        )
    }.filter { it.name.isNotEmpty() || it.email.isNotEmpty() }

    fun courses(body: String): List<Course> = root(body).objects("courses")
        .map { Course(it.string("id"), it.string("name"), it.string("section")) }

    fun firstSheetTitle(body: String): String =
        root(body).objects("sheets").firstOrNull()?.obj("properties")?.string("title") ?: ""

    fun sheetRows(body: String): List<List<String>> =
        (root(body)["values"] as? JsonArray)?.map { row -> (row as? JsonArray)?.map { it.text() } ?: emptyList() } ?: emptyList()

    fun documentId(body: String): String = root(body).string("documentId")

    /** Google's own explanation of a failed call, when the body carries one. */
    fun errorMessage(body: String): String? = runCatching {
        val error = root(body)["error"]
        when (error) {
            is JsonObject -> error.string("message").ifEmpty { null }
            is JsonPrimitive -> root(body).string("error_description").ifEmpty { error.contentOrNull }
            else -> null
        }
    }.getOrNull()

    /** A spreadsheet ID from either the bare ID or a full docs.google.com link. */
    fun spreadsheetId(input: String): String {
        val trimmed = input.trim()
        return Regex("/spreadsheets/d/([A-Za-z0-9_-]+)").find(trimmed)?.groupValues?.get(1) ?: trimmed
    }
}

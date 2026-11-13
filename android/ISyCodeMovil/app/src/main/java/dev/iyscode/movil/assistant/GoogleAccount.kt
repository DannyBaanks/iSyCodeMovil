package dev.iyscode.movil.assistant

import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient

/**
 * The connected Google account, shared by the Asistente screens and by GUS.
 * The token lives in the app's private preferences (allowBackup=false keeps it
 * on this phone) and is refreshed when it expires.
 */
class GoogleAccount(context: Context, private val http: OkHttpClient = OkHttpClient()) {
    private val secrets = context.getSharedPreferences("assistant_google", Context.MODE_PRIVATE)
    private val prefs = context.getSharedPreferences("assistant", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Mutex()

    fun token(): GoogleToken? = secrets.getString("token", null)
        ?.let { runCatching { json.decodeFromString(GoogleToken.serializer(), it) }.getOrNull() }

    fun save(token: GoogleToken) =
        secrets.edit().putString("token", json.encodeToString(GoogleToken.serializer(), token)).apply()

    fun grantedScopes(): Set<String> = token()?.scopes ?: emptySet()

    suspend fun accessToken(): String = lock.withLock {
        val token = token() ?: throw GoogleApiException(401, "Conecta tu cuenta de Google primero.")
        if (token.isFresh(System.currentTimeMillis())) return token.accessToken
        val refreshed = GoogleClient.refresh(http, prefs.getString("clientId", "").orEmpty(), token, System.currentTimeMillis())
        save(refreshed)
        refreshed.accessToken
    }
}

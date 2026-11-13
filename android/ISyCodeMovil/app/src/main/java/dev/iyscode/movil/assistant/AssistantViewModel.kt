package dev.iyscode.movil.assistant

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.iyscode.movil.IsyCodeApp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID

enum class Appearance(val label: String) { AUTO("Automático"), DARK("Oscuro"), LIGHT("Claro") }

enum class LogLevel { INFO, TOOL, SUCCESS, ERROR }

data class LogEntry(
    val id: String,
    val time: Long,
    val level: LogLevel,
    val tool: String,
    val message: String,
    val retryable: Boolean = false,
) {
    /** Raw JSON for the "Copiar" button: everything needed to report the problem. */
    fun rawJson(): String = buildString {
        append("{\n")
        append("  \"id\": \"").append(id).append("\",\n")
        append("  \"time\": ").append(time).append(",\n")
        append("  \"level\": \"").append(level.name).append("\",\n")
        append("  \"tool\": \"").append(tool.replace("\"", "\\\"")).append("\",\n")
        append("  \"message\": \"").append(message.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")).append("\"\n")
        append("}")
    }
}

data class FeedItem(val id: String, val title: String, val body: String, val source: String, val time: Long)

/** A write waiting for the user's yes. Nothing reaches Google until [run] is called from the dialog. */
data class PendingAction(
    val title: String,
    val message: String,
    val details: List<Pair<String, String>>,
    val toolId: String,
    val run: suspend () -> String,
)

data class AssistantUi(
    val section: AssistantSection = AssistantSection.HOME,
    val developerMode: Boolean = false,
    val appearance: Appearance = Appearance.AUTO,
    val priorityContext: Boolean = false,
    val clientId: String = "",
    val email: String? = null,
    val grantedScopes: Set<String> = emptySet(),
    val enabledServices: Set<GoogleService> = GoogleService.entries.filter { it.defaultOn }.toSet(),
    val mail: List<MailSummary> = emptyList(),
    val events: List<EventSummary> = emptyList(),
    val tasks: List<TaskItem> = emptyList(),
    val files: List<DriveFile> = emptyList(),
    val contacts: List<Contact> = emptyList(),
    val courses: List<Course> = emptyList(),
    val sheetId: String = "",
    val sheet: SheetData? = null,
    val loading: Set<GoogleService> = emptySet(),
    val logs: List<LogEntry> = emptyList(),
    val feed: List<FeedItem> = emptyList(),
    val monitorUrl: String = "",
    val monitorEnabled: Boolean = false,
    val watchGmail: Boolean = false,
    val monitorStatus: String = "Apagado",
    val pending: PendingAction? = null,
    val running: Boolean = false,
    val message: String? = null,
) {
    val signedIn: Boolean get() = email != null || grantedScopes.isNotEmpty()
    fun granted(service: GoogleService) = service.isGranted(grantedScopes)
}

class AssistantViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as IsyCodeApp
    private val prefs = application.getSharedPreferences("assistant", Context.MODE_PRIVATE)
    // Tokens live in their own private file; allowBackup=false keeps them on this phone.
    private val secrets = application.getSharedPreferences("assistant_google", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val http = OkHttpClient()
    private val tokenLock = Mutex()
    private val retries = mutableMapOf<String, suspend () -> Unit>()
    private var monitorJob: Job? = null

    val memory: MemoryStore = app.memory
    val notifier: Notifier = app.notifier

    private val _ui = MutableStateFlow(AssistantUi(
        developerMode = prefs.getBoolean("developer", false),
        appearance = runCatching { Appearance.valueOf(prefs.getString("appearance", "AUTO")!!) }.getOrDefault(Appearance.AUTO),
        priorityContext = prefs.getBoolean(PRIORITY_KEY, false),
        clientId = prefs.getString("clientId", "").orEmpty(),
        enabledServices = prefs.getStringSet("services", null)
            ?.mapNotNull { runCatching { GoogleService.valueOf(it) }.getOrNull() }?.toSet()
            ?: GoogleService.entries.filter { it.defaultOn }.toSet(),
        sheetId = prefs.getString("sheetId", "").orEmpty(),
        monitorUrl = prefs.getString("monitorUrl", "").orEmpty(),
        monitorEnabled = prefs.getBoolean("monitorEnabled", false),
        watchGmail = prefs.getBoolean("watchGmail", false),
    ))
    val ui: StateFlow<AssistantUi> = _ui.asStateFlow()

    private val google = GoogleClient(tokenProvider = { validAccessToken() })

    init {
        loadToken()?.let { token -> _ui.update { it.copy(email = token.email, grantedScopes = token.scopes) } }
        log(LogLevel.INFO, "isycode.start", "Asistente listo. ${memory.nodes.value.size} notas en memoria.")
        restartMonitor()
    }

    // ── Preferences ─────────────────────────────────────────────────────────

    fun open(section: AssistantSection) = _ui.update { it.copy(section = section) }

    fun setDeveloperMode(on: Boolean) {
        prefs.edit().putBoolean("developer", on).apply()
        _ui.update {
            val section = if (!on && it.section.developerOnly) AssistantSection.OPTIONS else it.section
            it.copy(developerMode = on, section = section)
        }
    }

    /** Returns true when the activity must be recreated to apply the new colors. */
    fun setAppearance(value: Appearance): Boolean {
        if (value == _ui.value.appearance) return false
        prefs.edit().putString("appearance", value.name).apply()
        _ui.update { it.copy(appearance = value) }
        return true
    }

    fun setPriorityContext(on: Boolean) {
        prefs.edit().putBoolean(PRIORITY_KEY, on).apply()
        _ui.update { it.copy(priorityContext = on) }
    }

    fun setClientId(value: String) {
        prefs.edit().putString("clientId", value.trim()).apply()
        _ui.update { it.copy(clientId = value.trim()) }
    }

    fun toggleService(service: GoogleService, on: Boolean) {
        val next = if (on) _ui.value.enabledServices + service else _ui.value.enabledServices - service
        prefs.edit().putStringSet("services", next.map { it.name }.toSet()).apply()
        _ui.update { it.copy(enabledServices = next) }
    }

    fun setSheetId(value: String) {
        prefs.edit().putString("sheetId", value.trim()).apply()
        _ui.update { it.copy(sheetId = value.trim()) }
    }

    fun dismissMessage() = _ui.update { it.copy(message = null) }
    private fun say(text: String) = _ui.update { it.copy(message = text) }

    // ── Log & feed ──────────────────────────────────────────────────────────

    private fun log(level: LogLevel, tool: String, message: String, retry: (suspend () -> Unit)? = null) {
        val entry = LogEntry("log_" + UUID.randomUUID().toString().take(8), System.currentTimeMillis(), level, tool, message, retry != null)
        if (retry != null) retries[entry.id] = retry
        _ui.update { it.copy(logs = (listOf(entry) + it.logs).take(200)) }
    }

    fun retry(entry: LogEntry) {
        val action = retries.remove(entry.id) ?: return
        _ui.update { state -> state.copy(logs = state.logs.map { if (it.id == entry.id) it.copy(retryable = false) else it }) }
        log(LogLevel.TOOL, entry.tool, "Reintentando ${entry.tool}…")
        viewModelScope.launch { action() }
    }

    fun clearLogs() {
        retries.clear()
        _ui.update { it.copy(logs = emptyList()) }
    }

    private fun feed(title: String, body: String, source: String) {
        val item = FeedItem("feed_" + UUID.randomUUID().toString().take(8), title, body, source, System.currentTimeMillis())
        _ui.update { it.copy(feed = (listOf(item) + it.feed).take(50)) }
    }

    // ── Google sign-in (OAuth 2.0 + PKCE in the browser) ────────────────────

    /** The URL to open in the browser, or null with a message when setup is missing. */
    fun beginSignIn(): String? {
        val state = _ui.value
        if (!GoogleOAuth.isPlausibleClientId(state.clientId)) {
            say("Pega primero tu ID de cliente de Android (termina en .apps.googleusercontent.com). La guía está en Opciones.")
            return null
        }
        val verifier = GoogleOAuth.newVerifier()
        val nonce = UUID.randomUUID().toString()
        secrets.edit().putString("verifier", verifier).putString("state", nonce).apply()
        val scopes = GoogleOAuth.scopes(state.enabledServices)
        log(LogLevel.INFO, "google.oauth", "Abriendo Google para pedir: ${state.enabledServices.joinToString { it.title }}.")
        return GoogleOAuth.authUrl(state.clientId, GoogleOAuth.ANDROID_REDIRECT, scopes, GoogleOAuth.challenge(verifier), nonce)
    }

    fun completeSignIn(uri: Uri) {
        val expected = secrets.getString("state", null)
        val verifier = secrets.getString("verifier", null)
        secrets.edit().remove("state").remove("verifier").apply()
        uri.getQueryParameter("error")?.let { error ->
            say(if (error == "access_denied") "Cancelaste el acceso a Google." else "Google respondió: $error")
            return
        }
        val code = uri.getQueryParameter("code")
        if (code == null || verifier == null || expected == null || uri.getQueryParameter("state") != expected) {
            say("La respuesta de Google no coincide con esta solicitud. Intenta conectar de nuevo.")
            return
        }
        viewModelScope.launch {
            runCatching {
                GoogleClient.exchangeCode(http, _ui.value.clientId, code, verifier, GoogleOAuth.ANDROID_REDIRECT, System.currentTimeMillis())
            }.onSuccess { token ->
                saveToken(token)
                _ui.update { it.copy(email = token.email, grantedScopes = token.scopes) }
                val granted = GoogleService.entries.filter { it.isGranted(token.scopes) }
                log(LogLevel.SUCCESS, "google.oauth", "Cuenta conectada${token.email?.let { " ($it)" } ?: ""}. Permisos: ${granted.joinToString { it.title }}.")
                say("Listo, Google está conectado.")
                refreshAll()
            }.onFailure { error ->
                log(LogLevel.ERROR, "google.oauth", error.message ?: "No se pudo completar el inicio de sesión.")
                say(error.message ?: "No se pudo completar el inicio de sesión.")
            }
        }
    }

    fun signOut() {
        val token = loadToken()
        secrets.edit().clear().apply()
        _ui.update { it.copy(email = null, grantedScopes = emptySet(), mail = emptyList(), events = emptyList(),
            tasks = emptyList(), files = emptyList(), contacts = emptyList(), courses = emptyList(), sheet = null) }
        log(LogLevel.INFO, "google.oauth", "Cuenta de Google desconectada en este teléfono.")
        if (token != null) viewModelScope.launch { GoogleClient.revoke(http, token) }
    }

    private fun loadToken(): GoogleToken? = secrets.getString("token", null)
        ?.let { runCatching { json.decodeFromString(GoogleToken.serializer(), it) }.getOrNull() }

    private fun saveToken(token: GoogleToken) =
        secrets.edit().putString("token", json.encodeToString(GoogleToken.serializer(), token)).apply()

    private suspend fun validAccessToken(): String = tokenLock.withLock {
        val token = loadToken() ?: throw GoogleApiException(401, "Conecta tu cuenta de Google primero.")
        if (token.isFresh(System.currentTimeMillis())) return token.accessToken
        val refreshed = GoogleClient.refresh(http, _ui.value.clientId, token, System.currentTimeMillis())
        saveToken(refreshed)
        refreshed.accessToken
    }

    // ── Reading Google ──────────────────────────────────────────────────────

    fun refreshAll() = GoogleService.entries.filter { it in _ui.value.enabledServices && _ui.value.granted(it) }.forEach { refresh(it) }

    fun refresh(service: GoogleService) {
        val state = _ui.value
        if (!state.granted(service)) {
            say("Falta el permiso de ${service.title}. Actívalo en Google y vuelve a conectar.")
            return
        }
        val tool = when (service) {
            GoogleService.GMAIL -> "gmail.read.inbox"
            GoogleService.CALENDAR -> "googlecalendar.read.events"
            GoogleService.TASKS -> "googletasks.read.list"
            GoogleService.DRIVE -> "googledrive.read.files"
            GoogleService.CONTACTS -> "googlecontacts.read.lookup"
            GoogleService.SHEETS -> "googlesheets.read.range"
            GoogleService.CLASSROOM -> "googleclassroom.read.courses"
            GoogleService.DOCS -> return
        }
        if (service == GoogleService.SHEETS && state.sheetId.isBlank()) {
            say("Pega el enlace o ID de tu hoja de cálculo para leerla.")
            return
        }
        _ui.update { it.copy(loading = it.loading + service) }
        viewModelScope.launch {
            try {
                val count = when (service) {
                    GoogleService.GMAIL -> google.recentMail().also { list -> _ui.update { it.copy(mail = list) } }.size
                    GoogleService.CALENDAR -> google.upcomingEvents(isoNow()).also { list -> _ui.update { it.copy(events = list) } }.size
                    GoogleService.TASKS -> google.openTasks().also { list -> _ui.update { it.copy(tasks = list) } }.size
                    GoogleService.DRIVE -> google.recentFiles().also { list -> _ui.update { it.copy(files = list) } }.size
                    GoogleService.CONTACTS -> google.contacts().also { list -> _ui.update { it.copy(contacts = list) } }.size
                    GoogleService.CLASSROOM -> google.courses().also { list -> _ui.update { it.copy(courses = list) } }.size
                    GoogleService.SHEETS -> google.readSheet(state.sheetId).also { data -> _ui.update { it.copy(sheet = data) } }.rows.size
                    GoogleService.DOCS -> 0
                }
                log(LogLevel.SUCCESS, tool, "${service.title}: $count ${if (count == 1) "elemento" else "elementos"}.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log(LogLevel.ERROR, tool, e.message ?: "Falló la lectura de ${service.title}.") { refresh(service) }
            } finally {
                _ui.update { it.copy(loading = it.loading - service) }
            }
        }
    }

    private fun isoNow(): String = ZonedDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

    // ── Writes: always through a confirmation ───────────────────────────────

    private fun propose(action: PendingAction) {
        log(LogLevel.INFO, action.toolId, "Esperando tu confirmación: ${action.title}")
        _ui.update { it.copy(pending = action) }
    }

    fun cancelPending() {
        _ui.value.pending?.let { log(LogLevel.INFO, it.toolId, "Cancelado por ti: ${it.title}") }
        _ui.update { it.copy(pending = null) }
    }

    fun confirmPending() {
        val action = _ui.value.pending ?: return
        _ui.update { it.copy(running = true) }
        viewModelScope.launch {
            try {
                val result = action.run()
                log(LogLevel.SUCCESS, action.toolId, result)
                feed(action.title, result, action.toolId)
                notifier.post(Notifier.CHANNEL_GOOGLE, action.toolId + System.currentTimeMillis(), "Hecho: ${action.title}", result)
                say(result)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log(LogLevel.ERROR, action.toolId, e.message ?: "La acción falló.") { _ui.update { it.copy(pending = action) } }
                say(e.message ?: "La acción falló.")
            } finally {
                _ui.update { it.copy(pending = null, running = false) }
            }
        }
    }

    fun proposeEmail(to: String, subject: String, body: String) {
        if (!AssistantCatalog.isPlausibleEmail(to)) { say("Escribe un correo válido para el destinatario."); return }
        if (subject.isBlank() && body.isBlank()) { say("El correo está vacío."); return }
        propose(PendingAction("Enviar correo", "Se enviará desde tu cuenta de Gmail.",
            listOf("Para" to to.trim(), "Asunto" to subject.ifBlank { "(sin asunto)" }, "Mensaje" to body.take(400)),
            "gmail.write.send") { google.sendMail(to, subject, body); "Correo enviado a ${to.trim()}." })
    }

    fun proposeEvent(title: String, date: String, time: String, minutes: Int, location: String) {
        val start = runCatching {
            ZonedDateTime.of(LocalDate.parse(date.trim()), LocalTime.parse(time.trim()), ZoneId.systemDefault())
        }.getOrNull()
        if (title.isBlank() || start == null) { say("Escribe un título, la fecha como 2026-11-20 y la hora como 16:30."); return }
        val end = start.plusMinutes(minutes.coerceIn(5, 24 * 60).toLong())
        val format = DateTimeFormatter.ISO_OFFSET_DATE_TIME
        propose(PendingAction("Crear evento", "Se agregará a tu calendario principal.",
            listOf("Título" to title, "Inicio" to start.format(DateTimeFormatter.ofPattern("EEE d MMM, HH:mm")),
                "Duración" to "${end.toEpochSecond().minus(start.toEpochSecond()) / 60} min", "Lugar" to location.ifBlank { "—" }),
            "googlecalendar.write.event") {
            val created = google.createEvent(title, start.format(format), end.format(format), location, ZoneId.systemDefault().id)
            refresh(GoogleService.CALENDAR)
            "Evento creado: ${created.title}."
        })
    }

    fun proposeTask(title: String, notes: String) {
        if (title.isBlank()) { say("Escribe el pendiente."); return }
        propose(PendingAction("Agregar pendiente", "Se agregará a tu lista principal de Google Tasks.",
            listOf("Pendiente" to title, "Notas" to notes.ifBlank { "—" }), "googletasks.write.create") {
            google.createTask(title, notes); refresh(GoogleService.TASKS); "Pendiente agregado: $title."
        })
    }

    fun proposeDoc(title: String, text: String) {
        if (title.isBlank()) { say("Escribe el título del documento."); return }
        propose(PendingAction("Crear documento", "Se creará un Google Doc en tu Drive.",
            listOf("Título" to title, "Texto" to text.take(400).ifBlank { "—" }), "googledocs.write.create") {
            val id = google.createDoc(title, text); "Documento creado: https://docs.google.com/document/d/$id"
        })
    }

    fun proposeRow(values: List<String>) {
        val sheet = _ui.value.sheetId
        if (sheet.isBlank() || values.all { it.isBlank() }) { say("Indica la hoja y al menos un valor."); return }
        propose(PendingAction("Agregar fila", "Se agregará al final de la primera pestaña.",
            listOf("Hoja" to GoogleParsers.spreadsheetId(sheet).take(24) + "…", "Valores" to values.joinToString(" | ")),
            "googlesheets.write.append_row") {
            google.appendRow(sheet, values); refresh(GoogleService.SHEETS); "Fila agregada (${values.size} columnas)."
        })
    }

    fun proposeAnnouncement(course: Course, text: String) {
        if (text.isBlank()) { say("Escribe el anuncio."); return }
        propose(PendingAction("Publicar anuncio", "Lo verán todos los alumnos del curso.",
            listOf("Curso" to course.name, "Anuncio" to text.take(400)), "googleclassroom.write.announcement") {
            google.postAnnouncement(course.id, text); "Anuncio publicado en ${course.name}."
        })
    }

    // ── Memory (as.save.context / as.read.context_tree) ─────────────────────

    fun proposeMemory(title: String, summary: String, path: List<String>, priority: ContextPriority, source: String) {
        if (summary.isBlank()) { say("Escribe qué quieres que GUS recuerde."); return }
        val clean = SemanticContext.cleanPath(path)
        propose(PendingAction("Guardar en memoria", "GUS podrá usar esta nota en tus próximas preguntas.",
            listOf("Nota" to title.ifBlank { summary.take(60) }, "Carpeta" to clean.joinToString(" › "), "Prioridad" to priority.label),
            AssistantCatalog.SAVE_CONTEXT) {
            val node = memory.save(title, summary, clean, priority, source)
            "Guardado en ${node.path.joinToString(" › ")}."
        })
    }

    fun deleteMemory(node: ContextNode) {
        memory.delete(node.id)
        log(LogLevel.INFO, AssistantCatalog.SAVE_CONTEXT, "Nota borrada: ${node.title}")
    }

    fun previewRetrieval(prompt: String): Retrieval {
        val result = SemanticContext.retrieve(memory.nodes.value, prompt, _ui.value.priorityContext)
        log(LogLevel.TOOL, AssistantCatalog.READ_CONTEXT, "Recorrido: ${result.matchedPath.joinToString(" › ")} · ${result.nodes.size} notas.")
        return result
    }

    // ── Daemon monitor + Gmail watch ────────────────────────────────────────

    fun configureMonitor(url: String, enabled: Boolean, watchGmail: Boolean) {
        val clean = url.trim()
        if (enabled && clean.isNotEmpty() && !DaemonManifest.isAllowedUrl(clean)) {
            say("Usa una dirección https:// (o http:// solo dentro de tu red local).")
            return
        }
        prefs.edit().putString("monitorUrl", clean).putBoolean("monitorEnabled", enabled).putBoolean("watchGmail", watchGmail).apply()
        _ui.update { it.copy(monitorUrl = clean, monitorEnabled = enabled, watchGmail = watchGmail) }
        restartMonitor()
    }

    private fun restartMonitor() {
        monitorJob?.cancel()
        val state = _ui.value
        val manifestOn = state.monitorEnabled && state.monitorUrl.isNotBlank()
        if (!manifestOn && !state.watchGmail) {
            _ui.update { it.copy(monitorStatus = "Apagado") }
            return
        }
        monitorJob = viewModelScope.launch {
            val client = DaemonManifestClient()
            var tick = 0
            while (isActive) {
                if (manifestOn) pollManifest(client)
                if (_ui.value.watchGmail && tick % 2 == 0) pollGmail()
                tick += 1
                delay(POLL_MS)
            }
        }
    }

    private suspend fun pollManifest(client: DaemonManifestClient) {
        val url = _ui.value.monitorUrl
        try {
            when (val result = client.poll(url, prefs.getString("monitorEtag", null))) {
                ManifestPoll.NotModified -> _ui.update { it.copy(monitorStatus = "Conectado · sin cambios") }
                is ManifestPoll.Changed -> {
                    val seen = prefs.getStringSet("seenTasks", emptySet()).orEmpty()
                    val fresh = DaemonManifest.newTasks(seen, result.tasks)
                    // The first read only learns what already exists: no flood of old tasks.
                    val firstRun = !prefs.getBoolean("monitorPrimed", false)
                    if (!firstRun) fresh.forEach { task ->
                        log(LogLevel.TOOL, "isycode.daemon", "${task.source}: ${task.title}")
                        feed(task.title, task.body.ifBlank { "Estado: ${task.status}" }, task.source)
                        notifier.post(Notifier.CHANNEL_DAEMON, "task_${task.id}", "iSyCode · ${task.title}", task.body.ifBlank { task.status })
                    }
                    val ids = (result.tasks.map { it.id } + seen).take(400).toSet()
                    prefs.edit().putStringSet("seenTasks", ids).putString("monitorEtag", result.etag)
                        .putBoolean("monitorPrimed", true).apply()
                    _ui.update { it.copy(monitorStatus = if (firstRun) "Conectado · ${result.tasks.size} tareas conocidas" else "Conectado · ${fresh.size} nuevas") }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _ui.update { it.copy(monitorStatus = "Sin conexión: ${e.message ?: "error"}") }
        }
    }

    private suspend fun pollGmail() {
        if (!_ui.value.granted(GoogleService.GMAIL)) return
        try {
            val mail = google.recentMail(max = 5, query = "in:inbox is:unread")
            val seen = prefs.getStringSet("seenMail", null)
            val fresh = if (seen == null) emptyList() else mail.filter { it.id !in seen }
            fresh.forEach { message ->
                log(LogLevel.TOOL, "gmail.read.inbox", "Correo nuevo de ${message.from}: ${message.subject}")
                feed(message.subject, "De ${message.from}\n${message.snippet}", "gmail")
                notifier.post(Notifier.CHANNEL_GOOGLE, "mail_${message.id}", message.subject, "De ${message.from}: ${message.snippet}")
            }
            prefs.edit().putStringSet("seenMail", (mail.map { it.id } + seen.orEmpty()).take(200).toSet()).apply()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log(LogLevel.ERROR, "gmail.read.inbox", "Vigilancia de Gmail: ${e.message}")
        }
    }

    // ── Quick actions and the "¿Qué necesitas?" field ───────────────────────

    /** Returns a map search query when the caller should open the maps app. */
    fun runQuickAction(action: QuickAction): String? {
        log(LogLevel.TOOL, action.toolId, "Acción rápida: ${action.title}")
        when (action.kind) {
            QuickActionKind.REFRESH_SERVICE -> action.service?.let { service ->
                refresh(service)
                open(AssistantSection.GOOGLE)
            }
            QuickActionKind.OPEN_MAPS -> return ""
            QuickActionKind.SAVE_MEMORY -> open(AssistantSection.MEMORY)
        }
        return null
    }

    /** Routes a typed request to the matching tools. Returns a maps query if one applies. */
    fun ask(prompt: String): String? {
        val text = prompt.trim()
        if (text.isEmpty()) return null
        val tools = AssistantCatalog.selectTools(text)
        log(LogLevel.INFO, "isycode.route", "\"${text.take(80)}\" → ${tools.ifEmpty { listOf("GUS") }.joinToString()}")
        if (_ui.value.priorityContext) {
            proposeMemory(text.take(80), text, SemanticContext.inferPath(text), ContextPriority.CRITICAL, "prioritario")
            return null
        }
        val first = tools.firstOrNull()
        if (first == null) {
            say("No encontré una herramienta para eso. Pregúntale a GUS en la pestaña de chat.")
            return null
        }
        if (first == AssistantCatalog.MAPS_SEARCH) return text
        if (first == AssistantCatalog.SAVE_CONTEXT) {
            proposeMemory("", text, SemanticContext.inferPath(text), ContextPriority.HIGH, "asistente")
            return null
        }
        val service = AssistantCatalog.tool(first)?.service ?: return null
        if (AssistantCatalog.tool(first)?.mode == ToolMode.WRITE_CONFIRMED) {
            say("Completa los datos de ${service.title} y confirma antes de enviar.")
        } else {
            refresh(service)
        }
        open(AssistantSection.GOOGLE)
        return null
    }

    override fun onCleared() {
        monitorJob?.cancel()
        super.onCleared()
    }

    companion object {
        const val PRIORITY_KEY = "priorityContext"
        private const val POLL_MS = 30_000L

        /** Read by MainActivity before composing, so the right palette is used from the first frame. */
        fun storedAppearance(context: Context): Appearance =
            runCatching { Appearance.valueOf(context.getSharedPreferences("assistant", Context.MODE_PRIVATE).getString("appearance", "AUTO")!!) }
                .getOrDefault(Appearance.AUTO)
    }
}

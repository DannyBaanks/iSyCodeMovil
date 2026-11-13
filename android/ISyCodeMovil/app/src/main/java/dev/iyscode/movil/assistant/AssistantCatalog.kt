package dev.iyscode.movil.assistant

import java.util.Base64

// Qué puede hacer el asistente con Google y con la memoria, y qué acciones
// necesitan que el usuario confirme. Misma tabla que
// Sources/Assistant/AssistantCatalog.swift en iOS.

enum class GoogleService(val title: String, val detail: String, val scopes: List<String>, val defaultOn: Boolean) {
    GMAIL("Gmail", "Leer tu bandeja y enviar correos que confirmes",
        listOf("https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.send"), true),
    CALENDAR("Calendar", "Ver tu agenda y crear eventos que confirmes",
        listOf("https://www.googleapis.com/auth/calendar.events"), true),
    TASKS("Tasks", "Ver y crear pendientes",
        listOf("https://www.googleapis.com/auth/tasks"), true),
    DRIVE("Drive", "Ver tus archivos recientes (solo nombres y enlaces)",
        listOf("https://www.googleapis.com/auth/drive.metadata.readonly"), true),
    CONTACTS("Contactos", "Buscar nombres y correos",
        listOf("https://www.googleapis.com/auth/contacts.readonly"), true),
    DOCS("Docs", "Crear documentos que confirmes",
        listOf("https://www.googleapis.com/auth/documents"), false),
    SHEETS("Sheets", "Leer una hoja y agregar filas que confirmes",
        listOf("https://www.googleapis.com/auth/spreadsheets"), false),
    CLASSROOM("Classroom", "Ver tus cursos y publicar anuncios que confirmes",
        listOf("https://www.googleapis.com/auth/classroom.courses.readonly",
            "https://www.googleapis.com/auth/classroom.announcements"), false);

    fun isGranted(grantedScopes: Set<String>) = scopes.all { it in grantedScopes }
}

enum class ToolMode(val label: String) { READ("Lectura"), WRITE_CONFIRMED("Escritura con confirmación"), LOCAL("En el teléfono") }

data class AssistantTool(
    val id: String,
    val service: GoogleService?,
    val serviceTitle: String,
    val mode: ToolMode,
    val endpoint: String,
    val description: String,
)

enum class QuickActionKind { REFRESH_SERVICE, OPEN_MAPS, SAVE_MEMORY }

data class QuickAction(
    val id: String,
    val title: String,
    val subtitle: String,
    val toolId: String,
    val kind: QuickActionKind,
    val service: GoogleService? = null,
)

enum class AssistantSection(val title: String, val developerOnly: Boolean = false) {
    HOME("Inicio"), MEMORY("Memoria"), GOOGLE("Google"), LOG("Registro", developerOnly = true), OPTIONS("Opciones")
}

object AssistantCatalog {
    const val SAVE_CONTEXT = "as.save.context"
    const val READ_CONTEXT = "as.read.context_tree"
    const val MAPS_SEARCH = "maps.search.place"

    val tools: List<AssistantTool> = listOf(
        AssistantTool("gmail.read.inbox", GoogleService.GMAIL, "Gmail", ToolMode.READ,
            "GET gmail/v1/users/me/messages", "Lee los correos más recientes de tu bandeja de entrada."),
        AssistantTool("gmail.write.send", GoogleService.GMAIL, "Gmail", ToolMode.WRITE_CONFIRMED,
            "POST gmail/v1/users/me/messages/send", "Envía un correo en tu nombre después de que lo confirmes."),
        AssistantTool("googlecalendar.read.events", GoogleService.CALENDAR, "Calendar", ToolMode.READ,
            "GET calendar/v3/calendars/primary/events", "Muestra tus próximos eventos."),
        AssistantTool("googlecalendar.write.event", GoogleService.CALENDAR, "Calendar", ToolMode.WRITE_CONFIRMED,
            "POST calendar/v3/calendars/primary/events", "Crea un evento después de que lo confirmes."),
        AssistantTool("googletasks.read.list", GoogleService.TASKS, "Tasks", ToolMode.READ,
            "GET tasks/v1/lists/@default/tasks", "Lista tus pendientes abiertos."),
        AssistantTool("googletasks.write.create", GoogleService.TASKS, "Tasks", ToolMode.WRITE_CONFIRMED,
            "POST tasks/v1/lists/@default/tasks", "Agrega un pendiente después de que lo confirmes."),
        AssistantTool("googledrive.read.files", GoogleService.DRIVE, "Drive", ToolMode.READ,
            "GET drive/v3/files", "Lista tus archivos modificados recientemente."),
        AssistantTool("googledocs.write.create", GoogleService.DOCS, "Docs", ToolMode.WRITE_CONFIRMED,
            "POST docs/v1/documents + :batchUpdate", "Crea un documento con el texto que confirmes."),
        AssistantTool("googlecontacts.read.lookup", GoogleService.CONTACTS, "Contactos", ToolMode.READ,
            "GET people/v1/people/me/connections", "Busca nombres, correos y organización de tus contactos."),
        AssistantTool("googlesheets.read.range", GoogleService.SHEETS, "Sheets", ToolMode.READ,
            "GET sheets/v4/spreadsheets/{id}/values/{rango}", "Lee las primeras filas de la hoja que indiques."),
        AssistantTool("googlesheets.write.append_row", GoogleService.SHEETS, "Sheets", ToolMode.WRITE_CONFIRMED,
            "POST sheets/v4/spreadsheets/{id}/values/{rango}:append", "Agrega una fila después de que lo confirmes."),
        AssistantTool("googleclassroom.read.courses", GoogleService.CLASSROOM, "Classroom", ToolMode.READ,
            "GET classroom/v1/courses", "Lista tus cursos activos."),
        AssistantTool("googleclassroom.write.announcement", GoogleService.CLASSROOM, "Classroom", ToolMode.WRITE_CONFIRMED,
            "POST classroom/v1/courses/{id}/announcements", "Publica un anuncio después de que lo confirmes."),
        AssistantTool(MAPS_SEARCH, null, "Mapas", ToolMode.LOCAL,
            "App de mapas del teléfono", "Abre la búsqueda de un lugar en tu app de mapas."),
        AssistantTool(SAVE_CONTEXT, null, "Memoria", ToolMode.WRITE_CONFIRMED,
            "Archivo local memoria.json", "Guarda una nota en carpetas de tres niveles después de que la confirmes."),
        AssistantTool(READ_CONTEXT, null, "Memoria", ToolMode.LOCAL,
            "Archivo local memoria.json", "Elige las notas guardadas que vienen al caso y las pasa a GUS."),
    )

    val quickActions: List<QuickAction> = listOf(
        QuickAction("qa-inbox", "Revisar mi correo", "Tus correos más recientes de Gmail",
            "gmail.read.inbox", QuickActionKind.REFRESH_SERVICE, GoogleService.GMAIL),
        QuickAction("qa-calendar", "Ver mi agenda", "Tus próximos eventos de Calendar",
            "googlecalendar.read.events", QuickActionKind.REFRESH_SERVICE, GoogleService.CALENDAR),
        QuickAction("qa-tasks", "Mis pendientes", "Lo que tienes abierto en Tasks",
            "googletasks.read.list", QuickActionKind.REFRESH_SERVICE, GoogleService.TASKS),
        QuickAction("qa-drive", "Archivos recientes", "Lo último que cambió en tu Drive",
            "googledrive.read.files", QuickActionKind.REFRESH_SERVICE, GoogleService.DRIVE),
        QuickAction("qa-maps", "Buscar un lugar", "Abre la búsqueda en tu app de mapas",
            MAPS_SEARCH, QuickActionKind.OPEN_MAPS),
        QuickAction("qa-memory", "Guardar en memoria", "Una nota que GUS recordará después",
            SAVE_CONTEXT, QuickActionKind.SAVE_MEMORY),
    )

    fun tool(id: String): AssistantTool? = tools.firstOrNull { it.id == id }

    fun sections(developerMode: Boolean): List<AssistantSection> =
        AssistantSection.entries.filter { developerMode || !it.developerOnly }

    private fun has(text: String, vararg terms: String) = terms.any { text.contains(it) }

    /** Tools that fit what the user typed, most specific first. Used by the "¿Qué necesitas?" field. */
    fun selectTools(prompt: String): List<String> {
        val text = SemanticContext.normalize(prompt)
        val ids = LinkedHashSet<String>()
        if (has(text, "recuerda", "recordar", "memoria", "guarda esto", "guardar nota", "no olvides")) ids += SAVE_CONTEXT
        if (has(text, "correo", "email", "gmail", "inbox", "bandeja", "mail")) {
            if (has(text, "envia", "enviar", "manda", "responde", "redacta", "escribe")) ids += "gmail.write.send"
            ids += "gmail.read.inbox"
        }
        if (has(text, "calendar", "calendario", "agenda", "reunion", "cita", "evento")) {
            if (has(text, "agendar", "agenda una", "crea", "crear", "programa", "nuevo evento", "nueva reunion")) ids += "googlecalendar.write.event"
            ids += "googlecalendar.read.events"
        }
        if (has(text, "pendiente", "tasks", "to-do", "todo", "lista de tareas", "por hacer")) {
            if (has(text, "agrega", "agregar", "crea", "crear", "anota", "nuevo", "nueva")) ids += "googletasks.write.create"
            ids += "googletasks.read.list"
        }
        if (has(text, "drive", "archivo", "carpeta")) ids += "googledrive.read.files"
        if (has(text, "docs", "documento", "minuta", "reporte")) ids += "googledocs.write.create"
        if (has(text, "contacto", "telefono de", "correo de", "directorio")) ids += "googlecontacts.read.lookup"
        if (has(text, "sheets", "hoja de calculo", "spreadsheet", "fila", "tabla")) {
            if (has(text, "agrega", "agregar", "inserta", "anota", "registra")) ids += "googlesheets.write.append_row"
            ids += "googlesheets.read.range"
        }
        if (has(text, "classroom", "curso", "clase", "anuncio")) {
            if (has(text, "publica", "publicar", "anuncia", "avisa")) ids += "googleclassroom.write.announcement"
            ids += "googleclassroom.read.courses"
        }
        if (has(text, "mapa", "maps", "ubicacion", "direccion", "cerca", "ruta", "como llegar", "restaurante", "cafe")) ids += MAPS_SEARCH
        return ids.toList()
    }

    /** Anything that changes the user's data needs a visible yes first. */
    fun requiresConfirmation(toolIds: List<String>): Boolean =
        toolIds.any { tool(it)?.mode == ToolMode.WRITE_CONFIRMED }

    private fun headerSafe(value: String) = value.replace(Regex("[\\r\\n]+"), " ").trim()

    /** RFC 2822 message, base64url, as Gmail's `messages/send` expects in `raw`. */
    fun encodeGmailRaw(to: String, subject: String, body: String): String {
        val encodedSubject = Base64.getEncoder().encodeToString(headerSafe(subject).toByteArray(Charsets.UTF_8))
        val mime = listOf(
            "To: ${headerSafe(to)}",
            "Subject: =?utf-8?B?$encodedSubject?=",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "",
            body,
        ).joinToString("\r\n")
        return Base64.getUrlEncoder().withoutPadding().encodeToString(mime.toByteArray(Charsets.UTF_8))
    }

    fun isPlausibleEmail(value: String): Boolean =
        Regex("^[^\\s@,;]+@[^\\s@,;]+\\.[^\\s@,;]+$").matches(value.trim())
}

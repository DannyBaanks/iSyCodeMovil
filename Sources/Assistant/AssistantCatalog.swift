import Foundation

// Qué puede hacer el asistente con Google y con la memoria, y qué acciones
// necesitan que el usuario confirme. Misma tabla que
// android/.../assistant/AssistantCatalog.kt.

public enum GoogleService: String, CaseIterable, Codable, Identifiable, Sendable {
    case gmail = "GMAIL", calendar = "CALENDAR", tasks = "TASKS", drive = "DRIVE",
         contacts = "CONTACTS", docs = "DOCS", sheets = "SHEETS", classroom = "CLASSROOM"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .calendar: return "Calendar"
        case .tasks: return "Tasks"
        case .drive: return "Drive"
        case .contacts: return "Contactos"
        case .docs: return "Docs"
        case .sheets: return "Sheets"
        case .classroom: return "Classroom"
        }
    }

    public var detail: String {
        switch self {
        case .gmail: return "Leer tu bandeja y enviar correos que confirmes"
        case .calendar: return "Ver tu agenda y crear eventos que confirmes"
        case .tasks: return "Ver y crear pendientes"
        case .drive: return "Ver tus archivos recientes (solo nombres y enlaces)"
        case .contacts: return "Buscar nombres y correos"
        case .docs: return "Crear documentos que confirmes"
        case .sheets: return "Leer una hoja y agregar filas que confirmes"
        case .classroom: return "Ver tus cursos y publicar anuncios que confirmes"
        }
    }

    public var symbol: String {
        switch self {
        case .gmail: return "envelope"
        case .calendar: return "calendar"
        case .tasks: return "checklist"
        case .drive: return "folder"
        case .contacts: return "person.2"
        case .docs: return "doc.text"
        case .sheets: return "tablecells"
        case .classroom: return "graduationcap"
        }
    }

    public var scopes: [String] {
        switch self {
        case .gmail: return ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.send"]
        case .calendar: return ["https://www.googleapis.com/auth/calendar.events"]
        case .tasks: return ["https://www.googleapis.com/auth/tasks"]
        case .drive: return ["https://www.googleapis.com/auth/drive.metadata.readonly"]
        case .contacts: return ["https://www.googleapis.com/auth/contacts.readonly"]
        case .docs: return ["https://www.googleapis.com/auth/documents"]
        case .sheets: return ["https://www.googleapis.com/auth/spreadsheets"]
        case .classroom: return ["https://www.googleapis.com/auth/classroom.courses.readonly",
                                 "https://www.googleapis.com/auth/classroom.announcements"]
        }
    }

    public var defaultOn: Bool {
        switch self {
        case .gmail, .calendar, .tasks, .drive, .contacts: return true
        case .docs, .sheets, .classroom: return false
        }
    }

    public func isGranted(_ granted: Set<String>) -> Bool { scopes.allSatisfy(granted.contains) }
}

public enum ToolMode: String, Sendable {
    case read, writeConfirmed, local

    public var label: String {
        switch self {
        case .read: return "Lectura"
        case .writeConfirmed: return "Escritura con confirmación"
        case .local: return "En el teléfono"
        }
    }
}

public struct AssistantToolInfo: Identifiable, Sendable {
    public let id: String
    public let service: GoogleService?
    public let serviceTitle: String
    public let mode: ToolMode
    public let endpoint: String
    public let description: String
}

public enum QuickActionKind: Sendable { case refreshService, openMaps, saveMemory }

public struct QuickAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let toolId: String
    public let kind: QuickActionKind
    public let service: GoogleService?
    public let symbol: String
}

public enum AssistantSection: String, CaseIterable, Identifiable, Sendable {
    case home, memory, google, log, options

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Inicio"
        case .memory: return "Memoria"
        case .google: return "Google"
        case .log: return "Registro"
        case .options: return "Opciones"
        }
    }

    public var symbol: String {
        switch self {
        case .home: return "sparkles"
        case .memory: return "brain"
        case .google: return "square.grid.2x2"
        case .log: return "list.bullet.rectangle"
        case .options: return "slider.horizontal.3"
        }
    }

    public var developerOnly: Bool { self == .log }
}

public enum AssistantCatalog {
    public static let saveContext = "as.save.context"
    public static let readContext = "as.read.context_tree"
    public static let mapsSearch = "maps.search.place"

    public static let tools: [AssistantToolInfo] = [
        .init(id: "gmail.read.inbox", service: .gmail, serviceTitle: "Gmail", mode: .read,
              endpoint: "GET gmail/v1/users/me/messages", description: "Lee los correos más recientes de tu bandeja de entrada."),
        .init(id: "gmail.write.send", service: .gmail, serviceTitle: "Gmail", mode: .writeConfirmed,
              endpoint: "POST gmail/v1/users/me/messages/send", description: "Envía un correo en tu nombre después de que lo confirmes."),
        .init(id: "googlecalendar.read.events", service: .calendar, serviceTitle: "Calendar", mode: .read,
              endpoint: "GET calendar/v3/calendars/primary/events", description: "Muestra tus próximos eventos."),
        .init(id: "googlecalendar.write.event", service: .calendar, serviceTitle: "Calendar", mode: .writeConfirmed,
              endpoint: "POST calendar/v3/calendars/primary/events", description: "Crea un evento después de que lo confirmes."),
        .init(id: "googletasks.read.list", service: .tasks, serviceTitle: "Tasks", mode: .read,
              endpoint: "GET tasks/v1/lists/@default/tasks", description: "Lista tus pendientes abiertos."),
        .init(id: "googletasks.write.create", service: .tasks, serviceTitle: "Tasks", mode: .writeConfirmed,
              endpoint: "POST tasks/v1/lists/@default/tasks", description: "Agrega un pendiente después de que lo confirmes."),
        .init(id: "googledrive.read.files", service: .drive, serviceTitle: "Drive", mode: .read,
              endpoint: "GET drive/v3/files", description: "Lista tus archivos modificados recientemente."),
        .init(id: "googledocs.write.create", service: .docs, serviceTitle: "Docs", mode: .writeConfirmed,
              endpoint: "POST docs/v1/documents + :batchUpdate", description: "Crea un documento con el texto que confirmes."),
        .init(id: "googlecontacts.read.lookup", service: .contacts, serviceTitle: "Contactos", mode: .read,
              endpoint: "GET people/v1/people/me/connections", description: "Busca nombres, correos y organización de tus contactos."),
        .init(id: "googlesheets.read.range", service: .sheets, serviceTitle: "Sheets", mode: .read,
              endpoint: "GET sheets/v4/spreadsheets/{id}/values/{rango}", description: "Lee las primeras filas de la hoja que indiques."),
        .init(id: "googlesheets.write.append_row", service: .sheets, serviceTitle: "Sheets", mode: .writeConfirmed,
              endpoint: "POST sheets/v4/spreadsheets/{id}/values/{rango}:append", description: "Agrega una fila después de que lo confirmes."),
        .init(id: "googleclassroom.read.courses", service: .classroom, serviceTitle: "Classroom", mode: .read,
              endpoint: "GET classroom/v1/courses", description: "Lista tus cursos activos."),
        .init(id: "googleclassroom.write.announcement", service: .classroom, serviceTitle: "Classroom", mode: .writeConfirmed,
              endpoint: "POST classroom/v1/courses/{id}/announcements", description: "Publica un anuncio después de que lo confirmes."),
        .init(id: mapsSearch, service: nil, serviceTitle: "Mapas", mode: .local,
              endpoint: "App de mapas del teléfono", description: "Abre la búsqueda de un lugar en tu app de mapas."),
        .init(id: saveContext, service: nil, serviceTitle: "Memoria", mode: .writeConfirmed,
              endpoint: "Archivo local memory.json", description: "Guarda una nota en carpetas de tres niveles después de que la confirmes."),
        .init(id: readContext, service: nil, serviceTitle: "Memoria", mode: .local,
              endpoint: "Archivo local memory.json", description: "Elige las notas guardadas que vienen al caso y las pasa al modelo."),
    ]

    public static let quickActions: [QuickAction] = [
        .init(id: "qa-inbox", title: "Revisar mi correo", subtitle: "Tus correos más recientes de Gmail",
              toolId: "gmail.read.inbox", kind: .refreshService, service: .gmail, symbol: "envelope"),
        .init(id: "qa-calendar", title: "Ver mi agenda", subtitle: "Tus próximos eventos de Calendar",
              toolId: "googlecalendar.read.events", kind: .refreshService, service: .calendar, symbol: "calendar"),
        .init(id: "qa-tasks", title: "Mis pendientes", subtitle: "Lo que tienes abierto en Tasks",
              toolId: "googletasks.read.list", kind: .refreshService, service: .tasks, symbol: "checklist"),
        .init(id: "qa-drive", title: "Archivos recientes", subtitle: "Lo último que cambió en tu Drive",
              toolId: "googledrive.read.files", kind: .refreshService, service: .drive, symbol: "folder"),
        .init(id: "qa-maps", title: "Buscar un lugar", subtitle: "Abre la búsqueda en tu app de mapas",
              toolId: mapsSearch, kind: .openMaps, service: nil, symbol: "mappin.and.ellipse"),
        .init(id: "qa-memory", title: "Guardar en memoria", subtitle: "Una nota que GUS recordará después",
              toolId: saveContext, kind: .saveMemory, service: nil, symbol: "brain"),
    ]

    public static func tool(_ id: String) -> AssistantToolInfo? { tools.first { $0.id == id } }

    public static func sections(developerMode: Bool) -> [AssistantSection] {
        AssistantSection.allCases.filter { developerMode || !$0.developerOnly }
    }

    private static func has(_ text: String, _ terms: String...) -> Bool { terms.contains { text.contains($0) } }

    /// Tools that fit what the user typed, most specific first.
    public static func selectTools(_ prompt: String) -> [String] {
        let text = SemanticContext.normalize(prompt)
        var ids: [String] = []
        func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }
        if has(text, "recuerda", "recordar", "memoria", "guarda esto", "guardar nota", "no olvides") { add(saveContext) }
        if has(text, "correo", "email", "gmail", "inbox", "bandeja", "mail") {
            if has(text, "envia", "enviar", "manda", "responde", "redacta", "escribe") { add("gmail.write.send") }
            add("gmail.read.inbox")
        }
        if has(text, "calendar", "calendario", "agenda", "reunion", "cita", "evento") {
            if has(text, "agendar", "agenda una", "crea", "crear", "programa", "nuevo evento", "nueva reunion") { add("googlecalendar.write.event") }
            add("googlecalendar.read.events")
        }
        if has(text, "pendiente", "tasks", "to-do", "todo", "lista de tareas", "por hacer") {
            if has(text, "agrega", "agregar", "crea", "crear", "anota", "nuevo", "nueva") { add("googletasks.write.create") }
            add("googletasks.read.list")
        }
        if has(text, "drive", "archivo", "carpeta") { add("googledrive.read.files") }
        if has(text, "docs", "documento", "minuta", "reporte") { add("googledocs.write.create") }
        if has(text, "contacto", "telefono de", "correo de", "directorio") { add("googlecontacts.read.lookup") }
        if has(text, "sheets", "hoja de calculo", "spreadsheet", "fila", "tabla") {
            if has(text, "agrega", "agregar", "inserta", "anota", "registra") { add("googlesheets.write.append_row") }
            add("googlesheets.read.range")
        }
        if has(text, "classroom", "curso", "clase", "anuncio") {
            if has(text, "publica", "publicar", "anuncia", "avisa") { add("googleclassroom.write.announcement") }
            add("googleclassroom.read.courses")
        }
        if has(text, "mapa", "maps", "ubicacion", "direccion", "cerca", "ruta", "como llegar", "restaurante", "cafe") { add(mapsSearch) }
        return ids
    }

    /// Anything that changes the user's data needs a visible yes first.
    public static func requiresConfirmation(_ toolIds: [String]) -> Bool {
        toolIds.contains { tool($0)?.mode == .writeConfirmed }
    }

    private static func headerSafe(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// RFC 2822 message, base64url, as Gmail's `messages/send` expects in `raw`.
    public static func encodeGmailRaw(to: String, subject: String, body: String) -> String {
        let encodedSubject = Data(headerSafe(subject).utf8).base64EncodedString()
        let mime = [
            "To: \(headerSafe(to))",
            "Subject: =?utf-8?B?\(encodedSubject)?=",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "",
            body,
        ].joined(separator: "\r\n")
        return base64URL(Data(mime.utf8))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isPlausibleEmail(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).range(of: #"^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$"#, options: .regularExpression) != nil
    }
}

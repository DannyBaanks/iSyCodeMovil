import Foundation

/// Google and memory tools for the on-device agent. Any model GUS runs (local
/// or cloud) sees only the tools that fit the request and whose Google
/// permission the user granted. Writes are destructive tools, so the agent asks
/// for approval on the iPhone every time before they run.
public actor AssistantToolExecutor {
    private let google: GoogleClient
    private let memoryURL: URL
    private let grantedScopes: @Sendable () async -> Set<String>

    public init(google: GoogleClient = GoogleClient(), memoryURL: URL = AssistantMemoryFile.url,
                grantedScopes: @escaping @Sendable () async -> Set<String> = { await GoogleSession.shared.grantedScopes() }) {
        self.google = google
        self.memoryURL = memoryURL
        self.grantedScopes = grantedScopes
    }

    public static let toolNames: Set<String> = Set(definitions.map(\.tool.name))

    public static func handles(_ name: String) -> Bool { toolNames.contains(name) }

    /// Tools that fit the latest user message. Memory reading is offered as soon as there are notes.
    public func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool] {
        let text = messages.last(where: { $0.role == .user })?.content ?? ""
        var wanted = Set(AssistantCatalog.selectTools(text))
        // A write also needs its read twin, so the model can check before acting.
        for id in wanted {
            if let service = AssistantCatalog.tool(id)?.service {
                AssistantCatalog.tools.filter { $0.service == service && $0.mode == .read }.forEach { wanted.insert($0.id) }
            }
        }
        if !AssistantMemoryFile.load(from: memoryURL).isEmpty { wanted.insert(AssistantCatalog.readContext) }
        let scopes = await grantedScopes()
        return Self.definitions.filter { definition in
            guard wanted.contains(definition.tool.name) else { return false }
            guard let service = definition.service else { return true }
            return service.isGranted(scopes)
        }.map(\.tool)
    }

    /// Text added to the prompt with the memory notes that apply to the latest message.
    public func memoryContext(for messages: [ModelMessage]) -> String? {
        let text = messages.last(where: { $0.role == .user })?.content ?? ""
        guard !text.isEmpty else { return nil }
        let priority = UserDefaults.standard.bool(forKey: AssistantStore.priorityKey)
        return SemanticContext.promptContext(AssistantMemoryFile.load(from: memoryURL), prompt: text, priority: priority,
                                             maxChars: priority ? 700 : 450)
    }

    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        let started = Date()
        func done(_ output: String) -> ToolExecutionResult {
            ToolExecutionResult(toolCallId: invocation.id, output: output, duration: Date().timeIntervalSince(started))
        }
        func fail(_ message: String) -> ToolExecutionResult {
            ToolExecutionResult(toolCallId: invocation.id, output: "", error: message, duration: Date().timeIntervalSince(started))
        }
        guard let definition = Self.definitions.first(where: { $0.tool.name == invocation.name }) else {
            return fail("Unknown assistant tool.")
        }
        if definition.tool.capabilities.isDestructive, approval != .allowOnce, approval != .allowAlways {
            return fail("This action needs your approval on the iPhone.")
        }
        if let service = definition.service, !service.isGranted(await grantedScopes()) {
            return fail("\(service.title) is not connected. Ask the user to connect it in Asistente › Google.")
        }
        let args = invocation.arguments
        func arg(_ key: String) -> String { (args[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            switch invocation.name {
            case "gmail.read.inbox":
                let mail = try await google.recentMail(max: min(Int(arg("max")) ?? 5, 10), query: arg("query").isEmpty ? "in:inbox" : arg("query"))
                return done(mail.isEmpty ? "No messages." : mail.map { "• \($0.subject) — \($0.from)\n  \($0.snippet)" }.joined(separator: "\n"))
            case "gmail.write.send":
                guard AssistantCatalog.isPlausibleEmail(arg("to")) else { return fail("Provide a valid recipient e-mail in `to`.") }
                try await google.sendMail(to: arg("to"), subject: arg("subject"), body: args["body"] ?? "")
                return done("Sent to \(arg("to")).")
            case "googlecalendar.read.events":
                let events = try await google.upcomingEvents()
                return done(events.isEmpty ? "No upcoming events." : events.map { "• \($0.start) \($0.title)\($0.location.isEmpty ? "" : " @ \($0.location)")" }.joined(separator: "\n"))
            case "googlecalendar.write.event":
                guard !arg("title").isEmpty, let start = ISO8601DateFormatter().date(from: arg("start")) else {
                    return fail("Provide `title` and `start` as ISO 8601 with offset, e.g. 2026-11-20T16:30:00-06:00.")
                }
                let minutes = max(5, min(Int(arg("minutes")) ?? 45, 1440))
                let event = try await google.createEvent(title: arg("title"), start: start,
                                                         end: start.addingTimeInterval(TimeInterval(minutes * 60)), location: arg("location"))
                return done("Created \"\(event.title)\" at \(event.start).")
            case "googletasks.read.list":
                let tasks = try await google.openTasks()
                return done(tasks.isEmpty ? "No open tasks." : tasks.map { "• \($0.title)" }.joined(separator: "\n"))
            case "googletasks.write.create":
                guard !arg("title").isEmpty else { return fail("Provide `title`.") }
                try await google.createTask(title: arg("title"), notes: arg("notes"))
                return done("Task added: \(arg("title")).")
            case "googledrive.read.files":
                let files = try await google.recentFiles()
                return done(files.isEmpty ? "No files." : files.map { "• \($0.name) (\($0.modified.prefix(10)))" }.joined(separator: "\n"))
            case "googledocs.write.create":
                guard !arg("title").isEmpty else { return fail("Provide `title`.") }
                let id = try await google.createDoc(title: arg("title"), text: args["text"] ?? "")
                return done("Created https://docs.google.com/document/d/\(id)")
            case "googlecontacts.read.lookup":
                let query = SemanticContext.normalize(arg("query"))
                let contacts = try await google.contacts(max: 50).filter {
                    query.isEmpty || SemanticContext.normalize("\($0.name) \($0.email) \($0.organization)").contains(query)
                }
                return done(contacts.isEmpty ? "No matching contacts." : contacts.prefix(10).map { "• \($0.name) <\($0.email)>" }.joined(separator: "\n"))
            case "googlesheets.read.range":
                guard !arg("spreadsheet").isEmpty else { return fail("Provide `spreadsheet` (link or ID).") }
                let sheet = try await google.readSheet(arg("spreadsheet"))
                return done("Tab \(sheet.tab):\n" + sheet.rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))
            case "googlesheets.write.append_row":
                let values = arg("values").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !arg("spreadsheet").isEmpty, !values.isEmpty else { return fail("Provide `spreadsheet` and comma-separated `values`.") }
                try await google.appendRow(arg("spreadsheet"), values: values)
                return done("Row appended (\(values.count) values).")
            case "googleclassroom.read.courses":
                let courses = try await google.courses()
                return done(courses.isEmpty ? "No active courses." : courses.map { "• \($0.name) (id \($0.id))" }.joined(separator: "\n"))
            case "googleclassroom.write.announcement":
                guard !arg("course_id").isEmpty, !arg("text").isEmpty else { return fail("Provide `course_id` and `text`.") }
                try await google.postAnnouncement(courseId: arg("course_id"), text: arg("text"))
                return done("Announcement posted.")
            case AssistantCatalog.readContext:
                let nodes = AssistantMemoryFile.load(from: memoryURL)
                let result = SemanticContext.retrieve(nodes, prompt: arg("query"), priority: arg("deep") == "true")
                let notes = result.nodes.map { "• [\($0.path.joined(separator: " › "))] \($0.title): \($0.summary)" }
                return done((result.steps + (notes.isEmpty ? ["No saved notes match."] : notes)).joined(separator: "\n"))
            case AssistantCatalog.saveContext:
                guard !arg("summary").isEmpty else { return fail("Provide `summary`.") }
                let path = arg("path").isEmpty ? SemanticContext.inferPath(arg("summary"))
                    : arg("path").components(separatedBy: ">").map { $0.replacingOccurrences(of: "›", with: "") }
                let priority = ContextPriority(rawValue: arg("priority").uppercased()) ?? .high
                let node = try AssistantMemoryFile.append(title: arg("title"), summary: arg("summary"), path: path,
                                                          priority: priority, source: "agente", to: memoryURL)
                return done("Saved under \(node.path.joined(separator: " › ")).")
            default:
                return fail("Unknown assistant tool.")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: Definitions

    struct Definition: Sendable {
        let tool: AgentTool
        let service: GoogleService?
    }

    private static func p(_ description: String) -> AgentTool.PropertySchema { .init(type: "string", description: description) }

    private static func write(_ reason: String) -> AgentTool.ToolCapabilities {
        .init(requiresNetwork: true, isDestructive: true, approvalReason: reason, requiresApprovalEveryTime: true)
    }

    private static let read = AgentTool.ToolCapabilities(requiresNetwork: true)

    static let definitions: [Definition] = [
        .init(tool: AgentTool(name: "gmail.read.inbox", description: "List the user's latest Gmail messages (subject, sender, snippet).",
              properties: ["query": p("Optional Gmail search, e.g. is:unread from:ana"), "max": p("How many, 1-10")], capabilities: read), service: .gmail),
        .init(tool: AgentTool(name: "gmail.write.send", description: "Send an e-mail from the user's Gmail. The user approves each send.",
              properties: ["to": p("Recipient e-mail"), "subject": p("Subject"), "body": p("Plain-text body")], required: ["to", "body"],
              capabilities: write("GUS quiere enviar un correo desde tu Gmail. Revisa destinatario y texto.")), service: .gmail),
        .init(tool: AgentTool(name: "googlecalendar.read.events", description: "List the user's next Google Calendar events.",
              properties: [:], capabilities: read), service: .calendar),
        .init(tool: AgentTool(name: "googlecalendar.write.event", description: "Create an event in the user's primary calendar after approval.",
              properties: ["title": p("Event title"), "start": p("ISO 8601 start with offset, e.g. 2026-11-20T16:30:00-06:00"),
                           "minutes": p("Duration in minutes, default 45"), "location": p("Optional place")], required: ["title", "start"],
              capabilities: write("GUS quiere crear un evento en tu calendario.")), service: .calendar),
        .init(tool: AgentTool(name: "googletasks.read.list", description: "List the user's open Google Tasks.", properties: [:], capabilities: read), service: .tasks),
        .init(tool: AgentTool(name: "googletasks.write.create", description: "Add a task to the user's default Google Tasks list after approval.",
              properties: ["title": p("Task"), "notes": p("Optional notes")], required: ["title"],
              capabilities: write("GUS quiere agregar un pendiente a Google Tasks.")), service: .tasks),
        .init(tool: AgentTool(name: "googledrive.read.files", description: "List recently modified Google Drive files (names only).",
              properties: [:], capabilities: read), service: .drive),
        .init(tool: AgentTool(name: "googledocs.write.create", description: "Create a Google Doc with the given text after approval.",
              properties: ["title": p("Document title"), "text": p("Document body")], required: ["title"],
              capabilities: write("GUS quiere crear un documento en tu Google Drive.")), service: .docs),
        .init(tool: AgentTool(name: "googlecontacts.read.lookup", description: "Find contacts by name, e-mail or organization.",
              properties: ["query": p("Text to look for")], capabilities: read), service: .contacts),
        .init(tool: AgentTool(name: "googlesheets.read.range", description: "Read the first rows of a spreadsheet's first tab.",
              properties: ["spreadsheet": p("Spreadsheet link or ID")], required: ["spreadsheet"], capabilities: read), service: .sheets),
        .init(tool: AgentTool(name: "googlesheets.write.append_row", description: "Append one row to a spreadsheet after approval.",
              properties: ["spreadsheet": p("Spreadsheet link or ID"), "values": p("Comma-separated cell values")], required: ["spreadsheet", "values"],
              capabilities: write("GUS quiere agregar una fila a tu hoja de cálculo.")), service: .sheets),
        .init(tool: AgentTool(name: "googleclassroom.read.courses", description: "List the user's active Google Classroom courses with their ids.",
              properties: [:], capabilities: read), service: .classroom),
        .init(tool: AgentTool(name: "googleclassroom.write.announcement", description: "Post an announcement to a course after approval.",
              properties: ["course_id": p("Course id from googleclassroom.read.courses"), "text": p("Announcement text")], required: ["course_id", "text"],
              capabilities: write("GUS quiere publicar un anuncio en Classroom.")), service: .classroom),
        .init(tool: AgentTool(name: AssistantCatalog.readContext,
              description: "Walk the user's saved memory folder by folder (domain › branch › topic) and return the notes that fit the query.",
              properties: ["query": p("What you need to remember"), "deep": p("true to widen to the whole domain")], required: ["query"]), service: nil),
        .init(tool: AgentTool(name: AssistantCatalog.saveContext,
              description: "Save something the user wants remembered into their memory, filed in three semantic folders. Ask first; the user approves each save.",
              properties: ["title": p("Short title"), "summary": p("What to remember"), "path": p("Optional: Domain > Branch > Topic"),
                           "priority": p("normal, high or critical")], required: ["summary"],
              capabilities: .init(isDestructive: true, approvalReason: "GUS quiere guardar una nota en tu memoria.", requiresApprovalEveryTime: true)),
              service: nil),
    ]
}

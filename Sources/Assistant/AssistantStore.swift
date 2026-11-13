import Foundation
import SwiftUI
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum AssistantLogLevel: String, CaseIterable, Sendable { case info = "INFO", tool = "TOOL", success = "SUCCESS", error = "ERROR" }

public struct AssistantLogEntry: Identifiable, Sendable {
    public let id: String
    public let time: Date
    public let level: AssistantLogLevel
    public let tool: String
    public let message: String
    public var retryable: Bool

    /// Raw JSON for the "Copiar" button.
    public var rawJSON: String {
        let object: [String: Any] = ["id": id, "time": ISO8601DateFormatter().string(from: time), "level": level.rawValue,
                                     "tool": tool, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return message }
        return String(data: data, encoding: .utf8) ?? message
    }
}

public struct FeedItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let source: String
    public let time: Date
}

/// A write waiting for the user's yes. Nothing reaches Google until `run` is called from the dialog.
public struct PendingAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let details: [(String, String)]
    public let toolId: String
    public let run: @MainActor () async throws -> String
}

/// State and actions of the assistant screens. Same responsibilities as
/// android/.../assistant/AssistantViewModel.kt.
@MainActor
public final class AssistantStore: ObservableObject {
    @Published public var section: AssistantSection = .home
    @Published public var developerMode = UserDefaults.standard.bool(forKey: "assistant.developerMode") {
        didSet { UserDefaults.standard.set(developerMode, forKey: "assistant.developerMode") }
    }
    @Published public var priorityContext = UserDefaults.standard.bool(forKey: AssistantStore.priorityKey) {
        didSet { UserDefaults.standard.set(priorityContext, forKey: AssistantStore.priorityKey) }
    }
    @Published public var clientId = UserDefaults.standard.string(forKey: GoogleSession.clientIdKey) ?? "" {
        didSet { UserDefaults.standard.set(clientId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GoogleSession.clientIdKey) }
    }
    @Published public var sheetId = UserDefaults.standard.string(forKey: "assistant.sheetId") ?? "" {
        didSet { UserDefaults.standard.set(sheetId, forKey: "assistant.sheetId") }
    }
    @Published public private(set) var monitorURL = UserDefaults.standard.string(forKey: "assistant.monitorURL") ?? "" {
        didSet { UserDefaults.standard.set(monitorURL, forKey: "assistant.monitorURL") }
    }
    @Published public private(set) var monitorEnabled = UserDefaults.standard.bool(forKey: "assistant.monitorEnabled") {
        didSet { UserDefaults.standard.set(monitorEnabled, forKey: "assistant.monitorEnabled") }
    }
    @Published public private(set) var watchGmail = UserDefaults.standard.bool(forKey: "assistant.watchGmail") {
        didSet { UserDefaults.standard.set(watchGmail, forKey: "assistant.watchGmail") }
    }
    @Published private var servicesRaw = UserDefaults.standard.string(forKey: "assistant.services")
        ?? GoogleService.allCases.filter(\.defaultOn).map(\.rawValue).joined(separator: ",") {
        didSet { UserDefaults.standard.set(servicesRaw, forKey: "assistant.services") }
    }

    /// Read by the agent too: when on, the newest message counts as priority context.
    public nonisolated static let priorityKey = "assistant.priorityContext"

    @Published public private(set) var memory: [ContextNode] = AssistantMemoryFile.load()
    @Published public private(set) var email: String?
    @Published public private(set) var grantedScopes: Set<String> = []
    @Published public var mail: [MailSummary] = []
    @Published public var events: [EventSummary] = []
    @Published public var tasks: [TaskItem] = []
    @Published public var files: [DriveFile] = []
    @Published public var contacts: [ContactItem] = []
    @Published public var courses: [CourseItem] = []
    @Published public var sheet: SheetData?
    @Published public private(set) var loading: Set<GoogleService> = []
    @Published public private(set) var logs: [AssistantLogEntry] = []
    @Published public private(set) var feed: [FeedItem] = []
    @Published public private(set) var monitorStatus = "Apagado"
    @Published public var pending: PendingAction?
    @Published public private(set) var running = false
    @Published public var message: String?
    @Published public private(set) var notificationsAllowed = false

    private let google = GoogleClient()
    private var retries: [String: @MainActor () async -> Void] = [:]
    private var monitorTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    #if canImport(AuthenticationServices) && canImport(UIKit)
    private var authSession: ASWebAuthenticationSession?
    private let anchor = AuthAnchor()
    #endif

    public init() {
        log(.info, "isycode.start", "Asistente listo. \(memory.count) notas en memoria.")
        Task {
            if let token = await GoogleSession.shared.token() {
                email = token.email
                grantedScopes = token.scopes
            }
            await refreshNotificationState()
            restartMonitor()
        }
    }

    public var signedIn: Bool { email != nil || !grantedScopes.isEmpty }
    public func granted(_ service: GoogleService) -> Bool { service.isGranted(grantedScopes) }

    public var enabledServices: [GoogleService] {
        let raw = Set(servicesRaw.split(separator: ",").map(String.init))
        return GoogleService.allCases.filter { raw.contains($0.rawValue) }
    }

    public func setService(_ service: GoogleService, enabled: Bool) {
        var set = Set(enabledServices)
        if enabled { set.insert(service) } else { set.remove(service) }
        servicesRaw = GoogleService.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    public func setDeveloperMode(_ on: Bool) {
        developerMode = on
        if !on, section.developerOnly { section = .options }
    }

    private func say(_ text: String) { message = text }

    // MARK: Log & feed

    private func log(_ level: AssistantLogLevel, _ tool: String, _ text: String, retry: (@MainActor () async -> Void)? = nil) {
        let entry = AssistantLogEntry(id: "log_" + UUID().uuidString.prefix(8).lowercased(), time: Date(), level: level,
                                      tool: tool, message: text, retryable: retry != nil)
        if let retry { retries[entry.id] = retry }
        logs.insert(entry, at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    public func retry(_ entry: AssistantLogEntry) {
        guard let action = retries.removeValue(forKey: entry.id) else { return }
        if let index = logs.firstIndex(where: { $0.id == entry.id }) { logs[index].retryable = false }
        log(.tool, entry.tool, "Reintentando \(entry.tool)…")
        Task { await action() }
    }

    public func clearLogs() {
        retries.removeAll()
        logs.removeAll()
    }

    private func addFeed(_ title: String, _ body: String, source: String) {
        feed.insert(FeedItem(id: UUID().uuidString, title: title, body: body, source: source, time: Date()), at: 0)
        if feed.count > 50 { feed.removeLast() }
    }

    // MARK: Notifications

    public func refreshNotificationState() async {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        #endif
    }

    public func requestNotifications() {
        #if canImport(UserNotifications)
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotificationState()
        }
        #endif
    }

    private func notify(id: String, title: String, body: String) {
        #if canImport(UserNotifications)
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(80))
        content.body = String(body.prefix(400))
        content.sound = .default
        content.userInfo = ["open": "assistant"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "iyscode.assistant.\(id)", content: content, trigger: nil))
        #endif
    }

    // MARK: Google sign-in (ASWebAuthenticationSession + PKCE)

    public func signIn() {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        guard let redirect = GoogleOAuth.redirectURI(clientId: clientId),
              let scheme = GoogleOAuth.redirectScheme(clientId: clientId) else {
            say("Pega primero tu ID de cliente de iOS (termina en .apps.googleusercontent.com). La guía está en Opciones.")
            return
        }
        let verifier = GoogleOAuth.newVerifier()
        let state = UUID().uuidString
        let services = enabledServices
        guard let url = GoogleOAuth.authURL(clientId: clientId, redirectURI: redirect, scopes: GoogleOAuth.scopes(services),
                                            challenge: GoogleOAuth.challenge(verifier), state: state) else { return }
        log(.info, "google.oauth", "Abriendo Google para pedir: \(services.map(\.title).joined(separator: ", ")).")
        // authSession is cleared in finishSignIn, which breaks this retain cycle.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
            Task { @MainActor in self.finishSignIn(callback: callback, error: error, verifier: verifier, state: state, redirect: redirect) }
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() { say("No pude abrir la página de Google.") }
        #else
        say("El inicio de sesión con Google necesita iOS.")
        #endif
    }

    private func finishSignIn(callback: URL?, error: Error?, verifier: String, state: String, redirect: String) {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        authSession = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            say("Cancelaste el acceso a Google.")
            return
        }
        let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let googleError = value("error") {
            say(googleError == "access_denied" ? "Cancelaste el acceso a Google." : "Google respondió: \(googleError)")
            return
        }
        guard let code = value("code"), value("state") == state else {
            say(error?.localizedDescription ?? "La respuesta de Google no coincide con esta solicitud. Intenta de nuevo.")
            return
        }
        let clientId = self.clientId
        Task {
            do {
                let token = try await GoogleOAuth.exchange(code: code, verifier: verifier, clientId: clientId, redirectURI: redirect)
                await GoogleSession.shared.store(token)
                email = token.email
                grantedScopes = token.scopes
                let granted = GoogleService.allCases.filter { $0.isGranted(token.scopes) }.map(\.title).joined(separator: ", ")
                log(.success, "google.oauth", "Cuenta conectada\(token.email.map { " (\($0))" } ?? ""). Permisos: \(granted).")
                say("Listo, Google está conectado.")
                refreshAll()
            } catch {
                log(.error, "google.oauth", error.localizedDescription)
                say(error.localizedDescription)
            }
        }
        #endif
    }

    public func signOut() {
        Task {
            let token = await GoogleSession.shared.token()
            await GoogleSession.shared.store(nil)
            if let token { await GoogleOAuth.revoke(token) }
        }
        email = nil
        grantedScopes = []
        mail = []; events = []; tasks = []; files = []; contacts = []; courses = []; sheet = nil
        log(.info, "google.oauth", "Cuenta de Google desconectada en este iPhone.")
    }

    // MARK: Reading Google

    public func refreshAll() {
        for service in enabledServices where granted(service) { refresh(service) }
    }

    private static func toolId(for service: GoogleService) -> String? {
        switch service {
        case .gmail: return "gmail.read.inbox"
        case .calendar: return "googlecalendar.read.events"
        case .tasks: return "googletasks.read.list"
        case .drive: return "googledrive.read.files"
        case .contacts: return "googlecontacts.read.lookup"
        case .sheets: return "googlesheets.read.range"
        case .classroom: return "googleclassroom.read.courses"
        case .docs: return nil
        }
    }

    public func refresh(_ service: GoogleService) {
        guard granted(service) else { say("Falta el permiso de \(service.title). Actívalo y vuelve a conectar."); return }
        guard let tool = Self.toolId(for: service) else { return }
        if service == .sheets && sheetId.isEmpty { say("Pega el enlace o ID de tu hoja de cálculo para leerla."); return }
        loading.insert(service)
        let sheetId = self.sheetId
        Task {
            defer { loading.remove(service) }
            do {
                let count: Int
                switch service {
                case .gmail: mail = try await google.recentMail(); count = mail.count
                case .calendar: events = try await google.upcomingEvents(); count = events.count
                case .tasks: tasks = try await google.openTasks(); count = tasks.count
                case .drive: files = try await google.recentFiles(); count = files.count
                case .contacts: contacts = try await google.contacts(); count = contacts.count
                case .classroom: courses = try await google.courses(); count = courses.count
                case .sheets: let data = try await google.readSheet(sheetId); sheet = data; count = data.rows.count
                case .docs: count = 0
                }
                log(.success, tool, "\(service.title): \(count) \(count == 1 ? "elemento" : "elementos").")
            } catch {
                log(.error, tool, error.localizedDescription) { [weak self] in self?.refresh(service) }
            }
        }
    }

    // MARK: Writes: always through a confirmation

    private func propose(_ action: PendingAction) {
        log(.info, action.toolId, "Esperando tu confirmación: \(action.title)")
        pending = action
    }

    public func cancelPending() {
        if let action = pending { log(.info, action.toolId, "Cancelado por ti: \(action.title)") }
        pending = nil
    }

    public func confirmPending() {
        guard let action = pending else { return }
        running = true
        Task {
            defer { running = false; pending = nil }
            do {
                let result = try await action.run()
                log(.success, action.toolId, result)
                addFeed(action.title, result, source: action.toolId)
                notify(id: action.toolId + "\(Date().timeIntervalSince1970)", title: "Hecho: \(action.title)", body: result)
                say(result)
            } catch {
                log(.error, action.toolId, error.localizedDescription) { [weak self] in self?.pending = action }
                say(error.localizedDescription)
            }
        }
    }

    public func proposeEmail(to: String, subject: String, body: String) {
        guard AssistantCatalog.isPlausibleEmail(to) else { say("Escribe un correo válido para el destinatario."); return }
        let google = self.google
        propose(PendingAction(title: "Enviar correo", message: "Se enviará desde tu cuenta de Gmail.",
            details: [("Para", to), ("Asunto", subject.isEmpty ? "(sin asunto)" : subject), ("Mensaje", String(body.prefix(400)))],
            toolId: "gmail.write.send") {
            try await google.sendMail(to: to, subject: subject, body: body)
            return "Correo enviado a \(to)."
        })
    }

    public func proposeEvent(title: String, start: Date, minutes: Int, location: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { say("Escribe un título para el evento."); return }
        let end = start.addingTimeInterval(TimeInterval(max(5, min(minutes, 1440)) * 60))
        let google = self.google
        propose(PendingAction(title: "Crear evento", message: "Se agregará a tu calendario principal.",
            details: [("Título", title), ("Inicio", start.formatted(date: .abbreviated, time: .shortened)),
                      ("Duración", "\(Int(end.timeIntervalSince(start) / 60)) min"), ("Lugar", location.isEmpty ? "—" : location)],
            toolId: "googlecalendar.write.event") { [weak self] in
            let created = try await google.createEvent(title: title, start: start, end: end, location: location)
            self?.refresh(.calendar)
            return "Evento creado: \(created.title)."
        })
    }

    public func proposeTask(title: String, notes: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { say("Escribe el pendiente."); return }
        let google = self.google
        propose(PendingAction(title: "Agregar pendiente", message: "Se agregará a tu lista principal de Google Tasks.",
            details: [("Pendiente", title), ("Notas", notes.isEmpty ? "—" : notes)], toolId: "googletasks.write.create") { [weak self] in
            try await google.createTask(title: title, notes: notes)
            self?.refresh(.tasks)
            return "Pendiente agregado: \(title)."
        })
    }

    public func proposeDoc(title: String, text: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { say("Escribe el título del documento."); return }
        let google = self.google
        propose(PendingAction(title: "Crear documento", message: "Se creará un Google Doc en tu Drive.",
            details: [("Título", title), ("Texto", text.isEmpty ? "—" : String(text.prefix(400)))], toolId: "googledocs.write.create") {
            let id = try await google.createDoc(title: title, text: text)
            return "Documento creado: https://docs.google.com/document/d/\(id)"
        })
    }

    public func proposeRow(_ values: [String]) {
        let sheet = sheetId
        guard !sheet.isEmpty, values.contains(where: { !$0.isEmpty }) else { say("Indica la hoja y al menos un valor."); return }
        let google = self.google
        propose(PendingAction(title: "Agregar fila", message: "Se agregará al final de la primera pestaña.",
            details: [("Hoja", String(GoogleParsers.spreadsheetId(sheet).prefix(24)) + "…"), ("Valores", values.joined(separator: " | "))],
            toolId: "googlesheets.write.append_row") { [weak self] in
            try await google.appendRow(sheet, values: values)
            self?.refresh(.sheets)
            return "Fila agregada (\(values.count) columnas)."
        })
    }

    public func proposeAnnouncement(course: CourseItem, text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { say("Escribe el anuncio."); return }
        let google = self.google
        propose(PendingAction(title: "Publicar anuncio", message: "Lo verán todos los alumnos del curso.",
            details: [("Curso", course.name), ("Anuncio", String(text.prefix(400)))], toolId: "googleclassroom.write.announcement") {
            try await google.postAnnouncement(courseId: course.id, text: text)
            return "Anuncio publicado en \(course.name)."
        })
    }

    // MARK: Memory

    public func reloadMemory() { memory = AssistantMemoryFile.load() }

    public func proposeMemory(title: String, summary: String, path: [String], priority: ContextPriority, source: String) {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { say("Escribe qué quieres que GUS recuerde."); return }
        let clean = SemanticContext.cleanPath(path)
        propose(PendingAction(title: "Guardar en memoria", message: "GUS podrá usar esta nota en tus próximas preguntas.",
            details: [("Nota", title.isEmpty ? String(summary.prefix(60)) : title), ("Carpeta", clean.joined(separator: " › ")),
                      ("Prioridad", priority.label)], toolId: AssistantCatalog.saveContext) { [weak self] in
            let node = try AssistantMemoryFile.append(title: title, summary: summary, path: clean, priority: priority, source: source)
            self?.reloadMemory()
            return "Guardado en \(node.path.joined(separator: " › "))."
        })
    }

    public func deleteMemory(_ node: ContextNode) {
        let remaining = AssistantMemoryFile.load().filter { $0.id != node.id }
        do {
            try AssistantMemoryFile.save(remaining)
            memory = remaining
            log(.info, AssistantCatalog.saveContext, "Nota borrada: \(node.title)")
        } catch {
            say("No pude borrar la nota: \(error.localizedDescription)")
        }
    }

    public func previewRetrieval(_ prompt: String) -> Retrieval {
        let result = SemanticContext.retrieve(memory, prompt: prompt, priority: priorityContext)
        log(.tool, AssistantCatalog.readContext, "Recorrido: \(result.matchedPath.joined(separator: " › ")) · \(result.nodes.count) notas.")
        return result
    }

    // MARK: Daemon monitor + Gmail watch

    public func configureMonitor(url: String, enabled: Bool, watchGmail: Bool) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled, !clean.isEmpty, !DaemonManifest.isAllowedURL(clean) {
            say("Usa una dirección https:// (o http:// solo dentro de tu red local).")
            return
        }
        if clean != monitorURL { defaults.removeObject(forKey: "assistant.monitorPrimed"); defaults.removeObject(forKey: "assistant.monitorEtag") }
        monitorURL = clean
        monitorEnabled = enabled
        self.watchGmail = watchGmail
        restartMonitor()
    }

    /// Polls while the app is open. In the background iOS decides when apps run,
    /// so your PC's daemon should also send its own push for urgent tasks.
    public func restartMonitor() {
        monitorTask?.cancel()
        let manifestOn = monitorEnabled && !monitorURL.isEmpty
        guard manifestOn || watchGmail else { monitorStatus = "Apagado"; return }
        monitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if manifestOn { await self.pollManifest() }
                if self.watchGmail, tick % 2 == 0 { await self.pollGmail() }
                tick += 1
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func pollManifest() async {
        do {
            switch try await DaemonManifest.poll(monitorURL, etag: defaults.string(forKey: "assistant.monitorEtag")) {
            case .notModified:
                monitorStatus = "Conectado · sin cambios"
            case .changed(let tasks, let etag):
                let seen = Set(defaults.stringArray(forKey: "assistant.seenTasks") ?? [])
                let fresh = DaemonManifest.newTasks(seen: seen, incoming: tasks)
                // The first read only learns what exists: no flood of old tasks.
                let firstRun = !defaults.bool(forKey: "assistant.monitorPrimed")
                if !firstRun {
                    for task in fresh {
                        log(.tool, "isycode.daemon", "\(task.source): \(task.title)")
                        addFeed(task.title, task.body.isEmpty ? "Estado: \(task.status)" : task.body, source: task.source)
                        notify(id: "task_\(task.id)", title: "iSyCode · \(task.title)", body: task.body.isEmpty ? task.status : task.body)
                    }
                }
                defaults.set(Array((tasks.map(\.id) + seen).prefix(400)), forKey: "assistant.seenTasks")
                defaults.set(etag, forKey: "assistant.monitorEtag")
                defaults.set(true, forKey: "assistant.monitorPrimed")
                monitorStatus = firstRun ? "Conectado · \(tasks.count) tareas conocidas" : "Conectado · \(fresh.count) nuevas"
            }
        } catch {
            monitorStatus = "Sin conexión: \(error.localizedDescription)"
        }
    }

    private func pollGmail() async {
        guard granted(.gmail) else { return }
        do {
            let recent = try await google.recentMail(max: 5, query: "in:inbox is:unread")
            let stored = defaults.stringArray(forKey: "assistant.seenMail")
            let fresh = stored == nil ? [] : recent.filter { !(stored ?? []).contains($0.id) }
            for message in fresh {
                log(.tool, "gmail.read.inbox", "Correo nuevo de \(message.from): \(message.subject)")
                addFeed(message.subject, "De \(message.from)\n\(message.snippet)", source: "gmail")
                notify(id: "mail_\(message.id)", title: message.subject, body: "De \(message.from): \(message.snippet)")
            }
            defaults.set(Array((recent.map(\.id) + (stored ?? [])).prefix(200)), forKey: "assistant.seenMail")
        } catch {
            log(.error, "gmail.read.inbox", "Vigilancia de Gmail: \(error.localizedDescription)")
        }
    }

    // MARK: Quick actions and the "¿Qué necesitas?" field

    /// Returns a maps query when the caller should open the maps app.
    public func run(_ action: QuickAction) -> String? {
        log(.tool, action.toolId, "Acción rápida: \(action.title)")
        switch action.kind {
        case .refreshService:
            if let service = action.service { refresh(service); section = .google }
        case .openMaps:
            return ""
        case .saveMemory:
            section = .memory
        }
        return nil
    }

    /// Routes a typed request to the matching tools. Returns a maps query if one applies.
    public func ask(_ prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let tools = AssistantCatalog.selectTools(text)
        log(.info, "isycode.route", "\"\(text.prefix(80))\" → \((tools.isEmpty ? ["GUS"] : tools).joined(separator: ", "))")
        if priorityContext {
            proposeMemory(title: String(text.prefix(80)), summary: text, path: SemanticContext.inferPath(text),
                          priority: .critical, source: "prioritario")
            return nil
        }
        guard let first = tools.first else {
            say("No encontré una herramienta para eso. Pregúntale a GUS en tu proyecto.")
            return nil
        }
        if first == AssistantCatalog.mapsSearch { return text }
        if first == AssistantCatalog.saveContext {
            proposeMemory(title: "", summary: text, path: SemanticContext.inferPath(text), priority: .high, source: "asistente")
            return nil
        }
        guard let tool = AssistantCatalog.tool(first), let service = tool.service else { return nil }
        if tool.mode == .writeConfirmed { say("Completa los datos de \(service.title) y confirma antes de enviar.") } else { refresh(service) }
        section = .google
        return nil
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
/// Presents Google's sign-in sheet over the app's key window.
final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
#endif

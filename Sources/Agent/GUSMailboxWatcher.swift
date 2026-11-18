import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Buzón [GUS] en Gmail: fuente de verdad del loop GUS ↔ Muse.
///
/// Protocolo v1 (el asunto es el encabezado legible por máquina; el cuerpo, el texto):
///   Asunto: `[GUS] <id-tarea> <estado> <para>`
///     - id-tarea: `gus-AAAAMMDD-HHMMSS-XXXX` (lo genera quien escribe la tarea)
///     - estado: `pendiente` | `en-curso` | `hecho` (en el asunto va con guion, sin espacios)
///     - para: `GUS` | `Muse` (GPT no es destinatario de fondo: solo se le alcanza por WDA)
///   Cuerpo: texto libre de la tarea. En un `hecho`, un resumen corto del resultado.
///
/// Reglas de la cola:
/// - La reconciliación es por id de tarea y gana el mensaje más reciente (Gmail lista
///   lo más reciente primero). El estado de cada tarea es el de su último mensaje.
/// - Las notificaciones solo avisan que hay que revisar el buzón; nunca son la fuente
///   del trabajo. Si iOS suspende la app, no llega una notificación o hay un reinicio,
///   al despertar el vigilante vuelve a listar el buzón y retoma lo pendiente: nada
///   se pierde. Lo local (intentos, marcas de tiempo) es solo un caché: la verdad
///   está en el buzón.
/// - GUS marca `en curso` al tomar una tarea y `hecho` al terminarla, respondiendo en
///   el mismo buzón (mismo id, nuevo estado). Un `en curso` sin actualización más de
///   `staleAfter` se reintenta como pendiente (máximo `maxAttempts` intentos).
/// - El buzón se escribe siempre desde el propio Gmail del usuario; el remitente no
///   distingue: el destinatario lo dice el `para` del asunto, no el From.
/// - El vigilante solo actúa sobre tareas `Para: GUS` en estado `pendiente` (o `en curso`
///   obsoletas). Las de `Para: Muse` son para Muse. Las de `Para: GPT` se ignoran en v1:
///   GPT no tiene canal de fondo entre sesiones, solo se le alcanza con mensajes
///   visibles por WDA en un turno en primer plano.
public actor GUSMailboxWatcher {
    public static let shared = GUSMailboxWatcher()

    /// Cuánto espera el vigilante entre revisiones del buzón mientras la app está viva.
    public static let pollInterval: TimeInterval = 300
    /// Un `en curso` sin actualización más de esto se reintenta como pendiente.
    public static let staleAfter: TimeInterval = 3600
    /// Intentos máximos por tarea antes de dejar de reintentarla y avisar.
    public static let maxAttempts = 3

    /// Interruptor del vigilante (Ajustes › Avanzado). Apagado por defecto: nada se
    /// revisa ni se envía hasta que el usuario lo activa.
    public static let enabledKey = "gus.mailbox.watcher.enabled"
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public enum MailboxTaskState: String, Sendable, CaseIterable {
        case pendiente
        case enCurso = "en-curso"
        case hecho

        public var displayName: String {
            switch self {
            case .pendiente: return "pendiente"
            case .enCurso: return "en curso"
            case .hecho: return "hecho"
            }
        }
    }

    public enum MailboxRecipient: String, Sendable {
        case gus = "GUS"
        case muse = "Muse"
        case gpt = "GPT"
    }

    public struct MailboxTask: Sendable, Equatable, Identifiable {
        public let id: String
        public let state: MailboxTaskState
        public let recipient: MailboxRecipient
        public let messageID: String
        public let subject: String
        public let from: String
        public let date: String
        public let snippet: String
    }

    public struct PendingDelivery: Sendable {
        public let task: MailboxTask
        public let body: String
    }

    public struct Review: Sendable {
        public let pending: [PendingDelivery]
        public let exhausted: [MailboxTask]
    }

    private let google: GoogleClient
    private var pollingTask: Task<Void, Never>?
    /// Generación del bucle de revisión vigente: el defer de una tarea terminada solo
    /// limpia el hueco si sigue siendo la vigente (si no, borraría el bucle nuevo).
    private var pollingToken: UUID?

    public init(google: GoogleClient = GoogleClient()) {
        self.google = google
    }

    // MARK: - Protocolo del buzón (lógica pura, cubierta por tests)

    public static func subject(id: String, state: MailboxTaskState, recipient: MailboxRecipient) -> String {
        "[GUS] \(id) \(state.rawValue) \(recipient.rawValue)"
    }

    /// Nuevo id de tarea: `gus-AAAAMMDD-HHMMSS-XXXX` (UTC, 4 hex aleatorios).
    public static func newTaskID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "gus-\(formatter.string(from: now))-\(String(format: "%04x", Int.random(in: 0..<65536)))"
    }

    /// `[GUS] <id> <estado> <para>`; el estado puede venir como `en curso` o `en-curso`.
    /// Devuelve nil si el asunto no sigue el protocolo (se ignora, no se rompe el buzón).
    public static func parseSubject(_ subject: String) -> (id: String, state: MailboxTaskState, recipient: MailboxRecipient)? {
        let parts = subject.split(separator: " ").map(String.init)
        guard parts.count >= 4, parts[0] == "[GUS]" else { return nil }
        let id = parts[1]
        guard !id.isEmpty else { return nil }
        guard let recipient = MailboxRecipient(rawValue: parts.last!) else { return nil }
        let stateRaw = parts[2..<(parts.count - 1)].joined(separator: " ")
        guard let state = MailboxTaskState(rawValue: stateRaw)
            ?? MailboxTaskState(rawValue: stateRaw.replacingOccurrences(of: " ", with: "-")) else { return nil }
        return (id, state, recipient)
    }

    /// Agrupa los mensajes del buzón por id de tarea; gana el más reciente
    /// (Gmail lista lo más reciente primero). Los asuntos fuera de protocolo se ignoran.
    public static func reconcile(_ summaries: [MailSummary]) -> [MailboxTask] {
        var latest: [String: MailboxTask] = [:]
        for summary in summaries {
            guard summary.subject.contains("[GUS]"),
                  let parsed = parseSubject(summary.subject) else { continue }
            guard latest[parsed.id] == nil else { continue }
            latest[parsed.id] = MailboxTask(
                id: parsed.id, state: parsed.state, recipient: parsed.recipient,
                messageID: summary.id, subject: summary.subject,
                from: summary.from, date: summary.date, snippet: summary.snippet
            )
        }
        return latest.values.sorted { $0.id < $1.id }
    }

    // MARK: - Revisión del buzón

    /// Una revisión del buzón: lista, reconcilia y separa las tareas entregables
    /// (pendientes para GUS, o en curso sin actualización) de las agotadas (3 intentos).
    public func review() async throws -> Review {
        let summaries = try await google.recentMail(max: 20, query: "subject:GUS")
        let tasks = Self.reconcile(summaries)
        var pending: [PendingDelivery] = []
        var exhausted: [MailboxTask] = []
        for task in tasks where task.recipient == .gus {
            switch task.state {
            case .pendiente:
                if attempts(task.id) >= Self.maxAttempts { exhausted.append(task); continue }
                pending.append(PendingDelivery(task: task, body: try await google.mailBody(id: task.messageID)))
            case .enCurso:
                if let first = firstSeenEnCurso(task.id) {
                    if Date().timeIntervalSince(first) > Self.staleAfter {
                        if attempts(task.id) >= Self.maxAttempts { exhausted.append(task); continue }
                        pending.append(PendingDelivery(task: task, body: try await google.mailBody(id: task.messageID)))
                    }
                } else {
                    // Primera vez que se ve en curso: se le da su plazo antes de reintentarla.
                    noteEnCurso(task.id)
                }
            case .hecho:
                clearEnCurso(task.id)
                clearAttempts(task.id)
            }
        }
        return Review(pending: pending, exhausted: exhausted)
    }

    // MARK: - Acuse de recibo (escribir en el buzón)

    /// Escribe un mensaje de estado en el buzón (siempre al propio Gmail del usuario).
    /// Es el acuse de recibo del protocolo: tomar una tarea = `en curso`, terminarla =
    /// `hecho`. Solo escribe asuntos `[GUS]`; nunca envía a otro destinatario.
    /// El `recipient` no cambia para un id de tarea: el estado es lo que cambia.
    public func mark(taskID: String, state: MailboxTaskState, recipient: MailboxRecipient, note: String) async throws {
        guard let ownEmail = await GoogleSession.shared.token()?.email,
              AssistantCatalog.isPlausibleEmail(ownEmail) else {
            throw GUSMailboxError.noOwnEmail
        }
        try await google.sendMail(to: ownEmail, subject: Self.subject(id: taskID, state: state, recipient: recipient), body: note)
        switch state {
        case .enCurso: noteAttempt(taskID)
        case .hecho: clearAttempts(taskID); clearEnCurso(taskID)
        case .pendiente: break
        }
    }

    // MARK: - Bucle de revisión periódica

    /// Revisa el buzón cada `interval` mientras la app está viva y entrega cada tarea
    /// pendiente al `handler`. Cada revisión mantiene la app viva con BackgroundRunKeeper;
    /// entre revisiones iOS puede suspender la app: al despertar, la siguiente revisión
    /// retoma lo pendiente desde el buzón (el buzón es la fuente de verdad, no la
    /// notificación ni la memoria local). Idempotente: si ya está corriendo, no hace nada.
    public func startPolling(every interval: TimeInterval = pollInterval,
                             onTask: @escaping @Sendable (MailboxTask, String) async -> Void) {
        guard pollingTask == nil else { return }
        let token = UUID()
        pollingToken = token
        pollingTask = Task { [weak self] in
            guard let self else { return }
            // Al terminar el bucle (apagado, cancelación), libera el hueco solo si
            // este bucle sigue siendo el vigente: si no, el usuario ya arrancó otro.
            defer {
                Task { [weak self] in
                    await self?.clearPollingIfCurrent(token)
                }
            }
            #if canImport(UserNotifications)
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            #endif
            while !Task.isCancelled {
                guard Self.isEnabled else { break }
                BackgroundRunKeeper.shared.begin()
                do {
                    let review = try await self.review()
                    if !review.exhausted.isEmpty {
                        await self.signalExhausted(review.exhausted)
                    }
                    if !review.pending.isEmpty {
                        await self.signalPendingTasks(review.pending.map(\.task))
                        for delivery in review.pending {
                            guard !Task.isCancelled, Self.isEnabled else { break }
                            await onTask(delivery.task, delivery.body)
                        }
                    }
                } catch {
                    // El buzón no está disponible (sin Google, sin red): se reintenta en
                    // el siguiente ciclo. Nada se pierde: el buzón es la fuente de verdad.
                    GUSFlightRecorder.shared.record("gus.mailbox.poll_error", ["error": error.localizedDescription])
                }
                BackgroundRunKeeper.shared.end()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func clearPollingIfCurrent(_ token: UUID) {
        if pollingToken == token {
            pollingTask = nil
            pollingToken = nil
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingToken = nil
    }

    // MARK: - Señales (notificaciones: avisan, no son el trabajo)

    /// Señal, no trabajo: avisa que hay tareas pendientes en el buzón. El trabajo
    /// siempre se lee del buzón, nunca de la notificación. Solo se publica si la app
    /// no está al frente (si está al frente, la tarea se ejecuta directamente).
    private func signalPendingTasks(_ tasks: [MailboxTask]) {
        guard !tasks.isEmpty else { return }
        postSignalNotification(
            identifier: "gus.mailbox.pending",
            title: "Buzón [GUS]: \(tasks.count) tarea(s) pendiente(s)",
            body: tasks.map(\.id).joined(separator: ", ")
        )
    }

    /// Una tarea agotó sus intentos: avisa para que la revise el usuario, no se reintenta más.
    private func signalExhausted(_ tasks: [MailboxTask]) {
        for task in tasks {
            postSignalNotification(
                identifier: "gus.mailbox.exhausted.\(task.id)",
                title: "Buzón [GUS]: tarea sin completar",
                body: "\(task.id) falló \(Self.maxAttempts) veces. Revísala en el buzón."
            )
        }
    }

    private func postSignalNotification(identifier: String, title: String, body: String) {
        #if canImport(UserNotifications) && canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(80))
        content.body = String(body.prefix(240))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
        #endif
    }

    // MARK: - Caché local (nunca es la fuente de verdad)

    public func attempts(_ id: String) -> Int {
        UserDefaults.standard.integer(forKey: "gus.mailbox.attempts.\(id)")
    }

    private func noteAttempt(_ id: String) {
        UserDefaults.standard.set(attempts(id) + 1, forKey: "gus.mailbox.attempts.\(id)")
    }

    private func clearAttempts(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "gus.mailbox.attempts.\(id)")
    }

    private func firstSeenEnCurso(_ id: String) -> Date? {
        let raw = UserDefaults.standard.double(forKey: "gus.mailbox.enCursoSince.\(id)")
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private func noteEnCurso(_ id: String, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "gus.mailbox.enCursoSince.\(id)")
    }

    private func clearEnCurso(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "gus.mailbox.enCursoSince.\(id)")
    }
}

public enum GUSMailboxError: Error, LocalizedError {
    case noOwnEmail

    public var errorDescription: String? {
        switch self {
        case .noOwnEmail:
            return "No puedo determinar tu correo de Google para escribir en el buzón [GUS]. Vuelve a conectar tu cuenta de Google."
        }
    }
}

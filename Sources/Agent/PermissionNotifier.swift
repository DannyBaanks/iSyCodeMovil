import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Asks for the agent's permissions with a native iOS notification when the person is in
/// another app, with Approve / Deny buttons like any other iOS alert.
///
/// Buttons: Approve (once), Approve always (for the rest of the session) and Deny. Tools that
/// must ask every time never get "always". Approving requires the phone to be unlocked, so a
/// notification on a locked screen cannot authorise an action on its own. A stale answer (the
/// request was already resolved) is ignored.
@MainActor
public final class PermissionNotifier {
    public static let shared = PermissionNotifier()

    public static let categoryID = "iyscode.permission"
    public static let onceCategoryID = "iyscode.permission.once"
    public static let approveID = "iyscode.permission.approve"
    public static let alwaysID = "iyscode.permission.always"
    public static let sequenceID = "iyscode.permission.sequence"
    public static let denyID = "iyscode.permission.deny"
    public static let requestKey = "permissionRequestId"

    /// Requests whose tool asks every time, so "always" is not offered. Filled by the agent loop.
    private var askEveryTime: Set<String> = []

    public func note(requestID: String, askEveryTime: Bool) {
        if askEveryTime { self.askEveryTime.insert(requestID) }
    }

    /// Set by the store: receives the answer the person chose from the notification.
    public var onDecision: ((String, PermissionResponse.Decision) -> Void)?

    /// Registers the Approve / Deny buttons. Call once at launch.
    public func registerCategory() {
        let approve = UNNotificationAction(identifier: Self.approveID, title: "Aprobar", options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: Self.alwaysID, title: "Aprobar siempre", options: [.authenticationRequired])
        // Una sola aprobación de alcance para el turno: cubre la secuencia de operaciones
        // WDA (iphone_*) de esa tarea, sin ser "siempre". Se ofrece en ambas categorías
        // porque no es un permiso permanente, aunque la herramienta pida aprobación cada vez.
        let sequence = UNNotificationAction(identifier: Self.sequenceID, title: "Permitir secuencia", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyID, title: "Denegar", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [approve, sequence, always, deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.onceCategoryID, actions: [approve, sequence, deny], intentIdentifiers: [], options: [])
        ])
    }

    /// Asks for notification permission the first time. Do it while the app is on screen,
    /// because the system prompt cannot appear from the background.
    public func prepare() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Posts the notification only if the app is not the one on screen.
    public func notify(requestID: String, tool: String, command: String, explanation: String) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = "iSyCode pide permiso"
        var body = String(explanation.prefix(160))
        let detail = String(command.prefix(120))
        body += "\n\(tool)" + (detail.isEmpty ? "" : " · \(detail)")
        content.body = body
        content.sound = .default
        content.categoryIdentifier = askEveryTime.contains(requestID) ? Self.onceCategoryID : Self.categoryID
        content.userInfo = [Self.requestKey: requestID]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.identifier(requestID), content: content, trigger: nil)
        )
    }

    /// Removes the notification once the request is answered somewhere else.
    public func clear(requestID: String) {
        askEveryTime.remove(requestID)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(requestID)])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(requestID)])
    }

    /// Maps a tapped button to a decision. Anything else (opening the alert, dismissing it) is
    /// not an answer, so the request keeps waiting.
    nonisolated public static func decision(forAction identifier: String) -> PermissionResponse.Decision? {
        switch identifier {
        case approveID: return .allowOnce
        case alwaysID: return .allowAlways
        case sequenceID: return .allowSequence
        case denyID: return .deny
        default: return nil
        }
    }

    public func deliver(requestID: String, decision: PermissionResponse.Decision) {
        onDecision?(requestID, decision)
    }

    private static func identifier(_ requestID: String) -> String { "iyscode.permission.\(requestID)" }
}

import Foundation
import SwiftUI

public enum GoogleConnectionState: Equatable, Sendable {
    case needsClientID
    case notConnected
    case expired(email: String?)
    case readOnly(email: String?, services: [GoogleService])
    case connected(email: String?, services: [GoogleService])

    public var badgeText: String {
        switch self {
        case .needsClientID: return "Falta ID OAuth"
        case .notConnected: return "Google sin conectar"
        case .expired: return "Sesión caducada"
        case .readOnly(_, let services):
            return services.isEmpty ? "Conectado · sin permisos" : "Google · solo lectura"
        case .connected(_, let services):
            return "Google conectado · \(services.count) \(services.count == 1 ? "servicio" : "servicios")"
        }
    }

    public var shortChipText: String {
        switch self {
        case .needsClientID: return "Google: configurar"
        case .notConnected: return "Google: sin conectar"
        case .expired: return "Google: sesión caducada"
        case .readOnly: return "Google: solo lectura"
        case .connected(_, let services):
            return "Google: \(services.count) listos"
        }
    }

    public var tone: ConnectionBadgeTone {
        switch self {
        case .needsClientID, .notConnected: return .needsSetup
        case .expired: return .expired
        case .readOnly, .connected: return .ready
        }
    }

    public var symbol: String {
        switch self {
        case .needsClientID: return "key.fill"
        case .notConnected: return "person.crop.circle.badge.questionmark"
        case .expired: return "exclamationmark.arrow.circlepath"
        case .readOnly: return "eye.circle.fill"
        case .connected: return "checkmark.circle.fill"
        }
    }

    public var primaryCTATitle: String {
        switch self {
        case .needsClientID: return "Configurar Google OAuth"
        case .notConnected: return "Conectar Google"
        case .expired: return "Volver a conectar"
        case .readOnly, .connected: return "Gestionar permisos"
        }
    }

    public var isAuthorizedSession: Bool {
        switch self {
        case .readOnly, .connected: return true
        default: return false
        }
    }
}

public enum HostConnectionState: Equatable, Sendable {
    case connected(label: String)
    case checking
    case paused
    case expired
    case rejected
    case unavailable(reason: String)
    case unverified

    public var badgeText: String {
        switch self {
        case .connected(let label): return label
        case .checking: return "Comprobando equipo"
        case .paused: return "Equipo en pausa"
        case .expired: return "Sesión de equipo caducada"
        case .rejected: return "Credencial rechazada"
        case .unavailable(let reason): return reason.isEmpty ? "Equipo sin conexión" : reason
        case .unverified: return "Equipo: estado no verificado"
        }
    }

    public var shortChipText: String {
        switch self {
        case .connected: return "Equipo: conectado"
        case .checking: return "Equipo: comprobando"
        case .paused: return "Equipo: en pausa"
        case .expired: return "Equipo: caducado"
        case .rejected: return "Equipo: rechazado"
        case .unavailable: return "Equipo: sin conexión"
        case .unverified: return "Equipo: no verificado"
        }
    }

    public var tone: ConnectionBadgeTone {
        switch self {
        case .connected: return .ready
        case .checking: return .checking
        case .paused, .unverified: return .offline
        case .expired: return .expired
        case .rejected, .unavailable: return .error
        }
    }

    public var symbol: String {
        switch self {
        case .connected: return "desktopcomputer"
        case .checking: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .expired: return "clock.badge.exclamationmark"
        case .rejected: return "lock.slash"
        case .unavailable: return "wifi.slash"
        case .unverified: return "questionmark.circle"
        }
    }
}

public enum GoogleDeepLinkTarget: Equatable, Sendable {
    case googleHome
    case googleOAuthSetup
    case authorizeService(GoogleService)
    case reconnectExpired
}

public struct AssistantActionAvailability: Equatable, Sendable {
    public let isReady: Bool
    public let badgeLabel: String
    public let blockedReason: String?
    public let ctaTitle: String?
    public let target: GoogleDeepLinkTarget?

    public init(
        isReady: Bool,
        badgeLabel: String,
        blockedReason: String?,
        ctaTitle: String?,
        target: GoogleDeepLinkTarget?
    ) {
        self.isReady = isReady
        self.badgeLabel = badgeLabel
        self.blockedReason = blockedReason
        self.ctaTitle = ctaTitle
        self.target = target
    }
}

public enum ConnectionStatusEvaluator {
    private static let writeScopes: Set<String> = [
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/tasks",
        "https://www.googleapis.com/auth/documents",
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/classroom.announcements",
    ]

    public static func evaluateGoogle(
        signedIn: Bool,
        email: String?,
        grantedScopes: Set<String>,
        clientId: String,
        sessionExpired: Bool
    ) -> GoogleConnectionState {
        if sessionExpired {
            return .expired(email: email)
        }
        if !signedIn {
            return GoogleOAuth.isPlausibleClientId(clientId) ? .notConnected : .needsClientID
        }
        let grantedServices = GoogleService.allCases.filter { $0.isGranted(grantedScopes) }
        let hasWriteScope = !grantedScopes.isDisjoint(with: writeScopes)
        if hasWriteScope {
            return .connected(email: email, services: grantedServices)
        }
        return .readOnly(email: email, services: grantedServices)
    }

    public static func evaluateHost(
        backendMode: BackendMode,
        connectionHealth: ConnectionHealth,
        remoteProviderName: String?,
        sandboxLink: SandboxLinkState?,
        hostLiveness: MobileHostLiveness,
        heartbeatState: MobileHeartbeatState,
        monitorStatus: String
    ) -> HostConnectionState {
        if backendMode == .remote {
            let label = remoteProviderName ?? "Computadora"
            switch connectionHealth {
            case .connected: return .connected(label: "\(label) · conectado")
            case .connecting: return .checking
            case .disconnected: return .unavailable(reason: "\(label) · sin conexión")
            }
        }

        if let sandboxLink {
            return sandboxLink.phase == "active"
                ? .connected(label: "Sandbox PC · \(sandboxLink.projectName)")
                : .unavailable(reason: "Sandbox PC · \(sandboxLink.phaseLabel)")
        }

        switch heartbeatState {
        case .connected:
            return .connected(label: "Host ISyCode · conectado")
        case .connecting:
            return .checking
        case .paused:
            return .paused
        case .expired:
            return .expired
        case .credentialRejected:
            return .rejected
        case .unavailable:
            return .unavailable(reason: "Host ISyCode · sin conexión")
        case .notPaired:
            break
        }

        if hostLiveness == .checking { return .checking }
        if hostLiveness == .alive { return .connected(label: "Host ISyCode · activo") }
        if hostLiveness == .unavailable { return .unavailable(reason: "Host ISyCode · no responde") }

        let lowered = monitorStatus.lowercased()
        if lowered.hasPrefix("conectado") {
            return .connected(label: "Monitor PC · conectado")
        }
        if lowered.hasPrefix("sin conexión") || lowered.hasPrefix("error") {
            return .unavailable(reason: monitorStatus)
        }

        return .unverified
    }

    public static func availability(
        for action: QuickAction,
        googleState: GoogleConnectionState,
        grantedScopes: Set<String>
    ) -> AssistantActionAvailability {
        guard let service = action.service else {
            let label = action.kind == .saveMemory ? "En este iPhone" : "Local"
            return AssistantActionAvailability(
                isReady: true,
                badgeLabel: label,
                blockedReason: nil,
                ctaTitle: nil,
                target: nil
            )
        }
        return availability(forService: service, mode: .read, googleState: googleState, grantedScopes: grantedScopes)
    }

    public static func availability(
        for tool: AssistantToolInfo,
        googleState: GoogleConnectionState,
        grantedScopes: Set<String>
    ) -> AssistantActionAvailability {
        guard let service = tool.service else {
            return AssistantActionAvailability(
                isReady: true,
                badgeLabel: tool.mode.label,
                blockedReason: nil,
                ctaTitle: nil,
                target: nil
            )
        }
        return availability(forService: service, mode: tool.mode, googleState: googleState, grantedScopes: grantedScopes)
    }

    public static func availability(
        forService service: GoogleService,
        mode: ToolMode,
        googleState: GoogleConnectionState,
        grantedScopes: Set<String>
    ) -> AssistantActionAvailability {
        let modeBadge = mode == .writeConfirmed ? "Escritura + confirmación" : "Lectura"
        switch googleState {
        case .needsClientID:
            return AssistantActionAvailability(
                isReady: false,
                badgeLabel: "Requiere Google · \(modeBadge)",
                blockedReason: "Falta configurar el ID de cliente OAuth iOS para conectar Google.",
                ctaTitle: "Configurar Google",
                target: .googleOAuthSetup
            )
        case .notConnected:
            return AssistantActionAvailability(
                isReady: false,
                badgeLabel: "Requiere Google · \(modeBadge)",
                blockedReason: "Conecta tu cuenta de Google para usar \(service.title).",
                ctaTitle: "Conectar Google",
                target: .googleHome
            )
        case .expired:
            return AssistantActionAvailability(
                isReady: false,
                badgeLabel: "Sesión caducada · \(modeBadge)",
                blockedReason: "Tu sesión de Google caducó. Vuelve a conectar para usar \(service.title).",
                ctaTitle: "Volver a conectar",
                target: .reconnectExpired
            )
        case .readOnly, .connected:
            if service.isGranted(grantedScopes) {
                return AssistantActionAvailability(
                    isReady: true,
                    badgeLabel: modeBadge,
                    blockedReason: nil,
                    ctaTitle: nil,
                    target: nil
                )
            }
            return AssistantActionAvailability(
                isReady: false,
                badgeLabel: "Falta permiso · \(modeBadge)",
                blockedReason: "Tu cuenta está conectada, pero falta autorizar \(service.title).",
                ctaTitle: "Autorizar \(service.title)",
                target: .authorizeService(service)
            )
        }
    }
}

public struct HumanConfirmationSummary: Equatable, Sendable {
    public let headline: String
    public let explanation: String
    public let readableDetails: [(String, String)]
    public let technicalDetails: [(String, String)]

    public static func == (lhs: HumanConfirmationSummary, rhs: HumanConfirmationSummary) -> Bool {
        lhs.headline == rhs.headline
            && lhs.explanation == rhs.explanation
            && lhs.readableDetails.map(\.0) == rhs.readableDetails.map(\.0)
            && lhs.readableDetails.map(\.1) == rhs.readableDetails.map(\.1)
            && lhs.technicalDetails.map(\.0) == rhs.technicalDetails.map(\.0)
            && lhs.technicalDetails.map(\.1) == rhs.technicalDetails.map(\.1)
    }
}

public enum HumanConfirmationFormatter {
    public static func format(action: PendingAction) -> HumanConfirmationSummary {
        let recipient = action.details.first(where: { $0.0 == "Para" })?.1
        let titleVal = action.details.first(where: { $0.0 == "Título" || $0.0 == "Nota" || $0.0 == "Pendiente" })?.1
        let headline: String
        switch action.toolId {
        case "gmail.write.send":
            headline = recipient.map { "Enviar correo a \($0)" } ?? "Enviar correo"
        case "googlecalendar.write.event":
            headline = titleVal.map { "Crear evento en Calendar: \($0)" } ?? "Crear evento en Calendar"
        case "googletasks.write.create":
            headline = titleVal.map { "Agregar pendiente: \($0)" } ?? "Agregar pendiente en Tasks"
        case "googledocs.write.create":
            headline = titleVal.map { "Crear documento: \($0)" } ?? "Crear Google Doc"
        case "googlesheets.write.append_row":
            headline = "Agregar fila en Google Sheets"
        case "googleclassroom.write.announcement":
            headline = "Publicar anuncio en Classroom"
        case AssistantCatalog.saveContext:
            headline = titleVal.map { "Guardar en memoria: \($0)" } ?? "Guardar en memoria"
        default:
            headline = action.title
        }

        let toolInfo = AssistantCatalog.tool(action.toolId)
        var technical: [(String, String)] = [("Tool ID", action.toolId)]
        if let service = toolInfo?.service {
            technical.append(("Servicio", service.title))
            technical.append(("Scopes", service.scopes.joined(separator: ", ")))
        }
        if let endpoint = toolInfo?.endpoint {
            technical.append(("Endpoint", endpoint))
        }

        return HumanConfirmationSummary(
            headline: headline,
            explanation: action.message,
            readableDetails: action.details,
            technicalDetails: technical
        )
    }

    public static func format(permission event: TimelineEvent) -> HumanConfirmationSummary {
        let tool = event.permissionTool ?? "herramienta"
        let command = event.permissionCommand ?? ""
        let headline: String
        switch tool {
        case "gmail.write.send":
            headline = "Enviar correo con Gmail"
        case "googlecalendar.write.event":
            headline = "Crear evento en Google Calendar"
        case "googletasks.write.create":
            headline = "Crear pendiente en Google Tasks"
        case "googledocs.write.create":
            headline = "Crear documento en Google Docs"
        case "googlesheets.write.append_row":
            headline = "Agregar fila en Google Sheets"
        case "googleclassroom.write.announcement":
            headline = "Publicar anuncio en Classroom"
        case AssistantCatalog.saveContext:
            headline = "Guardar nota en la memoria de GUS"
        case "edit_file", "write_file":
            headline = "Guardar cambios en un archivo"
        case "delete_file":
            headline = "Eliminar un archivo del proyecto"
        case "run_command", "bash", "shell":
            headline = "Ejecutar comando en el entorno"
        default:
            headline = "Autorizar acción: \(tool)"
        }

        var readable: [(String, String)] = []
        if !command.isEmpty {
            readable.append(("Resumen", String(command.prefix(240))))
        }
        if let scope = event.permissionScope, !scope.isEmpty {
            readable.append(("Dónde aplica", scope))
        }

        var technical: [(String, String)] = [("Herramienta", tool)]
        if !command.isEmpty {
            technical.append(("Payload", command))
        }
        if let id = event.permissionRequestId {
            technical.append(("Request ID", id))
        }

        return HumanConfirmationSummary(
            headline: headline,
            explanation: event.permissionExplanation ?? "Esta acción necesita tu confirmación explícita antes de ejecutarse.",
            readableDetails: readable,
            technicalDetails: technical
        )
    }
}

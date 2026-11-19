import Foundation

/// Shared presentation for backend errors. The original error remains available for inspection.
enum ConversationIssue: Equatable {
    case cancelled, quota, rateLimit, unsupported, authorization, accessDenied, model, offline, service, unknown

    init(_ raw: String) {
        let text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if text.contains("cancel") || words.contains("stopped") { self = .cancelled }
        else if text.contains("insufficient_quota") || words.contains("quota") || words.contains("cuota") { self = .quota }
        else if words.contains("429") || text.contains("rate limit") { self = .rateLimit }
        else if text.contains("unsupported") || text.contains("no admite") || text.contains("incompatible") { self = .unsupported }
        else if words.contains("403") || text.contains("permiso denegado") || text.contains("permission denied") { self = .accessDenied }
        else if !words.isDisjoint(with: ["401", "unauthorized", "authentication", "autenticacion"]) || text.contains("invalid api key") { self = .authorization }
        else if text.contains("model") && (words.contains("404") || text.contains("cargar") || text.contains("not found") || text.contains("no disponible")) { self = .model }
        else if !words.isDisjoint(with: ["offline", "network", "disconnected"]) || text.contains("sin conexion") || text.contains("timed out") || text.contains("not connected") { self = .offline }
        else if !words.isDisjoint(with: ["500", "502", "503", "504"]) { self = .service }
        else { self = .unknown }
    }

    var title: String {
        switch self {
        case .cancelled: return "Operación cancelada"
        case .quota: return "Cuota del proveedor agotada"
        case .rateLimit: return "Demasiadas solicitudes"
        case .unsupported: return "Contenido incompatible"
        case .authorization: return "La cuenta necesita atención"
        case .accessDenied: return "Acceso denegado"
        case .model: return "Modelo no disponible"
        case .offline: return "No se pudo conectar"
        case .service: return "El servicio tuvo un problema"
        case .unknown: return "No se completó la operación"
        }
    }

    var message: String {
        switch self {
        case .cancelled: return "Revisa la actividad para ver qué pasos alcanzaron a ejecutarse."
        case .quota: return "Revisa la cuota en tu cuenta o elige otro proveedor desde el compositor."
        case .rateLimit: return "Espera un momento antes de volver a intentarlo."
        case .unsupported: return "Consulta el detalle para identificar qué debes cambiar en el mensaje o en sus adjuntos."
        case .authorization: return "Abre Conexiones para revisar la sesión del proveedor."
        case .accessDenied: return "Consulta el permiso requerido en los detalles antes de continuar."
        case .model: return "Abre Modelo desde el compositor y elige uno disponible."
        case .offline: return "Comprueba que el iPhone pueda alcanzar el servicio y vuelve a intentarlo."
        case .service: return "Consulta la actividad antes de repetir la operación."
        case .unknown: return "Abre los detalles para ver qué informó el servicio."
        }
    }
}

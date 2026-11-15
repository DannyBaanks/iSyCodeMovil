import Foundation

/// Opt-in allowlist for tools exposed to the on-device GUS model.
/// Enabling a tool never replaces the per-operation approval for mutations.
public enum GUSToolPermissionCatalog {
    public struct Permission: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let changesData: Bool

        public init(id: String, title: String, detail: String, changesData: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.changesData = changesData
        }
    }

    public static let permissions: [Permission] = [
        .init(id: "list_directory", title: "Ver archivos y carpetas", detail: "Lista el workspace elegido."),
        .init(id: "file_info", title: "Ver detalles", detail: "Consulta metadatos de archivos y carpetas."),
        .init(id: "search_files", title: "Buscar archivos y texto", detail: "Busca nombres y contenido en el workspace."),
        .init(id: "read_file", title: "Leer archivos", detail: "El contenido leído se envía al modelo local GUS."),
        .init(id: "write_file", title: "Crear o reemplazar archivos", detail: "Cada escritura pide aprobación en pantalla.", changesData: true),
        .init(id: "edit_file", title: "Editar texto exacto", detail: "Reemplaza una coincidencia exacta; pide aprobación cada vez.", changesData: true),
        .init(id: "create_directory", title: "Crear carpetas", detail: "Cada creación pide aprobación en pantalla.", changesData: true),
        .init(id: "move_file", title: "Mover o renombrar", detail: "Cada movimiento pide aprobación en pantalla.", changesData: true),
        .init(id: "delete_file", title: "Eliminar archivos", detail: "Cada eliminación pide aprobación en pantalla.", changesData: true),
        .init(id: "notifications.schedule", title: "Programar recordatorios", detail: "Requiere permiso de iOS y aprobación por recordatorio.", changesData: true),
        .init(id: "notifications.cancel", title: "Cancelar recordatorios", detail: "Solo cancela recordatorios creados por iSyCode.", changesData: true),
        .init(id: "shortcuts.run", title: "Abrir tu atajo configurado", detail: "Puede salir de la app y pide aprobación cada vez.", changesData: true)
    ]

    public static let unsupported = [
        "Shell y ejecución de procesos (iOS no los permite)",
        "Red arbitraria y ajustes de iOS",
        "Archivos fuera del workspace o carpeta elegida en Archivos",
        "Datos privados de otras apps"
    ]

    public static func isEnabled(_ toolName: String, defaults: UserDefaults = .standard) -> Bool {
        guard permissions.contains(where: { $0.id == toolName }) else { return false }
        return defaults.bool(forKey: key(for: toolName))
    }

    public static func setEnabled(_ enabled: Bool, for toolName: String, defaults: UserDefaults = .standard) {
        guard permissions.contains(where: { $0.id == toolName }) else { return }
        defaults.set(enabled, forKey: key(for: toolName))
    }

    private static func key(for toolName: String) -> String { "gus.local.permission.\(toolName)" }
}

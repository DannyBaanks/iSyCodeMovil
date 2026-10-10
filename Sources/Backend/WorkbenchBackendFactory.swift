import Foundation

/// Fábrica para crear backends según el tipo de pairing/runtime.
/// Centraliza la lógica de instanciación y permite añadir nuevos backends
/// sin tocar el resto de la app.
public enum WorkbenchBackendFactory {
    
    /// Errores de la fábrica
    public enum FactoryError: Error, LocalizedError, Sendable {
        case unsupportedBackendType(String)
        case invalidPairingLink(String)
        case missingConfiguration(String)
        
        public var errorDescription: String? {
            switch self {
            case .unsupportedBackendType(let type): return "Unsupported backend type: \(type)"
            case .invalidPairingLink(let reason): return "Invalid pairing link: \(reason)"
            case .missingConfiguration(let detail): return "Missing configuration: \(detail)"
            }
        }
    }
    
    /// Crea un backend a partir de una pairing link parseada.
    /// - Parameter pairing: Pairing genérico con tipo de backend incluido
    /// - Returns: Backend configurado y listo para connectRemote
    @MainActor
    public static func makeBackend(from pairing: BackendPairing) throws -> WorkbenchBackend {
        switch pairing {
        case .openCode(let opencodePairing):
            return OpenCodeRemoteBackend(pairing: opencodePairing)
        case .codex:
            return CodexRemoteBackend()
        case .grok:
            return GrokRemoteBackend()
        case .remote(let remotePairing):
            switch remotePairing.type {
            case .opencode, .openisy:
                let opencodePairing = OpenCodePairing(
                    scheme: remotePairing.scheme,
                    host: remotePairing.host,
                    port: remotePairing.port,
                    username: remotePairing.username,
                    password: remotePairing.password,
                    directory: remotePairing.directory
                )
                return OpenCodeRemoteBackend(pairing: opencodePairing)
            case .crush:
                return CrushRemoteBackend()
            case .claudeCode:
                return ClaudeCodeRemoteBackend()
            case .gemini:
                return GeminiRemoteBackend()
            case .codex:
                throw FactoryError.missingConfiguration("Codex requires a typed Codex pairing.")
            case .grok:
                throw FactoryError.missingConfiguration("Grok requires a typed Grok pairing.")
            }
        }
    }
    
    /// Crea un backend nativo (sandbox local)
    @MainActor
    public static func makeNativeBackend(workspaceBookmark: Data? = nil, forceOfflineDemo: Bool = false,
                                         modelDownloadManager: GUSModelDownloadManager = .shared) -> WorkbenchBackend {
        NativeSwiftBackend(workspaceBookmark: workspaceBookmark, forceOfflineDemo: forceOfflineDemo,
                           modelDownloadManager: modelDownloadManager)
    }
    
    /// Crea un backend demo/fixture para testing
    @MainActor
    public static func makeDemoBackend() -> WorkbenchBackend {
        NativeSwiftBackend(forceOfflineDemo: true) // demo aislado, sin claves ni permisos de Files
    }
    
    /// Parsea una URL sin mezclar credenciales Codex con auth Basic de OpenCode.
    public static func parsePairingURL(_ url: String) throws -> (RemoteBackendType, BackendPairing) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme != nil else {
            throw FactoryError.invalidPairingLink("Invalid URL format")
        }
        
        let scheme = components.scheme ?? ""
        let host = components.host ?? ""
        
        // Determinar tipo por scheme
        let backendType: RemoteBackendType
        switch scheme {
        case "iyscodemovil":
            // iyscodemovil://pair?... -> OpenCode
            backendType = .opencode
        case "opencodenative":
            // legacy
            backendType = .opencode
        case "openisy":
            backendType = .openisy
        case "crush":
            backendType = .crush
        case "codex":
            backendType = .codex
        case "grok":
            backendType = .grok
        case "claude-code":
            backendType = .claudeCode
        case "gemini":
            backendType = .gemini
        default:
            // Default a opencode para compatibilidad
            backendType = .opencode
        }

        if backendType == .codex {
            do {
                return (.codex, .codex(try CodexPairing.parse(value)))
            } catch {
                throw FactoryError.invalidPairingLink(error.localizedDescription)
            }
        }
        if backendType == .grok {
            do {
                return (.grok, .grok(try GrokPairing.parse(value)))
            } catch {
                throw FactoryError.invalidPairingLink(error.localizedDescription)
            }
        }
        
        // Parsear query items
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            guard items.updateValue(value, forKey: item.name) == nil else {
                throw FactoryError.invalidPairingLink("Duplicate query parameter: \(item.name)")
            }
        }
        
        let remoteScheme = items["scheme"] ?? "http"
        guard remoteScheme == "http" || remoteScheme == "https",
              let host = items["host"], !host.isEmpty,
              let portText = items["port"], let port = Int(portText), (1...65535).contains(port),
              let password = items["password"], !password.isEmpty else {
            throw FactoryError.invalidPairingLink("Missing required fields: host, port, password")
        }
        
        let pairing = RemotePairing(
            type: backendType,
            scheme: remoteScheme,
            host: host,
            port: port,
            username: items["username"] ?? "user",
            password: password,
            directory: items["directory"] ?? ""
        )
        
        if backendType == .opencode || backendType == .openisy {
            let opencodePairing = OpenCodePairing(
                scheme: pairing.scheme,
                host: pairing.host,
                port: pairing.port,
                username: pairing.username,
                password: pairing.password,
                directory: pairing.directory
            )
            return (backendType, .openCode(opencodePairing))
        }
        return (backendType, .remote(pairing))
    }
    
    /// Tipos de backend soportados (backends que existen y se conectan)
    public static var supportedBackendTypes: [RemoteBackendType] {
        [.opencode, .openisy, .codex, .grok]
    }

    /// Tipos de backend con stub compilado pero sin transporte implementado
    public static var stubbedBackendTypes: [RemoteBackendType] {
        [.crush, .claudeCode, .gemini]
    }

    /// Tipos de backend planificados (no implementados)
    public static var plannedBackendTypes: [RemoteBackendType] {
        stubbedBackendTypes
    }

    /// Verifica si un tipo de backend está implementado (conecta de verdad)
    public static func isImplemented(_ type: RemoteBackendType) -> Bool {
        supportedBackendTypes.contains(type)
    }
}

import Foundation
import SwiftUI

/// Explicit, text-first readiness states for the active AI runtime.
public enum RuntimeReadinessState: Equatable, Sendable {
    case notConfigured
    case needsModel
    case needsKey
    case checking
    case ready
    case demo
    case error(String)

    public var badgeText: String {
        switch self {
        case .notConfigured: return "Sin configurar"
        case .needsModel: return "Modelo no disponible"
        case .needsKey: return "Falta API key"
        case .checking: return "Comprobando"
        case .ready: return "Listo"
        case .demo: return "Guion de demo"
        case .error: return "Error"
        }
    }

    public var symbol: String {
        switch self {
        case .notConfigured: return "slider.horizontal.3"
        case .needsModel: return "arrow.down.circle"
        case .needsKey: return "key.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .demo: return "play.rectangle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    public var tone: ConnectionBadgeTone {
        switch self {
        case .notConfigured, .needsModel, .needsKey: return .needsSetup
        case .checking: return .checking
        case .ready: return .ready
        case .demo: return .demo
        case .error: return .error
        }
    }

    public var isUsableForChat: Bool {
        switch self {
        case .ready, .demo: return true
        default: return false
        }
    }

    public var errorDetail: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

public enum ConnectionBadgeTone: String, Equatable, Sendable {
    case ready
    case checking
    case needsSetup
    case expired
    case error
    case demo
    case offline

    public var semanticColor: Color {
        switch self {
        case .ready: return OCColor.success
        case .checking: return OCColor.info
        case .needsSetup: return OCColor.warning
        case .expired: return OCColor.warning
        case .error: return OCColor.danger
        case .demo: return OCColor.info
        case .offline: return OCColor.textFaint
        }
    }
}

public struct RuntimeSelectionSnapshot: Equatable, Sendable {
    public let providerID: String?
    public let providerName: String
    public let modelName: String?
    public let isLocal: Bool
    public let isRemoteHost: Bool
    public let readiness: RuntimeReadinessState
    public let lastVerifiedAt: Date?

    public init(
        providerID: String?,
        providerName: String,
        modelName: String?,
        isLocal: Bool,
        isRemoteHost: Bool = false,
        readiness: RuntimeReadinessState,
        lastVerifiedAt: Date?
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelName = modelName
        self.isLocal = isLocal
        self.isRemoteHost = isRemoteHost
        self.readiness = readiness
        self.lastVerifiedAt = lastVerifiedAt
    }

    public var primaryCTATitle: String {
        switch readiness {
        case .ready:
            return "Continuar con \(providerName)"
        case .demo:
            return "Continuar en modo demo"
        case .needsModel:
            return "Descargar modelo local"
        case .needsKey:
            return "Introducir API key de \(providerName)"
        case .checking:
            return "Comprobando \(providerName)…"
        case .error:
            return "Reintentar conexión"
        case .notConfigured:
            return "Configurar motor"
        }
    }

    public var runtimeSummaryLine: String {
        switch readiness {
        case .ready:
            let model = modelName ?? "Modelo activo"
            return isLocal ? "Local en este iPhone · \(model)" : "\(providerName) · \(model)"
        case .demo:
            return "Guion de demo local · sin API key ni red"
        case .needsModel:
            return "GUS local seleccionado · falta descargar un modelo GGUF"
        case .needsKey:
            return "\(providerName) seleccionado · falta guardar la API key"
        case .checking:
            return "Verificando \(providerName)…"
        case .error(let detail):
            return detail.isEmpty ? "No pude iniciar \(providerName)" : detail
        case .notConfigured:
            return "Elige un motor local en tu iPhone o un proveedor conectado"
        }
    }
}

public enum RuntimeSelectionEvaluator {
    public static func evaluate(
        backendMode: BackendMode,
        connectionHealth: ConnectionHealth,
        connectionStatus: String,
        configuredProviderID: String?,
        configuredModelName: String?,
        selectedModel: ModelInfo?,
        hasSavedAPIKey: Bool,
        hasInstalledLocalModel: Bool,
        sandboxUsesLiveModel: Bool,
        isChecking: Bool,
        lastError: String?,
        lastVerifiedAt: Date?
    ) -> RuntimeSelectionSnapshot {
        if isChecking {
            let provider = configuredProviderID.flatMap(SandboxModelProvider.provider(id:))
            return RuntimeSelectionSnapshot(
                providerID: configuredProviderID,
                providerName: provider?.name ?? "Motor de IA",
                modelName: selectedModel?.name ?? configuredModelName,
                isLocal: configuredProviderID == "gus-local",
                isRemoteHost: backendMode == .remote,
                readiness: .checking,
                lastVerifiedAt: lastVerifiedAt
            )
        }

        if backendMode == .remote {
            let name = selectedModel?.provider ?? "Computadora conectada"
            let readiness: RuntimeReadinessState
            switch connectionHealth {
            case .connected:
                readiness = .ready
            case .connecting:
                readiness = .checking
            case .disconnected:
                let msg = connectionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                readiness = msg.isEmpty ? .error("Conexión con la computadora perdida") : .error(msg)
            }
            return RuntimeSelectionSnapshot(
                providerID: selectedModel?.route ?? "remote",
                providerName: name,
                modelName: selectedModel?.name ?? configuredModelName,
                isLocal: false,
                isRemoteHost: true,
                readiness: readiness,
                lastVerifiedAt: lastVerifiedAt
            )
        }

        if backendMode == .native {
            if !sandboxUsesLiveModel {
                if let configuredProviderID,
                   let provider = SandboxModelProvider.provider(id: configuredProviderID) {
                    if configuredProviderID == "gus-local" && !hasInstalledLocalModel {
                        return RuntimeSelectionSnapshot(
                            providerID: provider.id,
                            providerName: provider.name,
                            modelName: configuredModelName,
                            isLocal: true,
                            readiness: .needsModel,
                            lastVerifiedAt: lastVerifiedAt
                        )
                    }
                    if configuredProviderID != "gus-local" && !hasSavedAPIKey {
                        return RuntimeSelectionSnapshot(
                            providerID: provider.id,
                            providerName: provider.name,
                            modelName: configuredModelName,
                            isLocal: false,
                            readiness: .needsKey,
                            lastVerifiedAt: lastVerifiedAt
                        )
                    }
                }
                return RuntimeSelectionSnapshot(
                    providerID: "scripted",
                    providerName: "Guion de demo",
                    modelName: selectedModel?.name ?? "Demo offline",
                    isLocal: true,
                    readiness: .demo,
                    lastVerifiedAt: lastVerifiedAt
                )
            }

            let resolvedProviderID = selectedModel?.route ?? configuredProviderID
            let provider = resolvedProviderID.flatMap(SandboxModelProvider.provider(id:))
            let isLocal = (resolvedProviderID == "gus-local") || (selectedModel?.isLocal ?? false)
            let providerName = provider?.name ?? selectedModel?.provider ?? (isLocal ? "GUS local" : "Proveedor conectado")
            let modelName = selectedModel?.name ?? configuredModelName

            if let lastError, !lastError.isEmpty {
                return RuntimeSelectionSnapshot(
                    providerID: resolvedProviderID,
                    providerName: providerName,
                    modelName: modelName,
                    isLocal: isLocal,
                    readiness: .error(lastError),
                    lastVerifiedAt: lastVerifiedAt
                )
            }

            return RuntimeSelectionSnapshot(
                providerID: resolvedProviderID,
                providerName: providerName,
                modelName: modelName,
                isLocal: isLocal,
                readiness: connectionHealth == .connected ? .ready : .checking,
                lastVerifiedAt: lastVerifiedAt
            )
        }

        // backendMode == .unconfigured: inspect persisted intent!
        if let configuredProviderID,
           let provider = SandboxModelProvider.provider(id: configuredProviderID) {
            let isLocal = configuredProviderID == "gus-local"
            if let lastError, !lastError.isEmpty {
                return RuntimeSelectionSnapshot(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelName: configuredModelName,
                    isLocal: isLocal,
                    readiness: .error(lastError),
                    lastVerifiedAt: lastVerifiedAt
                )
            }
            if isLocal {
                return RuntimeSelectionSnapshot(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelName: configuredModelName,
                    isLocal: true,
                    readiness: hasInstalledLocalModel ? .ready : .needsModel,
                    lastVerifiedAt: lastVerifiedAt
                )
            } else {
                return RuntimeSelectionSnapshot(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelName: configuredModelName,
                    isLocal: false,
                    readiness: hasSavedAPIKey ? .ready : .needsKey,
                    lastVerifiedAt: lastVerifiedAt
                )
            }
        }

        return RuntimeSelectionSnapshot(
            providerID: nil,
            providerName: "Motor sin configurar",
            modelName: nil,
            isLocal: false,
            readiness: .notConfigured,
            lastVerifiedAt: lastVerifiedAt
        )
    }
}

/// Persisted user intent for runtime, model, and last active conversation.
public enum RuntimeIntentDefaults {
    public static let onboardingCompletedKey = "iyscode.onboardingCompleted"
    public static let lastRuntimeModeKey = "iyscode.lastRuntimeMode" // "native" | "remote" | "demo"
    public static let lastSessionIDKey = "iyscode.lastSessionID"
    public static let lastSessionTitleKey = "iyscode.lastSessionTitle"
    public static let lastProjectIDKey = "iyscode.lastProjectID"
    public static let lastProjectNameKey = "iyscode.lastProjectName"
}

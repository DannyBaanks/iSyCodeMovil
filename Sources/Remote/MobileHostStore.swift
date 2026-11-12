import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum MobileHostLiveness: String, Sendable {
    case unknown
    case checking
    case alive
    case unavailable
}

public enum MobileHeartbeatState: String, Sendable {
    case notPaired
    case connecting
    case connected
    case paused
    case unavailable
    case credentialRejected
    case expired
}

@MainActor
public final class MobileHostStore: ObservableObject {
    private enum PairingStorageError: Error, LocalizedError {
        case keychainWriteFailed

        var errorDescription: String? {
            "ISyCode accepted the PIN, but iOS could not store the credential in Keychain. Revoke the issued key on the host before pairing again."
        }
    }

    @Published public private(set) var hostLiveness: MobileHostLiveness = .unknown
    @Published public private(set) var heartbeatState: MobileHeartbeatState = .notPaired
    @Published public private(set) var credential: MobileHostCredential?
    @Published public private(set) var isPairing = false
    @Published public private(set) var errorMessage: String?

    private let api = MobileHostAPI()
    private let credentialStore = MobileHostCredentialStore()
    private let defaults: UserDefaults
    private var heartbeatTask: Task<Void, Never>?
    private var isAppActive = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func restore() async {
        do {
            guard let (savedCredential, _) = try await credentialStore.load() else { return }
            credential = savedCredential
            if let expires = savedCredential.expirationDate, expires <= Date() {
                heartbeatState = .expired
            } else {
                heartbeatState = isAppActive ? .connecting : .paused
                if isAppActive { startHeartbeatLoop() }
            }
        } catch {
            errorMessage = "No se pudo leer la credencial guardada del host en el llavero."
            heartbeatState = .credentialRejected
        }
    }

    public func pair(baseURL: String, code: String) async {
        guard !isPairing else { return }
        isPairing = true
        errorMessage = nil
        hostLiveness = .checking
        defer { isPairing = false }

        do {
            let normalizedURL = try api.normalizedBaseURL(baseURL)
            try await api.checkHealth(baseURL: normalizedURL.absoluteString)
            hostLiveness = .alive
            let (newCredential, apiKey) = try await api.exchangePairingCode(
                baseURL: normalizedURL.absoluteString,
                code: code,
                deviceName: Self.deviceName
            )
            do {
                try await credentialStore.save(newCredential, apiKey: apiKey)
            } catch {
                throw PairingStorageError.keychainWriteFailed
            }
            credential = newCredential
            heartbeatState = isAppActive ? .connecting : .paused
            if isAppActive {
                await refreshHostAndHeartbeat()
                startHeartbeatLoop()
            }
        } catch {
            if hostLiveness == .checking { hostLiveness = .unavailable }
            heartbeatState = credential == nil ? .notPaired : heartbeatState
            errorMessage = error.localizedDescription
        }
    }

    public func forgetCredential() async {
        stopHeartbeatLoop()
        do {
            try await credentialStore.clear()
            credential = nil
            heartbeatState = .notPaired
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo eliminar la credencial del host del llavero."
        }
    }

    public func setAppActive(_ active: Bool) async {
        isAppActive = active
        stopHeartbeatLoop()
        guard active, credential != nil else {
            if credential != nil, heartbeatState != .expired, heartbeatState != .credentialRejected {
                heartbeatState = .paused
            }
            return
        }
        heartbeatState = .connecting
        await refreshHostAndHeartbeat()
        if heartbeatState != .expired && heartbeatState != .credentialRejected {
            startHeartbeatLoop()
        }
    }

    private func startHeartbeatLoop() {
        guard isAppActive, credential != nil,
              heartbeatState != .expired, heartbeatState != .credentialRejected else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.isAppActive else { return }
                await self.refreshHostAndHeartbeat()
            }
        }
    }

    private func refreshHostAndHeartbeat() async {
        guard let credential else {
            hostLiveness = .unknown
            heartbeatState = .notPaired
            return
        }
        if let expires = credential.expirationDate, expires <= Date() {
            heartbeatState = .expired
            stopHeartbeatLoop()
            return
        }

        do {
            try await api.checkHealth(baseURL: credential.baseURL)
            hostLiveness = .alive
        } catch {
            hostLiveness = .unavailable
        }

        do {
            guard let (_, apiKey) = try await credentialStore.load(), !apiKey.isEmpty else {
                heartbeatState = .credentialRejected
                stopHeartbeatLoop()
                return
            }
            try await api.sendHeartbeat(
                baseURL: credential.baseURL,
                apiKey: apiKey,
                clientID: clientIdentifier,
                deviceName: Self.deviceName
            )
            heartbeatState = .connected
        } catch MobileHostAPIError.expiredCredential {
            heartbeatState = .expired
            stopHeartbeatLoop()
        } catch MobileHostAPIError.unauthorized {
            heartbeatState = .credentialRejected
            stopHeartbeatLoop()
        } catch {
            heartbeatState = .unavailable
        }
    }

    private var clientIdentifier: String {
        let key = "iyscodemovil_mobile_host_v1_client_id"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let newValue = UUID().uuidString.lowercased()
        defaults.set(newValue, forKey: key)
        return newValue
    }

    private func stopHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        "iOS device"
        #endif
    }
}

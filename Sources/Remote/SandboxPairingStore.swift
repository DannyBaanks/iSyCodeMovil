import Foundation

/// Keeps the sandbox link between launches: the token in the Keychain, the rest in defaults.
public actor SandboxPairingStore {
    private let keychain = KeychainHelper.shared
    private let defaults: UserDefaults
    private let metadataKey = "iyscodemovil_sandbox_pairing_metadata"
    private let tokenKey = "iyscodemovil_sandbox_pairing_token"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Metadata: Codable, Sendable {
        let host: String
        let port: Int
        let directory: String
    }

    public func save(_ pairing: SandboxPairing) async throws {
        let encoded = try JSONEncoder().encode(Metadata(host: pairing.host, port: pairing.port, directory: pairing.directory))
        try await keychain.save(key: tokenKey, value: pairing.token)
        defaults.set(encoded, forKey: metadataKey)
    }

    public func load() async throws -> SandboxPairing? {
        guard let encoded = defaults.data(forKey: metadataKey) else { return nil }
        let metadata = try JSONDecoder().decode(Metadata.self, from: encoded)
        guard let token = try await keychain.load(key: tokenKey) else { return nil }
        return try SandboxPairing(host: metadata.host, port: metadata.port, token: token, directory: metadata.directory)
    }

    public func clear() async throws {
        if try await keychain.load(key: tokenKey) != nil {
            try await keychain.delete(key: tokenKey)
        }
        defaults.removeObject(forKey: metadataKey)
    }
}

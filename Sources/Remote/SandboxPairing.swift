import Foundation

/// Pairing with the sandbox orchestrator that `link --runtime sandbox` starts on the
/// computer. The agent stays on the iPhone; this only says where its tools run.
public struct SandboxPairing: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token: String
    public let directory: String

    public init(host: String, port: Int, token: String, directory: String) throws {
        // The API is plain HTTP with a bearer token: only the encrypted tailnet, or
        // loopback for development in the Simulator, is an acceptable place for it.
        guard Self.isTailscaleIPv4(host) || host == "127.0.0.1",
              (1...65535).contains(port), token.count >= 32, !directory.isEmpty else {
            throw SandboxPairingError.invalidPairing
        }
        self.host = host
        self.port = port
        self.token = token
        self.directory = directory
    }

    public static func isPairingLink(_ rawValue: String) -> Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("isysandbox://")
    }

    public static func parse(_ rawValue: String) throws -> SandboxPairing {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SandboxPairingError.invalidPairing
        }
        return try parse(url: url)
    }

    public static func parse(url: URL) throws -> SandboxPairing {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "isysandbox", components.host == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else {
            throw SandboxPairingError.invalidPairing
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                throw SandboxPairingError.invalidPairing
            }
        }
        let allowed = Set(["host", "port", "token", "directory"])
        guard Set(values.keys).isSubset(of: allowed),
              let host = values["host"], let portText = values["port"], let port = Int(portText),
              let token = values["token"], let directory = values["directory"] else {
            throw SandboxPairingError.invalidPairing
        }
        return try SandboxPairing(host: host, port: port, token: token, directory: directory)
    }

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        // Host and port were validated in init, so this URL always builds.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Last path component of the linked folder, for labels.
    public var projectName: String {
        let parts = directory.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? directory
    }

    private static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        return parts.count == 4 && octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

public enum SandboxPairingError: Error, LocalizedError, Sendable {
    case invalidPairing

    public var errorDescription: String? {
        "El enlace del sandbox no es válido. Debe venir de `link --runtime sandbox --host tailscale`."
    }
}

import Foundation

public struct GrokCapabilityProfile: Codable, Equatable, Sendable {
    public let profileVersion: Int
    public let protocolVersion: Int
    public let sessionNew: Bool
    public let sessionList: Bool
    public let sessionPrompt: Bool
    public let sessionCancel: Bool
    public let textStreaming: Bool
    public let permission: Bool
    public let sessionLoad: Bool

    public init(profileVersion: Int, protocolVersion: Int, sessionNew: Bool, sessionList: Bool, sessionPrompt: Bool, sessionCancel: Bool, textStreaming: Bool, permission: Bool, sessionLoad: Bool) {
        self.profileVersion = profileVersion
        self.protocolVersion = protocolVersion
        self.sessionNew = sessionNew
        self.sessionList = sessionList
        self.sessionPrompt = sessionPrompt
        self.sessionCancel = sessionCancel
        self.textStreaming = textStreaming
        self.permission = permission
        self.sessionLoad = sessionLoad
    }

    public var supportsCoreConversation: Bool {
        profileVersion == 1 && protocolVersion == 1 && sessionNew && sessionPrompt && textStreaming
    }
}

public struct GrokPairing: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token: String
    public let directory: String
    public let grokVersion: String
    public let profile: GrokCapabilityProfile

    public init(host: String, port: Int, token: String, directory: String, grokVersion: String, profile: GrokCapabilityProfile) throws {
        guard Self.isTailscaleIPv4(host), (1...65535).contains(port), token.count >= 32,
              !directory.isEmpty, !grokVersion.isEmpty, profile.supportsCoreConversation else {
            throw GrokPairingError.invalidPairing
        }
        self.host = host
        self.port = port
        self.token = token
        self.directory = directory
        self.grokVersion = grokVersion
        self.profile = profile
    }

    public static func parse(_ rawValue: String) throws -> GrokPairing {
        guard let url = URL(string: rawValue) else { throw GrokPairingError.invalidPairing }
        return try parse(url: url)
    }

    public static func parse(url: URL) throws -> GrokPairing {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "grok", components.host == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else {
            throw GrokPairingError.invalidPairing
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                throw GrokPairingError.invalidPairing
            }
        }
        let allowed = Set(["host", "port", "directory", "token", "grokVersion", "profile"])
        guard Set(values.keys).isSubset(of: allowed) else { throw GrokPairingError.invalidPairing }
        guard let host = values["host"], let portText = values["port"], let port = Int(portText),
              let token = values["token"], let directory = values["directory"],
              let grokVersion = values["grokVersion"], let profileJSON = values["profile"],
              let profileData = profileJSON.data(using: .utf8),
              let profile = try? JSONDecoder().decode(GrokCapabilityProfile.self, from: profileData) else {
            throw GrokPairingError.invalidPairing
        }
        return try GrokPairing(host: host, port: port, token: token, directory: directory, grokVersion: grokVersion, profile: profile)
    }

    public var rawValue: String {
        var components = URLComponents()
        components.scheme = "grok"
        components.host = "pair"
        let profileData = (try? JSONEncoder().encode(profile)) ?? Data()
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "grokVersion", value: grokVersion),
            URLQueryItem(name: "profile", value: String(data: profileData, encoding: .utf8) ?? "")
        ]
        return components.url?.absoluteString ?? ""
    }

    private static func isTailscaleIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

public enum GrokPairingError: Error, LocalizedError, Sendable {
    case invalidPairing

    public var errorDescription: String? {
        "Invalid Grok pairing link or unsupported ACP profile."
    }
}

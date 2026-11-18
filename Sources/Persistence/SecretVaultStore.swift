import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Metadata non-sensitive stored in `Documents/.isycode/secret_vault_index.json`.
/// Actual secrets live ONLY in Apple Keychain (`KeychainHelper`), never in JSON files, prompts, or `.isyagent.json`.
public struct SecretVaultEntryMetadata: Codable, Sendable, Identifiable, Equatable {
    public var id: String { alias }
    public let alias: String
    public var label: String
    public var serviceDomain: String
    public var hasUsername: Bool
    public var hasPassword: Bool
    public var hasToken: Bool
    public var requireFaceID: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        alias: String,
        label: String,
        serviceDomain: String = "",
        hasUsername: Bool = false,
        hasPassword: Bool = false,
        hasToken: Bool = false,
        requireFaceID: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.alias = Self.normalizeAlias(alias)
        self.label = label
        self.serviceDomain = serviceDomain
        self.hasUsername = hasUsername
        self.hasPassword = hasPassword
        self.hasToken = hasToken
        self.requireFaceID = requireFaceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalizeAlias(_ raw: String) -> String {
        let lower = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "credencial" : String(collapsed.prefix(40))
    }

    public var availableFields: [String] {
        var fields: [String] = []
        if hasUsername { fields.append("username") }
        if hasPassword { fields.append("password") }
        if hasToken { fields.append("token") }
        return fields
    }
}

public enum SecretVaultField: String, Codable, Sendable {
    case username
    case password
    case token
}

public struct SecretReferenceToken: Sendable, Equatable {
    public let rawToken: String
    public let alias: String
    public let field: SecretVaultField

    public init(rawToken: String, alias: String, field: SecretVaultField) {
        self.rawToken = rawToken
        self.alias = alias
        self.field = field
    }
}

public enum SecretVaultError: Error, LocalizedError, Sendable {
    case missingAlias(String)
    case missingField(alias: String, field: SecretVaultField)
    case biometricFailed(String)
    case keychainFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingAlias(let alias):
            return "El secreto '{{secret:\(alias)}}' no existe en el Llavero de este iPhone. Guárdalo en Conexiones → Llavero antes de ejecutar este paso."
        case .missingField(let alias, let field):
            return "La credencial '\(alias)' no tiene guardado el campo '\(field.rawValue)' en el Llavero."
        case .biometricFailed(let reason):
            return "Se canceló o falló la verificación biométrica del Llavero: \(reason)"
        case .keychainFailure(let detail):
            return "No se pudo leer o guardar en el Keychain: \(detail)"
        }
    }
}

/// Manages Keychain-backed credential entries whose opaque references (`{{secret:alias.password}}`)
/// can be bound into L1 workflows and UI typing without ever exposing secrets to LLM prompts or transcripts.
@MainActor
public final class SecretVaultStore: ObservableObject {
    public static let shared = SecretVaultStore()

    @Published public private(set) var entries: [SecretVaultEntryMetadata] = []
    @Published public var lastError: String?
    @Published public var requestedAliasDraft: (alias: String, label: String, domain: String)?

    private let indexURL: URL

    public init(directoryURL: URL? = nil) {
        let base: URL
        if let directoryURL {
            base = directoryURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = docs.appendingPathComponent(".isycode")
        }
        self.indexURL = base.appendingPathComponent("secret_vault_index.json")
        loadIndex()
    }

    public func loadIndex() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? decoder.decode([SecretVaultEntryMetadata].self, from: data) {
            self.entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func hasAlias(_ alias: String) -> Bool {
        let normalized = SecretVaultEntryMetadata.normalizeAlias(alias)
        return entries.contains { $0.alias == normalized }
    }

    public func missingAliases(from required: [String]) -> [String] {
        let existing = Set(entries.map(\.alias))
        return required
            .map(SecretVaultEntryMetadata.normalizeAlias)
            .filter { !existing.contains($0) }
    }

    public func upsertSecret(
        alias rawAlias: String,
        label: String,
        serviceDomain: String,
        username: String,
        password: String,
        token: String = "",
        requireFaceID: Bool
    ) async throws {
        let alias = SecretVaultEntryMetadata.normalizeAlias(rawAlias)
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDomain = serviceDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = entries.first { $0.alias == alias }

        if !username.isEmpty {
            try await KeychainHelper.shared.save(key: Self.keychainKey(alias: alias, field: .username), value: username)
        }
        if !password.isEmpty {
            try await KeychainHelper.shared.save(key: Self.keychainKey(alias: alias, field: .password), value: password)
        }
        if !token.isEmpty {
            try await KeychainHelper.shared.save(key: Self.keychainKey(alias: alias, field: .token), value: token)
        }

        let meta = SecretVaultEntryMetadata(
            alias: alias,
            label: cleanLabel.isEmpty ? alias : cleanLabel,
            serviceDomain: cleanDomain,
            hasUsername: !username.isEmpty || (existing?.hasUsername ?? false),
            hasPassword: !password.isEmpty || (existing?.hasPassword ?? false),
            hasToken: !token.isEmpty || (existing?.hasToken ?? false),
            requireFaceID: requireFaceID,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        if let idx = entries.firstIndex(where: { $0.alias == alias }) {
            entries[idx] = meta
        } else {
            entries.insert(meta, at: 0)
        }
        persistIndex()
    }

    public func deleteSecret(alias rawAlias: String) async {
        let alias = SecretVaultEntryMetadata.normalizeAlias(rawAlias)
        for field in [SecretVaultField.username, .password, .token] {
            try? await KeychainHelper.shared.delete(key: Self.keychainKey(alias: alias, field: field))
        }
        entries.removeAll { $0.alias == alias }
        persistIndex()
    }

    public func safeCatalogLines() -> String {
        guard !entries.isEmpty else {
            return "El Llavero está vacío. Usa `secret_vault_request_entry` o abre Llavero para guardar un usuario/contraseña de forma segura."
        }
        return entries.map { entry in
            let fields = entry.availableFields.map { "{{secret:\(entry.alias).\($0)}}" }.joined(separator: ", ")
            let domainNote = entry.serviceDomain.isEmpty ? "" : " (\(entry.serviceDomain))"
            let faceIDNote = entry.requireFaceID ? "Face ID" : "sin Face ID"
            return "- \(entry.label)\(domainNote) [alias: \(entry.alias), \(faceIDNote)] → referencias: \(fields)"
        }.joined(separator: "\n")
    }

    public func requestNewEntryFromAgent(alias: String, label: String, domain: String) {
        requestedAliasDraft = (
            alias: SecretVaultEntryMetadata.normalizeAlias(alias),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func persistIndex() {
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public nonisolated static func keychainKey(alias: String, field: SecretVaultField) -> String {
        "secret_vault.v1.\(SecretVaultEntryMetadata.normalizeAlias(alias)).\(field.rawValue)"
    }

    // MARK: - Token Parsing & Redaction

    /// Matches `{{secret:alias}}`, `{{secret:alias.username}}`, `{{secret:alias.password}}`, `{{secret:alias.token}}`.
    public nonisolated static func parseTokens(in text: String) -> [SecretReferenceToken] {
        guard text.contains("{{secret:") else { return [] }
        let pattern = #"\{\{secret:([a-zA-Z0-9_\-\.]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var result: [SecretReferenceToken] = []
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let innerRange = Range(match.range(at: 1), in: text) else { continue }
            let rawToken = String(text[fullRange])
            let inner = String(text[innerRange])
            let parts = inner.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            guard let aliasPart = parts.first else { continue }
            let alias = SecretVaultEntryMetadata.normalizeAlias(String(aliasPart))
            let field: SecretVaultField
            if parts.count == 2, let parsedField = SecretVaultField(rawValue: String(parts[1]).lowercased()) {
                field = parsedField
            } else {
                field = .password
            }
            result.append(SecretReferenceToken(rawToken: rawToken, alias: alias, field: field))
        }
        return result
    }

    public nonisolated static func extractAliases(in text: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for tok in parseTokens(in: text) where seen.insert(tok.alias).inserted {
            ordered.append(tok.alias)
        }
        return ordered
    }

    public nonisolated static func containsSecretReference(in arguments: [String: String]) -> Bool {
        arguments.values.contains { !parseTokens(in: $0).isEmpty }
    }

    public nonisolated static func redact(_ text: String, secrets: [String]) -> String {
        var output = text
        for secret in secrets where !secret.isEmpty {
            output = output.replacingOccurrences(of: secret, with: "••••••••")
        }
        return output
    }
}

/// Resolves opaque `{{secret:...}}` references just-in-time in memory right before UI injection,
/// enforcing biometric authentication if configured and returning values for immediate redaction.
public actor SecretVaultRuntimeResolver {
    public typealias SecretReader = @Sendable (_ alias: String, _ field: SecretVaultField) async throws -> String?
    public typealias MetadataLookup = @Sendable (_ alias: String) async -> SecretVaultEntryMetadata?
    public typealias BiometricAuthenticator = @Sendable (_ reason: String) async throws -> Bool

    public static let shared = SecretVaultRuntimeResolver()

    private let reader: SecretReader
    private let metadataLookup: MetadataLookup
    private let authenticator: BiometricAuthenticator

    public init(
        reader: SecretReader? = nil,
        metadataLookup: MetadataLookup? = nil,
        authenticator: BiometricAuthenticator? = nil
    ) {
        self.reader = reader ?? { alias, field in
            try await KeychainHelper.shared.load(key: SecretVaultStore.keychainKey(alias: alias, field: field))
        }
        self.metadataLookup = metadataLookup ?? { alias in
            let normalized = SecretVaultEntryMetadata.normalizeAlias(alias)
            return await MainActor.run {
                SecretVaultStore.shared.entries.first { $0.alias == normalized }
            }
        }
        self.authenticator = authenticator ?? { reason in
            try await Self.defaultBiometricAuthenticate(reason: reason)
        }
    }

    public struct ResolutionResult: Sendable {
        public let arguments: [String: String]
        public let resolvedSecrets: [String]
        public let usedAliases: [String]
    }

    public func resolvePlaceholders(in arguments: [String: String]) async throws -> ResolutionResult {
        var allTokens: [SecretReferenceToken] = []
        for value in arguments.values {
            allTokens.append(contentsOf: SecretVaultStore.parseTokens(in: value))
        }
        guard !allTokens.isEmpty else {
            return ResolutionResult(arguments: arguments, resolvedSecrets: [], usedAliases: [])
        }

        var uniqueAliases: [String] = []
        var seenAliases: Set<String> = []
        for token in allTokens where seenAliases.insert(token.alias).inserted {
            uniqueAliases.append(token.alias)
        }

        var requiresBiometry = false
        var promptLabels: [String] = []
        for alias in uniqueAliases {
            if let meta = await metadataLookup(alias) {
                if meta.requireFaceID {
                    requiresBiometry = true
                }
                promptLabels.append(meta.label)
            } else {
                requiresBiometry = true
                promptLabels.append(alias)
            }
        }

        if requiresBiometry {
            let reason = "Autoriza usar la credencial del Llavero (\(promptLabels.joined(separator: ", "))) para completar este paso."
            let ok = try await authenticator(reason)
            guard ok else {
                throw SecretVaultError.biometricFailed("Autenticación rechazada.")
            }
        }

        var resolvedCache: [String: String] = [:]
        var secretValues: [String] = []
        for token in allTokens {
            if resolvedCache[token.rawToken] != nil { continue }
            let val: String?
            do {
                val = try await reader(token.alias, token.field)
            } catch {
                throw SecretVaultError.keychainFailure(error.localizedDescription)
            }
            guard let unwrapped = val, !unwrapped.isEmpty else {
                if await metadataLookup(token.alias) == nil {
                    throw SecretVaultError.missingAlias(token.alias)
                }
                throw SecretVaultError.missingField(alias: token.alias, field: token.field)
            }
            resolvedCache[token.rawToken] = unwrapped
            secretValues.append(unwrapped)
        }

        var resolvedArgs: [String: String] = [:]
        for (key, value) in arguments {
            var next = value
            for (token, secret) in resolvedCache {
                next = next.replacingOccurrences(of: token, with: secret)
            }
            resolvedArgs[key] = next
        }

        return ResolutionResult(
            arguments: resolvedArgs,
            resolvedSecrets: secretValues,
            usedAliases: uniqueAliases
        )
    }

    private static func defaultBiometricAuthenticate(reason: String) async throws -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
        return true
        #else
        return true
        #endif
    }
}

import Foundation

/// The iPhone's apps by name → Bundle ID, remembered on the iPhone so agents stop guessing
/// IDs ("com.openai.chatgpt" does not exist; "Muse" is com.facebook.hatch).
///
/// It learns by itself: every `iphone_list_apps` result (computer mode) is merged in, and
/// `iphone_app_remember` adds one pair the agent has verified (e.g. with `iphone_status`
/// after opening the app). "This iPhone" mode cannot list apps (WebDriverAgent has no such
/// call), so it relies on what was learned here. `iphone_launch_app` and
/// `iphone_terminate_app` resolve a name through it before the built-in aliases.
public enum IphoneAppDirectory {
    public static let defaultsKey = "iphone.appDirectory.v1"

    public struct App: Codable, Equatable, Sendable {
        public let name: String
        public let bundleID: String

        public init(name: String, bundleID: String) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> [App] {
        guard let data = defaults.data(forKey: defaultsKey),
              let apps = try? JSONDecoder().decode([App].self, from: data) else { return [] }
        return apps
    }

    static func save(_ apps: [App], defaults: UserDefaults) {
        let sorted = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Merges the lines of an `iphone_list_apps` result ("Name<TAB>com.bundle.id", one per
    /// line). Returns how many apps were read. Lines without a Bundle ID are ignored.
    @discardableResult
    public static func learn(fromListing text: String, defaults: UserDefaults = .standard) -> Int {
        let found = text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
        guard !found.isEmpty else { return 0 }
        var byBundle = Dictionary(load(defaults: defaults).map { ($0.bundleID, $0) }, uniquingKeysWith: { _, new in new })
        for app in found { byBundle[app.bundleID] = app }
        save(Array(byBundle.values), defaults: defaults)
        return found.count
    }

    /// Adds or renames one app. Returns false when `bundleID` does not look like a Bundle ID.
    @discardableResult
    public static func remember(name: String, bundleID: String, defaults: UserDefaults = .standard) -> Bool {
        let cleanName = stripInvisible(name).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, isBundleID(cleanID) else { return false }
        var apps = load(defaults: defaults).filter { $0.bundleID != cleanID && normalize($0.name) != normalize(cleanName) }
        apps.append(App(name: cleanName, bundleID: cleanID))
        save(apps, defaults: defaults)
        return true
    }

    /// Bundle ID for a name the person or the model used: exact name first (ignoring case,
    /// accents and invisible marks), then a single app whose name starts with it, then a
    /// single app whose name contains it. Nil when unknown or ambiguous.
    public static func resolve(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        let wanted = normalize(raw)
        guard !wanted.isEmpty else { return nil }
        let apps = load(defaults: defaults)
        if let exact = apps.first(where: { normalize($0.name) == wanted }) { return exact.bundleID }
        let prefixed = apps.filter { normalize($0.name).hasPrefix(wanted) }
        if prefixed.count == 1 { return prefixed[0].bundleID }
        let containing = apps.filter { normalize($0.name).contains(wanted) }
        if containing.count == 1 { return containing[0].bundleID }
        return nil
    }

    /// Text for the agent: one "Name → bundle" per line, optionally filtered.
    public static func describe(filter: String? = nil, defaults: UserDefaults = .standard) -> String {
        let wanted = filter.map(normalize) ?? ""
        let apps = load(defaults: defaults).filter {
            wanted.isEmpty || normalize($0.name).contains(wanted) || $0.bundleID.lowercased().contains(wanted)
        }
        guard !apps.isEmpty else {
            return wanted.isEmpty
                ? "El directorio de apps está vacío. En modo computadora, iphone_list_apps lo llena solo; en este iPhone, abre la app, lee su Bundle ID con iphone_status (App al frente) y guárdalo con iphone_app_remember."
                : "Ninguna app guardada coincide con «\(filter ?? "")»."
        }
        return (["\(apps.count) apps guardadas (usa el Bundle ID exacto con iphone_launch_app):"]
            + apps.map { "\($0.name) → \($0.bundleID)" }).joined(separator: "\n")
    }

    // MARK: - Parsing and normalisation

    static func parseLine(_ line: String) -> App? {
        let cleaned = stripInvisible(line).trimmingCharacters(in: .whitespaces)
        let fields = cleaned.split(separator: "\t", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if fields.count >= 2, isBundleID(fields[1]), !fields[0].isEmpty {
            return App(name: fields[0], bundleID: fields[1])
        }
        // Fallback: "Name  com.bundle.id" with spaces.
        guard let last = cleaned.split(separator: " ").last.map(String.init), isBundleID(last) else { return nil }
        let name = cleaned.dropLast(last.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : App(name: name, bundleID: last)
    }

    static func isBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Case-, accent- and space-insensitive key, without invisible direction marks (the
    /// listing shows WhatsApp as "\u{200E}WhatsApp").
    static func normalize(_ value: String) -> String {
        stripInvisible(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func stripInvisible(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .format || scalar == "\u{FEFF}")
        }))
    }
}

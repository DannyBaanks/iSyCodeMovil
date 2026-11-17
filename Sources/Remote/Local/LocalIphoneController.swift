import Foundation

/// The narrow part of WebDriverAgent used by the local iPhone tools.
public protocol WdaDriving: Sendable {
    func status() async throws -> LocalWdaStatus
    func screenshotPNG() async throws -> Data
    func pageSource() async throws -> String
    func tap(x: Double, y: Double) async throws
    func longPress(x: Double, y: Double, seconds: Double) async throws
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double) async throws
    func typeText(_ text: String, submit: Bool) async throws
    func pressButton(_ button: String) async throws
    func launchApp(bundleID: String) async throws
    func terminateApp(bundleID: String) async throws
}

/// Screen parsing and element selection are injected so the controller is independent
/// of the concrete WDA client and XML parser.
public protocol WdaElementReading: Sendable {
    func parse(xml: String) -> [LocalElement]
    func format(_ elements: [LocalElement], limit: Int) -> String
    func resolveTap(text: String, index: Int, in elements: [LocalElement]) throws -> (x: Double, y: Double)
}

public actor LocalIphoneController {
    public static let supportedToolNames: Set<String> = [
        "iphone_status", "iphone_screenshot", "iphone_list_elements", "iphone_list_devices",
        "iphone_wait_for", "iphone_tap", "iphone_tap_element", "iphone_long_press",
        "iphone_swipe", "iphone_type_text", "iphone_press_button", "iphone_launch_app",
        "iphone_terminate_app"
    ]

    private let wda: WdaDriving
    private let elementReader: WdaElementReading

    public init(wda: WdaDriving, elementReader: WdaElementReading) {
        self.wda = wda
        self.elementReader = elementReader
    }

    public func call(tool: String, arguments: [String: Any]) async throws -> String {
        switch tool {
        case "iphone_status":
            let status = try await wda.status()
            let foreground = status.foregroundBundleID ?? "desconocida"
            return [
                "WebDriverAgent: \(status.ready ? "listo" : "no disponible")",
                "Bloqueado: \(status.locked ? "sí" : "no")",
                "App al frente: \(foreground)",
                "Pantalla: \(status.widthPoints) × \(status.heightPoints) puntos"
            ].joined(separator: "\n")

        case "iphone_screenshot":
            let image = try await wda.screenshotPNG()
            return "Captura tomada (\(image.count / 1024) KB). La imagen no se transmite al modelo; usa iphone_list_elements para leer la pantalla."

        case "iphone_list_elements":
            return try await listElements(arguments: arguments)

        case "iphone_list_devices":
            return "Este iPhone (WebDriverAgent en 127.0.0.1:8100)."

        case "iphone_list_apps":
            throw LocalIphoneError.unsupported("iphone_list_apps no está disponible en modo local: WebDriverAgent no permite enumerar las apps instaladas.")

        case "iphone_open_url":
            throw LocalIphoneError.unsupported("iphone_open_url no está disponible en modo local: WebDriverAgent no ofrece una operación para abrir URLs en este controlador.")

        case "iphone_wait_for":
            return try await waitFor(arguments: arguments)

        case "iphone_tap":
            let x = try number("x", in: arguments)
            let y = try number("y", in: arguments)
            let then = try thenMode(in: arguments)
            try await wda.tap(x: x, y: y)
            return try await finishAction(then: then)

        case "iphone_tap_element":
            let text = try string("text", in: arguments)
            let index = try integer("index", in: arguments, default: 0)
            guard index >= 0 else { throw LocalIphoneError.invalid("index debe ser cero o mayor.") }
            let then = try thenMode(in: arguments)
            let elements = try await readElements()
            let point = try elementReader.resolveTap(text: text, index: index, in: elements)
            try await wda.tap(x: point.x, y: point.y)
            return try await finishAction(then: then)

        case "iphone_long_press":
            let x = try number("x", in: arguments)
            let y = try number("y", in: arguments)
            let seconds = try number("seconds", in: arguments, default: 1)
            guard seconds > 0 else { throw LocalIphoneError.invalid("seconds debe ser mayor que cero.") }
            let then = try thenMode(in: arguments)
            try await wda.longPress(x: x, y: y, seconds: seconds)
            return try await finishAction(then: then)

        case "iphone_swipe":
            let fromX = try number("from_x", in: arguments)
            let fromY = try number("from_y", in: arguments)
            let toX = try number("to_x", in: arguments)
            let toY = try number("to_y", in: arguments)
            let seconds = try number("seconds", in: arguments, default: 0.3)
            guard seconds > 0 else { throw LocalIphoneError.invalid("seconds debe ser mayor que cero.") }
            let then = try thenMode(in: arguments)
            try await wda.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, seconds: seconds)
            return try await finishAction(then: then)

        case "iphone_type_text":
            let text = try string("text", in: arguments)
            let submit = try boolean("submit", in: arguments, default: false)
            let then = try thenMode(in: arguments)
            try await wda.typeText(text, submit: submit)
            return try await finishAction(then: then)

        case "iphone_press_button":
            let button = try string("button", in: arguments)
            guard ["home", "volume_up", "volume_down", "lock"].contains(button) else {
                throw LocalIphoneError.invalid("button debe ser home, volume_up, volume_down o lock.")
            }
            let then = try thenMode(in: arguments)
            try await wda.pressButton(button)
            return try await finishAction(then: then)

        case "iphone_launch_app":
            let bundleID = Self.resolveBundleID(try string("app", in: arguments))
            let then = try thenMode(in: arguments)
            try await wda.launchApp(bundleID: bundleID)
            return try await finishAction(then: then)

        case "iphone_terminate_app":
            let bundleID = Self.resolveBundleID(try string("app", in: arguments))
            let then = try thenMode(in: arguments)
            try await wda.terminateApp(bundleID: bundleID)
            return try await finishAction(then: then)

        default:
            throw LocalIphoneError.unsupported("La herramienta \(tool) no está disponible en el controlador local.")
        }
    }

    private func readElements() async throws -> [LocalElement] {
        elementReader.parse(xml: try await wda.pageSource())
    }

    private func listElements(arguments: [String: Any]) async throws -> String {
        let elements = try await readElements()
        let filter = (arguments["filter"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching: [LocalElement]
        if filter.isEmpty {
            matching = elements
        } else {
            let needle = filter.lowercased()
            matching = elements.filter {
                $0.searchableText.lowercased().contains(needle)
            }
        }
        let limit = try integer("limit", in: arguments, default: 150)
        guard limit >= 0 else { throw LocalIphoneError.invalid("limit debe ser cero o mayor.") }
        if matching.isEmpty, !filter.isEmpty, !elements.isEmpty {
            return "No element containing \"\(filter)\" (\(elements.count) other elements with text on screen; leave out filter to list them all)"
        }
        return elementReader.format(matching, limit: limit)
    }

    private func waitFor(arguments: [String: Any]) async throws -> String {
        let text = try string("text", in: arguments)
        let timeout = try number("timeout", in: arguments, default: 5)
        guard timeout >= 0 else { throw LocalIphoneError.invalid("timeout debe ser cero o mayor.") }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let elements = try await readElements()
            if elements.contains(where: { $0.waitSearchTexts.contains(text) })
                || elements.contains(where: { element in
                    element.waitSearchTexts.contains { $0.lowercased().contains(text.lowercased()) }
                }) {
                return "Encontrado: \(text)"
            }
            guard Date() < deadline else {
                throw LocalIphoneError.timedOut("No apareció «\(text)» en \(timeout) segundos.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static let bundleAliases: [String: String] = [
        "safari": "com.apple.mobilesafari",
        "ajustes": "com.apple.Preferences",
        "settings": "com.apple.Preferences",
        "configuracion": "com.apple.Preferences",
        "mensajes": "com.apple.MobileSMS",
        "messages": "com.apple.MobileSMS",
        "telefono": "com.apple.mobilephone",
        "phone": "com.apple.mobilephone",
        "camara": "com.apple.camera",
        "camera": "com.apple.camera",
        "fotos": "com.apple.mobileslideshow",
        "photos": "com.apple.mobileslideshow",
        "notas": "com.apple.mobilenotes",
        "notes": "com.apple.mobilenotes",
        "reloj": "com.apple.mobiletimer",
        "clock": "com.apple.mobiletimer",
        "calculadora": "com.apple.calculator",
        "calculator": "com.apple.calculator",
        "calendario": "com.apple.mobilecal",
        "calendar": "com.apple.mobilecal",
        "mapas": "com.apple.Maps",
        "maps": "com.apple.Maps",
        "app store": "com.apple.AppStore",
        "appstore": "com.apple.AppStore",
        "archivos": "com.apple.DocumentsApp",
        "files": "com.apple.DocumentsApp",
        "correo": "com.apple.mobilemail",
        "mail": "com.apple.mobilemail",
        "musica": "com.apple.Music",
        "music": "com.apple.Music",
        "atajos": "com.apple.shortcuts",
        "shortcuts": "com.apple.shortcuts",
        "recordatorios": "com.apple.reminders",
        "reminders": "com.apple.reminders",
        "whatsapp": "net.whatsapp.WhatsApp",
        "youtube": "com.google.ios.youtube",
        "spotify": "com.spotify.client",
        "chrome": "com.google.chrome.ios",
        "instagram": "com.burbn.instagram",
        "telegram": "ph.telegra.Telegraph",
        "twitter": "com.atebits.Tweetie2",
        "x": "com.atebits.Tweetie2",
        "tailscale": "io.tailscale.ipn.ios",
        "localdevvpn": "com.stoss.LocalDevVPN"
    ]

    private static func resolveBundleID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".") {
            return trimmed
        }
        let normalized = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if normalized.contains("isycode") || normalized.contains("iyscode") {
            return Bundle.main.bundleIdentifier ?? "com.isyco.iyscodemovil"
        }
        return bundleAliases[normalized] ?? trimmed
    }

    private func finishAction(then: String) async throws -> String {
        guard then == "elements" else { return "Listo." }
        try await Task.sleep(nanoseconds: 600_000_000)
        return try await listElements(arguments: [:])
    }

    private func thenMode(in arguments: [String: Any]) throws -> String {
        let then = arguments["then"] as? String ?? "none"
        guard then == "none" || then == "elements" else {
            throw LocalIphoneError.invalid("then debe ser elements o none.")
        }
        return then
    }

    private func string(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw LocalIphoneError.invalid("Falta el argumento \(key).")
        }
        return value
    }

    private func number(_ key: String, in arguments: [String: Any], default defaultValue: Double? = nil) throws -> Double {
        guard let raw = arguments[key] else {
            if let defaultValue { return defaultValue }
            throw LocalIphoneError.invalid("Falta el argumento \(key).")
        }
        let value: Double?
        if let number = raw as? Double {
            value = number
        } else if let number = raw as? Int {
            value = Double(number)
        } else if let number = raw as? NSNumber {
            value = number.doubleValue
        } else {
            value = nil
        }
        guard let value, value.isFinite else { throw LocalIphoneError.invalid("\(key) debe ser un número finito.") }
        return value
    }

    private func integer(_ key: String, in arguments: [String: Any], default defaultValue: Int? = nil) throws -> Int {
        guard let raw = arguments[key] else {
            if let defaultValue { return defaultValue }
            throw LocalIphoneError.invalid("Falta el argumento \(key).")
        }
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue {
            return number.intValue
        }
        throw LocalIphoneError.invalid("\(key) debe ser un entero.")
    }

    private func boolean(_ key: String, in arguments: [String: Any], default defaultValue: Bool) throws -> Bool {
        guard let value = arguments[key] else { return defaultValue }
        guard let value = value as? Bool else { throw LocalIphoneError.invalid("\(key) debe ser true o false.") }
        return value
    }
}

public enum IphoneControlMode: String, Sendable {
    case computer
    case thisPhone

    public static func resolve(preferred: IphoneControlMode?, bridgeTools: [String], localReachable: Bool) -> IphoneControlMode? {
        let hasBridge = bridgeTools.contains { IphoneControlCatalog.names.contains($0) }
        let hasLocal = localReachable

        if let preferred {
            switch preferred {
            case .computer where hasBridge: return .computer
            case .thisPhone where hasLocal: return .thisPhone
            default: break
            }
        }

        guard hasBridge || hasLocal else { return nil }
        if preferred == nil, hasLocal, !hasBridge { return .thisPhone }
        if hasBridge { return .computer }
        return .thisPhone
    }
}

private enum LocalIphoneError: Error, LocalizedError {
    case invalid(String)
    case unsupported(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .unsupported(message), let .timedOut(message): return message
        }
    }
}

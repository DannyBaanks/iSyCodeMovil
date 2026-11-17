import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errores del cliente de WebDriverAgent (WDA). Los mensajes son para el usuario de la app (español).
public enum WdaError: Error, LocalizedError, Sendable {
    /// No se pudo conectar con WDA (no está corriendo o el puerto no responde).
    case unavailable(String)
    /// La petición se envió pero no hubo respuesta a tiempo; el teléfono puede seguir ejecutándola.
    case timeout(String)
    /// WDA respondió con un error W3C (`value.error`) o con un código HTTP >= 400.
    case remote(kind: String, message: String)
    /// La respuesta de WDA no se entiende (no es JSON, falta un campo esperado, ...).
    case invalidResponse(String)
    /// El botón pedido no es uno de los que WDA entiende.
    case invalidButton(String)
    /// WDA está atascado: `WdaClient.stallLimit` peticiones seguidas llegaron sin respuesta.
    case stalled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "WDA no está disponible: \(detail)"
        case .timeout(let detail):
            return "WDA no respondió a tiempo (\(detail)). La petición se envió: el teléfono puede haberla ejecutado igualmente."
        case .remote(let kind, let message):
            return "WDA devolvió un error (\(kind)): \(message)"
        case .invalidResponse(let detail):
            return "La respuesta de WDA no se entiende: \(detail)"
        case .invalidButton(let name):
            return "Botón desconocido: \(name). Usa home, volume_up, volume_down o lock."
        case .stalled:
            return "WDA está atascado: \(WdaClient.stallLimit) peticiones seguidas sin respuesta. Hay que reiniciarlo."
        }
    }
}

/// Un paso de un gesto W3C pointer (el `PointerStep` del daemon Rust).
public enum PointerStep: Equatable, Sendable {
    case move(x: Double, y: Double, ms: Int)
    case down
    case up
    case pause(ms: Int)
}

/// Lo que devuelve `GET /status` junto con el bloqueo, la app en primer plano y la pantalla en puntos.
public struct WdaStatus: Equatable, Sendable {
    public let ready: Bool
    public let locked: Bool
    public let foregroundBundleID: String
    /// Ancho de la pantalla en puntos.
    public let width: Double
    /// Alto de la pantalla en puntos.
    public let height: Double

    public init(ready: Bool, locked: Bool, foregroundBundleID: String, width: Double, height: Double) {
        self.ready = ready
        self.locked = locked
        self.foregroundBundleID = foregroundBundleID
        self.width = width
        self.height = height
    }
}

/// Cliente HTTP de WebDriverAgent corriendo en el propio iPhone (`http://127.0.0.1:8100`).
///
/// Porta la semántica del daemon Rust (`ictl-wda`): la sesión se crea con `POST /session` y, si WDA
/// la invalidó (p. ej. tras reiniciarse), se vuelve a crear **una sola vez** antes de fallar.
/// Los toques y deslizamientos son gestos W3C pointer enviados a `POST /session/{id}/actions`.
public actor WdaClient {
    /// Pulsación de un tap normal, en milisegundos. Más corto puede no reconocerse como tap.
    public static let tapPressMs: Int = 50

    /// Peticiones seguidas sin respuesta (que no sean `/status`) antes de declarar que WDA está atascado.
    public static let stallLimit: Int = 3

    /// `/status` responde aunque WDA esté medio caído: se le da menos tiempo que al resto.
    private static let statusTimeout: TimeInterval = 5
    /// Escribir texto puede tardar (teclado, autocompletado): 120 s como en el daemon.
    private static let keysTimeout: TimeInterval = 120
    /// Lanzar una app en frío puede tardar: 60 s como en el daemon.
    private static let launchTimeout: TimeInterval = 60

    public let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private var sessionID: String?
    /// Peticiones seguidas que llegaron a WDA pero no tuvieron respuesta (timeout).
    private var unanswered: Int = 0

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8100")!, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Gestos W3C pointer

    /// Un toque: mover, bajar, esperar `pressMs` y subir.
    public static func tapSteps(x: Double, y: Double, pressMs: Int = tapPressMs) -> [PointerStep] {
        [.move(x: x, y: y, ms: 0), .down, .pause(ms: pressMs), .up]
    }

    /// Un deslizamiento: bajar en el origen, esperar 50 ms, moverse al destino en `ms` y subir.
    public static func swipeSteps(fromX: Double, fromY: Double, toX: Double, toY: Double, ms: Int) -> [PointerStep] {
        [.move(x: fromX, y: fromY, ms: 0), .down, .pause(ms: 50), .move(x: toX, y: toY, ms: ms), .up]
    }

    /// Cuerpo de `POST /session/{id}/actions` para un gesto de un dedo táctil.
    public static func actionsBody(_ steps: [PointerStep]) -> [String: Any] {
        let actions: [[String: Any]] = steps.map { step in
            switch step {
            case .move(let x, let y, let ms):
                return ["type": "pointerMove", "duration": ms, "x": x, "y": y]
            case .down:
                return ["type": "pointerDown", "button": 0]
            case .up:
                return ["type": "pointerUp", "button": 0]
            case .pause(let ms):
                return ["type": "pause", "duration": ms]
            }
        }
        return ["actions": [["type": "pointer", "id": "finger1", "parameters": ["pointerType": "touch"], "actions": actions]]]
    }

    // MARK: - Estado

    /// `GET /status` más bloqueo (`/wda/locked`), app en primer plano (`/wda/activeAppInfo`)
    /// y tamaño de pantalla en puntos (`/wda/screen`). Ninguna usa sesión.
    public func status() async throws -> WdaStatus {
        let status = try await call("GET", "/status", timeout: Self.statusTimeout)
        let statusValue = status["value"] as? [String: Any] ?? [:]
        let ready = (statusValue["ready"] as? NSNumber)?.boolValue ?? false
        let locked = ((try await get("/wda/locked")) as? NSNumber)?.boolValue ?? false
        let active = (try await get("/wda/activeAppInfo")) as? [String: Any] ?? [:]
        let bundleID = active["bundleId"] as? String ?? ""
        let screen = (try await get("/wda/screen")) as? [String: Any] ?? [:]
        let size = screen["screenSize"] as? [String: Any] ?? [:]
        func positive(_ key: String) -> Double? {
            guard let n = (size[key] as? NSNumber)?.doubleValue, n.isFinite, n > 0 else { return nil }
            return n
        }
        guard let width = positive("width"), let height = positive("height") else {
            throw WdaError.invalidResponse("Dimensiones de pantalla inválidas en /wda/screen")
        }
        return WdaStatus(ready: ready, locked: locked, foregroundBundleID: bundleID, width: width, height: height)
    }

    /// Captura de pantalla (`GET /screenshot`), decodificada del base64 que devuelve WDA.
    public func screenshotPNG() async throws -> Data {
        guard let base64 = try await get("/screenshot") as? String else {
            throw WdaError.invalidResponse("La captura no llegó como cadena base64")
        }
        let cleaned = base64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: cleaned) else {
            throw WdaError.invalidResponse("La captura no es base64 válido")
        }
        return data
    }

    /// Árbol de elementos en XML (`GET /source?format=xml`).
    public func pageSource() async throws -> String {
        guard let xml = try await get("/source?format=xml") as? String else {
            throw WdaError.invalidResponse("El árbol de elementos no llegó como cadena XML")
        }
        return xml
    }

    // MARK: - Gestos y entrada

    /// Toca (x, y): un gesto W3C con pulsación de `tapPressMs` (50 ms).
    public func tap(x: Double, y: Double) async throws {
        _ = try await post("/actions", Self.actionsBody(Self.tapSteps(x: x, y: y)))
    }

    /// Mantiene pulsado (x, y) durante `seconds`.
    public func longPress(x: Double, y: Double, seconds: Double) async throws {
        _ = try await post("/actions", Self.actionsBody(Self.tapSteps(x: x, y: y, pressMs: Int(seconds * 1000))))
    }

    /// Desliza desde (fromX, fromY) hasta (toX, toY) en `seconds`.
    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double) async throws {
        let ms = Int(seconds * 1000)
        _ = try await post("/actions", Self.actionsBody(Self.swipeSteps(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms)))
    }

    /// Escribe `text` en el campo con foco (`POST /session/{id}/wda/keys`, un carácter por elemento).
    /// Con `submit` pulsa Return al final (añade "\n" al texto).
    public func typeText(_ text: String, submit: Bool = false) async throws {
        var characters = text.map { String($0) }
        if submit { characters.append("\n") }
        _ = try await inSession("POST", "/wda/keys", body: ["value": characters], timeout: Self.keysTimeout)
    }

    /// Pulsa un botón de hardware con WDA (`POST /session/{id}/wda/pressButton`):
    /// `home`, `volume_up`, `volume_down` o `lock`.
    public func pressButton(_ name: String) async throws {
        let wdaName: String
        switch name {
        case "home": wdaName = "home"
        case "volume_up": wdaName = "volumeUp"
        case "volume_down": wdaName = "volumeDown"
        case "lock": wdaName = "lock"
        default: throw WdaError.invalidButton(name)
        }
        _ = try await post("/wda/pressButton", ["name": wdaName])
    }

    /// Lanza la app con `POST /session/{id}/wda/apps/launch` (en frío puede tardar hasta 60 s).
    public func launchApp(bundleID: String) async throws {
        _ = try await inSession("POST", "/wda/apps/launch", body: ["bundleId": bundleID], timeout: Self.launchTimeout)
    }

    /// Termina la app con `POST /session/{id}/wda/apps/terminate`.
    public func terminateApp(bundleID: String) async throws {
        _ = try await post("/wda/apps/terminate", ["bundleId": bundleID])
    }

    // MARK: - Sesión y transporte

    /// La sesión existente o una nueva con `POST /session`.
    private func ensureSession() async throws -> String {
        if let sessionID { return sessionID }
        let response = try await call("POST", "/session", body: ["capabilities": ["alwaysMatch": [:]]])
        let value = response["value"] as? [String: Any] ?? [:]
        guard let id = response["sessionId"] as? String ?? value["sessionId"] as? String else {
            throw WdaError.invalidResponse("Crear la sesión no devolvió sessionId")
        }
        sessionID = id
        return id
    }

    /// Petición con sesión (`/session/{id}...`). Si WDA invalidó la sesión (p. ej. se reinició y
    /// respondió "invalid session id"), se olvida y se crea una nueva **una sola vez**; si vuelve a
    /// fallar, el error se devuelve tal cual.
    private func inSession(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Any? {
        for attempt in 0..<2 {
            let id = try await ensureSession()
            do {
                return try await call(method, "/session/\(id)\(path)", body: body, timeout: timeout)["value"]
            } catch let error as WdaError {
                if case .remote(let kind, _) = error, attempt == 0, kind.lowercased().contains("session") {
                    sessionID = nil
                    continue
                }
                throw error
            }
        }
        throw WdaError.invalidResponse("No se pudo establecer sesión con WDA")
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval? = nil) async throws -> Any? {
        try await inSession("POST", path, body: body, timeout: timeout)
    }

    /// `GET` sin sesión (las rutas de WDA que no pasan por XCTest: /status, /screenshot, /source, /wda/...).
    private func get(_ path: String, timeout: TimeInterval? = nil) async throws -> Any? {
        try await call("GET", path, timeout: timeout)["value"]
    }

    /// Una petición HTTP a WDA. Devuelve el JSON completo de la respuesta.
    ///
    /// `/status` no pasa por XCTest (responde aunque WDA esté medio muerto), así que no cuenta para
    /// el atasco: tras `stallLimit` peticiones seguidas sin respuesta se declara que WDA está
    /// atascado y ya no si envían más (salvo `/status`).
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        if path != "/status", unanswered >= Self.stallLimit {
            throw WdaError.stalled
        }
        // /status no pasa por XCTest: responde aunque WDA esté medio muerto, así que ni suma ni limpia
        // el contador. Si lo limpiara, un WDA atascado que sigue contestando /status nunca se detectaría
        // (el daemon Rust tampoco lo cuenta).
        let countsForStall = path != "/status"
        do {
            let json = try await perform(method, path, body: body, timeout: timeout ?? self.timeout)
            if countsForStall { unanswered = 0 } // WDA respondió (aunque fuera con error): no está atascado
            return json
        } catch let error as WdaError {
            if countsForStall {
                if case .timeout = error { unanswered += 1 } else { unanswered = 0 }
            }
            throw error
        }
    }

    private func perform(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval) async throws -> [String: Any] {
        let request = try self.request(method, path, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw WdaError.timeout("\(method) \(path) superó los \(Int(request.timeoutInterval)) s")
        } catch {
            throw WdaError.unavailable("\(method) \(path): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WdaError.invalidResponse("\(method) \(path): la respuesta no es HTTP")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let value = json?["value"] as? [String: Any], let kind = value["error"] as? String {
            let message = (value["message"] as? String ?? "").components(separatedBy: .newlines).first ?? ""
            throw WdaError.remote(kind: kind, message: message)
        }
        if http.statusCode >= 400 {
            throw WdaError.remote(kind: "http", message: "\(http.statusCode)")
        }
        guard let json else {
            throw WdaError.invalidResponse("\(method) \(path): la respuesta (HTTP \(http.statusCode)) no es JSON")
        }
        return json
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        guard let target = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw WdaError.invalidResponse("Ruta inválida: \(path)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

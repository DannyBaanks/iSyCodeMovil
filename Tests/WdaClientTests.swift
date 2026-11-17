import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import IysCodeMovilCore

/// Simula WDA contestando a las peticiones del cliente: cada petición queda registrada en
/// `MockWDA.requests` y se responde con lo que devuelva `handler`.
private final class MockWDA: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []

    static func reset(_ handler: ((URLRequest) throws -> (Int, Data))? = nil) {
        Self.handler = handler
        Self.requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didReceive: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class WdaClientTests: XCTestCase {
    private var session: URLSession!
    private var client: WdaClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWDA.self]
        session = URLSession(configuration: config)
        client = WdaClient(session: session)
    }

    override func tearDown() {
        session.finishTasksAndInvalidate()
        MockWDA.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func stub(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        MockWDA.reset(handler)
    }

    private func json(_ status: Int = 200, _ object: [String: Any]) -> (Int, Data) {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }

    private func wdaError(_ status: Int, _ error: String, _ message: String) -> (Int, Data) {
        json(status, ["value": ["error": error, "message": message]])
    }

    /// Stub mínimo: crea la sesión `S1` y acepta cualquier POST dentro de ella.
    private func stubWithSession(_ sessionID: String = "S1", invalidSessions: Set<String> = []) {
        stub { request in
            let path = request.url?.path ?? ""
            if path == "/session" && request.httpMethod == "POST" {
                return self.json(["value": ["sessionId": sessionID, "capabilities": [:]], "sessionId": sessionID])
            }
            if invalidSessions.contains(path.components(separatedBy: "/")[2]) {
                return self.wdaError(404, "invalid session id", "Session does not exist")
            }
            if path.hasPrefix("/session/") {
                return self.json(["value": [:]])
            }
            return self.wdaError(404, "unknown command", path)
        }
    }

    private func requests(to path: String) -> [URLRequest] {
        MockWDA.requests.filter { $0.url?.path == path }
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n > 0 { buffer.append(chunk, count: n) } else { break }
            }
            stream.close()
            data = buffer
        } else {
            XCTFail("La petición no tiene cuerpo")
            throw NSError(domain: "WdaClientTests", code: 1)
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func actions(of request: URLRequest) throws -> [[String: Any]] {
        let json = try body(of: request)
        let pointer = try XCTUnwrap((json["actions"] as? [[String: Any]])?.first)
        XCTAssertEqual(pointer["type"] as? String, "pointer")
        XCTAssertEqual(pointer["id"] as? String, "finger1")
        XCTAssertEqual((pointer["parameters"] as? [String: Any])?["pointerType"] as? String, "touch")
        return try XCTUnwrap(pointer["actions"] as? [[String: Any]])
    }

    private func str(_ value: Any?) -> String? { value as? String }
    private func dbl(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    // MARK: - Estado

    func testStatusCombinesStatusLockedAppAndScreen() async throws {
        stub { request in
            switch request.url?.path {
            case "/status": return self.json(["value": ["ready": true, "message": "WebDriverAgent is ready"]])
            case "/wda/locked": return self.json(["value": true])
            case "/wda/activeAppInfo": return self.json(["value": ["bundleId": "com.apple.mobilesafari", "pid": 321]])
            case "/wda/screen": return self.json(["value": ["screenSize": ["width": 393, "height": 852], "scale": 3]])
            default: return self.wdaError(404, "unknown command", request.url?.path ?? "")
            }
        }
        let status = try await client.status()
        XCTAssertTrue(status.ready)
        XCTAssertTrue(status.locked)
        XCTAssertEqual(status.foregroundBundleID, "com.apple.mobilesafari")
        XCTAssertEqual(status.width, 393)
        XCTAssertEqual(status.height, 852)
        // Ninguna de estas rutas pasa por sesión
        XCTAssertTrue(requests(to: "/status").count == 1)
        XCTAssertTrue(MockWDA.requests.contains { $0.url?.path == "/session" } == false)
    }

    func testScreenshotDecodesBase64() async throws {
        let png = "fake-png-bytes".data(using: .utf8)!
        stub { request in
            if request.url?.path == "/screenshot" {
                return self.json(["value": png.base64EncodedString()])
            }
            return self.wdaError(404, "unknown command", "x")
        }
        let data = try await client.screenshotPNG()
        XCTAssertEqual(data, png)
    }

    func testPageSourceReturnsXML() async throws {
        stub { request in
            if request.url?.path == "/source" {
                XCTAssertEqual(request.url?.query, "format=xml")
                return self.json(["value": "<AppiumAUT><XCUIElementTypeApplication/></AppiumAUT>"])
            }
            return self.wdaError(404, "unknown command", "x")
        }
        XCTAssertEqual(try await client.pageSource(), "<AppiumAUT><XCUIElementTypeApplication/></AppiumAUT>")
    }

    // MARK: - Sesión

    func testTapCreatesOneSessionAndReusesIt() async throws {
        var sessions = 0
        stub { request in
            if request.url?.path == "/session" {
                sessions += 1
                return self.json(["value": ["sessionId": "S1", "capabilities": [:]], "sessionId": "S1"])
            }
            if request.url?.path == "/session/S1/actions" { return self.json(["value": [:]]) }
            return self.wdaError(404, "unknown command", "x")
        }
        try await client.tap(x: 100, y: 200)
        try await client.tap(x: 5, y: 6)
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(requests(to: "/session/S1/actions").count, 2)
    }

    func testSessionIdCanComeFromValue() async throws {
        stub { request in
            if request.url?.path == "/session" {
                return self.json(["value": ["sessionId": "S9", "capabilities": [:]]]) // sin sessionId de nivel superior
            }
            if request.url?.path == "/session/S9/actions" { return self.json(["value": [:]]) }
            return self.wdaError(404, "unknown command", "x")
        }
        try await client.tap(x: 1, y: 1)
        XCTAssertEqual(requests(to: "/session/S9/actions").count, 1)
    }

    func testInvalidSessionIsRecreatedOnce() async throws {
        var next = ["S1", "S2"]
        stub { request in
            let path = request.url?.path ?? ""
            if path == "/session" {
                let id = next.removeFirst()
                return self.json(["value": ["sessionId": id, "capabilities": [:]], "sessionId": id])
            }
            if path == "/session/S1/actions" { return self.wdaError(404, "invalid session id", "Session does not exist") }
            if path == "/session/S2/actions" { return self.json(["value": [:]]) }
            return self.wdaError(404, "unknown command", path)
        }
        try await client.tap(x: 10, y: 20) // S1 invalidada -> se crea S2 y se reintenta
        XCTAssertEqual(requests(to: "/session").count, 2)
        XCTAssertEqual(requests(to: "/session/S1/actions").count, 1)
        XCTAssertEqual(requests(to: "/session/S2/actions").count, 1)
    }

    func testInvalidSessionTwiceIsNotRetriedAgain() async throws {
        // las dos sesiones que se creen son inválidas: sólo se recrea una vez
        var next = ["S1", "S2"]
        stub { request in
            let path = request.url?.path ?? ""
            if path == "/session" {
                let id = next.removeFirst()
                return self.json(["value": ["sessionId": id], "sessionId": id])
            }
            if path.hasPrefix("/session/") { return self.wdaError(404, "invalid session id", "Session does not exist") }
            return self.wdaError(404, "unknown command", path)
        }
        await XCTAssertThrowsAsyncError(try await client.tap(x: 1, y: 1)) { error in
            guard case WdaError.remote(let kind, _) = error else { return XCTFail("esperaba remote, llegó \(error)") }
            XCTAssertTrue(kind.contains("session"))
        }
        XCTAssertEqual(requests(to: "/session").count, 2)
    }

    // MARK: - Cuerpos W3C de los gestos

    func testTapSendsW3CPointerBodyWith50msPress() async throws {
        stubWithSession()
        try await client.tap(x: 100, y: 200)
        let steps = try actions(of: try XCTUnwrap(requests(to: "/session/S1/actions").first))
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(str(steps[0]["type"]), "pointerMove")
        XCTAssertEqual(dbl(steps[0]["x"]), 100)
        XCTAssertEqual(dbl(steps[0]["y"]), 200)
        XCTAssertEqual(int(steps[0]["duration"]), 0)
        XCTAssertEqual(str(steps[1]["type"]), "pointerDown")
        XCTAssertEqual(int(steps[1]["button"]), 0)
        XCTAssertEqual(str(steps[2]["type"]), "pause")
        XCTAssertEqual(int(steps[2]["duration"]), WdaClient.tapPressMs) // TAP_PRESS_MS = 50
        XCTAssertEqual(int(steps[2]["duration"]), 50)
        XCTAssertEqual(str(steps[3]["type"]), "pointerUp")
        XCTAssertEqual(int(steps[3]["button"]), 0)
    }

    func testLongPressUsesGivenSeconds() async throws {
        stubWithSession()
        try await client.longPress(x: 1, y: 2, seconds: 1.5)
        let steps = try actions(of: try XCTUnwrap(requests(to: "/session/S1/actions").first))
        XCTAssertEqual(str(steps[2]["type"]), "pause")
        XCTAssertEqual(int(steps[2]["duration"]), 1500)
    }

    func testSwipeSendsSwipeSteps() async throws {
        stubWithSession()
        try await client.swipe(fromX: 10, fromY: 20, toX: 30, toY: 40, seconds: 0.3)
        let steps = try actions(of: try XCTUnwrap(requests(to: "/session/S1/actions").first))
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(str(steps[0]["type"]), "pointerMove")
        XCTAssertEqual(dbl(steps[0]["x"]), 10)
        XCTAssertEqual(dbl(steps[0]["y"]), 20)
        XCTAssertEqual(str(steps[1]["type"]), "pointerDown")
        XCTAssertEqual(str(steps[2]["type"]), "pause")
        XCTAssertEqual(int(steps[2]["duration"]), 50)
        XCTAssertEqual(str(steps[3]["type"]), "pointerMove")
        XCTAssertEqual(dbl(steps[3]["x"]), 30)
        XCTAssertEqual(dbl(steps[3]["y"]), 40)
        XCTAssertEqual(int(steps[3]["duration"]), 300)
        XCTAssertEqual(str(steps[4]["type"]), "pointerUp")
    }

    // MARK: - Teclado, botones y apps

    func testTypeTextSplitsCharactersAndSubmitAppendsReturn() async throws {
        stubWithSession()
        try await client.typeText("hola", submit: true)
        let body = try body(of: try XCTUnwrap(requests(to: "/session/S1/wda/keys").first))
        XCTAssertEqual(body["value"] as? [String], ["h", "o", "l", "a", "\n"])

        try await client.typeText("ab")
        let second = try body(of: requests(to: "/session/S1/wda/keys")[1])
        XCTAssertEqual(second["value"] as? [String], ["a", "b"])
    }

    func testPressButtonMapsNamesToWDA() async throws {
        stubWithSession()
        try await client.pressButton("home")
        try await client.pressButton("volume_up")
        try await client.pressButton("volume_down")
        try await client.pressButton("lock")
        let sent = try requests(to: "/session/S1/wda/pressButton").map { try body(of: $0)["name"] as? String }
        XCTAssertEqual(sent, ["home", "volumeUp", "volumeDown", "lock"])
    }

    func testPressButtonRejectsUnknownName() async throws {
        stubWithSession()
        await XCTAssertThrowsAsyncError(try await client.pressButton("power")) { error in
            guard case WdaError.invalidButton("power") = error else { return XCTFail("esperaba invalidButton, llegó \(error)") }
        }
        XCTAssertTrue(requests(to: "/session/S1/wda/pressButton").isEmpty)
    }

    func testLaunchAndTerminateApp() async throws {
        stubWithSession()
        try await client.launchApp(bundleID: "com.example.app")
        try await client.terminateApp(bundleID: "com.example.app")
        let launch = try body(of: try XCTUnwrap(requests(to: "/session/S1/wda/apps/launch").first))
        XCTAssertEqual(launch["bundleId"] as? String, "com.example.app")
        let terminate = try body(of: try XCTUnwrap(requests(to: "/session/S1/wda/apps/terminate").first))
        XCTAssertEqual(terminate["bundleId"] as? String, "com.example.app")
    }

    // MARK: - Errores

    func testWDAErrorIsSurfacedWithFirstMessageLine() async throws {
        stub { _ in self.wdaError(500, "unknown error", "boom\nsecond line") }
        await XCTAssertThrowsAsyncError(try await client.status()) { error in
            guard case WdaError.remote(let kind, let message) = error else { return XCTFail("esperaba remote, llegó \(error)") }
            XCTAssertEqual(kind, "unknown error")
            XCTAssertEqual(message, "boom")
        }
    }

    func testHTTPErrorWithoutW3CValueBecomesHttpKind() async throws {
        stub { _ in self.json(503, ["value": [:]]) }
        await XCTAssertThrowsAsyncError(try await client.status()) { error in
            guard case WdaError.remote(let kind, let message) = error else { return XCTFail("esperaba remote, llegó \(error)") }
            XCTAssertEqual(kind, "http")
            XCTAssertEqual(message, "503")
        }
    }

    func testUnreachableWDAIsUnavailable() async throws {
        stub { _ in throw URLError(.cannotConnectToHost) }
        await XCTAssertThrowsAsyncError(try await client.status()) { error in
            guard case WdaError.unavailable = error else { return XCTFail("esperaba unavailable, llegó \(error)") }
        }
        XCTAssertNotNil((WdaError.unavailable("x") as LocalizedError).errorDescription?.contains("WDA no está disponible"))
    }

    func testStalledAfterThreeUnansweredRequests() async throws {
        stub { request in
            if request.url?.path == "/status" { return self.json(["value": ["ready": true]]) }
            throw URLError(.timedOut)
        }
        for _ in 0..<WdaClient.stallLimit {
            await XCTAssertThrowsAsyncError(try await client.pressButton("lock")) { error in
                guard case WdaError.timeout = error else { return XCTFail("esperaba timeout, llegó \(error)") }
            }
        }
        XCTAssertEqual(MockWDA.requests.count, WdaClient.stallLimit)
        // La siguiente petición ya no se envía: se declara el atasco de inmediato.
        await XCTAssertThrowsAsyncError(try await client.pressButton("lock")) { error in
            guard case WdaError.stalled = error else { return XCTFail("esperaba stalled, llegó \(error)") }
        }
        XCTAssertEqual(MockWDA.requests.count, WdaClient.stallLimit)
        XCTAssertNotNil((WdaError.stalled as LocalizedError).errorDescription?.contains("atascado"))
    }
}

private func XCTAssertThrowsAsyncError<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("Se esperaba un error y no se lanzó ninguno. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

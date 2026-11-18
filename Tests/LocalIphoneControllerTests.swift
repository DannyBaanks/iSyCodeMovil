import Foundation
import XCTest
@testable import IysCodeMovilCore

final class LocalIphoneControllerTests: XCTestCase {
    func testToolsCallTheExpectedWDAOperations() async throws {
        let wda = RecordingWda()
        let controller = LocalIphoneController(wda: wda, elementReader: StubElementReader())

        let status = try await controller.call(tool: "iphone_status", arguments: [:])
        let screenshot = try await controller.call(tool: "iphone_screenshot", arguments: [:])
        let devices = try await controller.call(tool: "iphone_list_devices", arguments: [:])
        let listed = try await controller.call(tool: "iphone_list_elements", arguments: ["filter": "continuar", "limit": 3])
        XCTAssertTrue(status.contains("app.id"))
        XCTAssertTrue(screenshot.contains("2 KB"))
        XCTAssertEqual(devices, "Este iPhone (WebDriverAgent en 127.0.0.1:8100).")
        XCTAssertEqual(listed, "Continuar")

        _ = try await controller.call(tool: "iphone_tap", arguments: ["x": 10.5, "y": 20.0])
        _ = try await controller.call(tool: "iphone_tap_element", arguments: ["text": "Continuar", "index": 1])
        _ = try await controller.call(tool: "iphone_long_press", arguments: ["x": 1.0, "y": 2.0, "seconds": 2.0])
        _ = try await controller.call(tool: "iphone_swipe", arguments: ["from_x": 1.0, "from_y": 2.0, "to_x": 3.0, "to_y": 4.0, "seconds": 0.5])
        _ = try await controller.call(tool: "iphone_type_text", arguments: ["text": "hola", "submit": true])
        _ = try await controller.call(tool: "iphone_press_button", arguments: ["button": "home"])
        _ = try await controller.call(tool: "iphone_launch_app", arguments: ["app": "com.example.app"])
        _ = try await controller.call(tool: "iphone_terminate_app", arguments: ["app": "com.example.app"])
        let waited = try await controller.call(tool: "iphone_wait_for", arguments: ["text": "Continuar", "timeout": 0.2])
        XCTAssertEqual(waited, "Encontrado: Continuar")

        let calls = await wda.recordedCalls()
        XCTAssertEqual(calls, [
            "status", "screenshotPNG", "pageSource", "tap(10.5,20.0)",
            "pageSource", "tap(33.0,48.0)", "longPress(1.0,2.0,2.0)",
            "swipe(1.0,2.0,3.0,4.0,0.5)", "typeText(hola,true)", "pressButton(home)",
            "launchApp(com.example.app)", "terminateApp(com.example.app)", "pageSource"
        ])
    }

    func testThenElementsWaitsAndReturnsAFormattedList() async throws {
        let wda = RecordingWda()
        let controller = LocalIphoneController(wda: wda, elementReader: StubElementReader())
        let started = Date()

        let result = try await controller.call(tool: "iphone_tap", arguments: ["x": 4.0, "y": 8.0, "then": "elements"])

        XCTAssertEqual(result, "Continuar")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.55)
        let calls = await wda.recordedCalls()
        XCTAssertEqual(calls, ["tap(4.0,8.0)", "pageSource"])
    }

    func testUnsupportedAndInvalidCallsFailClearly() async throws {
        let wda = RecordingWda()
        let controller = LocalIphoneController(wda: wda, elementReader: StubElementReader())

        await assertError(contains: "no está disponible", from: controller, tool: "iphone_list_apps", arguments: [:])
        await assertError(contains: "no está disponible", from: controller, tool: "iphone_open_url", arguments: ["url": "https://example.com"])
        await assertError(contains: "no está disponible", from: controller, tool: "iphone_batch", arguments: [:])
        await assertError(contains: "no está disponible", from: controller, tool: "iphone_select_device", arguments: [:])
        await assertError(contains: "no está disponible", from: controller, tool: "iphone_unknown", arguments: [:])
        await assertError(contains: "button debe ser", from: controller, tool: "iphone_press_button", arguments: ["button": "power"])
        await assertError(contains: "Falta el argumento x", from: controller, tool: "iphone_tap", arguments: ["y": 2.0])
        await assertError(contains: "then debe ser", from: controller, tool: "iphone_tap", arguments: ["x": 1.0, "y": 2.0, "then": "other"])
        await assertError(contains: "No apareció", from: controller, tool: "iphone_wait_for", arguments: ["text": "nunca", "timeout": 0.0])
        let calls = await wda.recordedCalls()
        XCTAssertEqual(calls, ["pageSource"])
    }

    func testBundleIDAliasesResolveChatGPTToTheRealID() async throws {
        let wda = RecordingWda()
        let controller = LocalIphoneController(wda: wda, elementReader: StubElementReader())

        // Nombre y el ID incorrecto histórico llegan al mismo ID real.
        let byName = try await controller.call(tool: "iphone_launch_app", arguments: ["app": "chatgpt"])
        let byWrongID = try await controller.call(tool: "iphone_launch_app", arguments: ["app": "com.openai.chatgpt"])
        XCTAssertTrue(byName.contains("com.openai.chat"))
        XCTAssertTrue(byWrongID.contains("com.openai.chat"))
        XCTAssertFalse(byWrongID.contains("com.openai.chatgpt"))
        let calls = await wda.recordedCalls()
        XCTAssertEqual(calls, ["launchApp(com.openai.chat)", "launchApp(com.openai.chat)"])
    }

    func testResolveBundleIDTable() {
        XCTAssertEqual(LocalIphoneController.resolveBundleID("chatgpt"), "com.openai.chat")
        XCTAssertEqual(LocalIphoneController.resolveBundleID("com.openai.chatgpt"), "com.openai.chat")
        XCTAssertEqual(LocalIphoneController.resolveBundleID("com.openai.chat"), "com.openai.chat")
        XCTAssertEqual(LocalIphoneController.resolveBundleID("safari"), "com.apple.mobilesafari")
        XCTAssertEqual(LocalIphoneController.resolveBundleID("com.example.app"), "com.example.app")
        // Sin alias conocido, el nombre se devuelve tal cual (no se inventa un ID).
        XCTAssertEqual(LocalIphoneController.resolveBundleID("claude"), "claude")
    }

    func testControlModeResolutionTable() {
        let cases: [(IphoneControlMode?, [String], Bool, IphoneControlMode?)] = [
            (nil, [], false, nil),
            (nil, ["iphone_status"], false, .computer),
            (nil, [], true, .thisPhone),
            (nil, ["iphone_status"], true, .computer),
            (.computer, ["iphone_status"], true, .computer),
            (.computer, [], true, .thisPhone),
            (.thisPhone, ["iphone_status"], true, .thisPhone),
            (.thisPhone, ["iphone_status"], false, .computer),
            (nil, ["not_a_catalog_tool"], false, nil)
        ]

        for (preferred, bridgeTools, localReachable, expected) in cases {
            XCTAssertEqual(
                IphoneControlMode.resolve(preferred: preferred, bridgeTools: bridgeTools, localReachable: localReachable),
                expected,
                "preferred=\(String(describing: preferred)), bridgeTools=\(bridgeTools), localReachable=\(localReachable)"
            )
        }
    }

    private func assertError(
        contains phrase: String,
        from controller: LocalIphoneController,
        tool: String,
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await controller.call(tool: tool, arguments: arguments)
            XCTFail("Expected \(tool) to fail", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(phrase), error.localizedDescription, file: file, line: line)
        }
    }
}

private actor RecordingWda: WdaDriving {
    private var calls: [String] = []

    func status() async throws -> LocalWdaStatus {
        calls.append("status")
        return LocalWdaStatus(ready: true, locked: false, foregroundBundleID: "app.id", widthPoints: 390, heightPoints: 844)
    }

    func screenshotPNG() async throws -> Data {
        calls.append("screenshotPNG")
        return Data(repeating: 0, count: 2048)
    }

    func pageSource() async throws -> String {
        calls.append("pageSource")
        return "<App/>"
    }

    func tap(x: Double, y: Double) async throws { calls.append("tap(\(x),\(y))") }
    func longPress(x: Double, y: Double, seconds: Double) async throws { calls.append("longPress(\(x),\(y),\(seconds))") }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double) async throws {
        calls.append("swipe(\(fromX),\(fromY),\(toX),\(toY),\(seconds))")
    }
    func typeText(_ text: String, submit: Bool) async throws { calls.append("typeText(\(text),\(submit))") }
    func pressButton(_ button: String) async throws { calls.append("pressButton(\(button))") }
    func launchApp(bundleID: String) async throws { calls.append("launchApp(\(bundleID))") }
    func terminateApp(bundleID: String) async throws { calls.append("terminateApp(\(bundleID))") }

    func recordedCalls() -> [String] { calls }
}

private struct StubElementReader: WdaElementReading {
    func parse(xml: String) -> [LocalElement] {
        [LocalElement(kind: "Button", label: "Continuar", name: "", value: "", centerX: 32, centerY: 48, width: 80, height: 40)]
    }
    func format(_ elements: [LocalElement], limit: Int) -> String { "Continuar" }
    func resolveTap(text: String, index: Int, in elements: [LocalElement]) throws -> (x: Double, y: Double) { (32 + Double(index), 48) }
}

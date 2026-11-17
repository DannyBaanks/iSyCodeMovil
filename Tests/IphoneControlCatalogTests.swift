import XCTest
@testable import IysCodeMovilCore

final class IphoneControlCatalogTests: XCTestCase {
    private let observing = ["iphone_status", "iphone_screenshot", "iphone_list_apps", "iphone_list_devices"]

    func testOnlyToolsTheComputerAllowedBecomeTools() {
        XCTAssertEqual(Set(IphoneControlCatalog.tools(allowed: observing).map(\.name)), Set(observing))
        XCTAssertTrue(IphoneControlCatalog.tools(allowed: []).isEmpty)
        // A name the computer never offered, or an admin tool, is ignored even if listed.
        let tools = IphoneControlCatalog.tools(allowed: ["iphone_select_device", "iphone_nope", "iphone_status"]).map(\.name)
        XCTAssertEqual(tools, ["iphone_status"])
        XCTAssertFalse(IphoneControlCatalog.names.contains("iphone_select_device"))
        XCTAssertFalse(IphoneControlCatalog.names.contains("iphone_batch"))
    }

    func testApprovalTiers() throws {
        let tools = IphoneControlCatalog.tools(allowed: IphoneControlCatalog.names)
        func tool(_ name: String) throws -> AgentTool { try XCTUnwrap(tools.first { $0.name == name }) }
        for name in observing + ["iphone_list_elements", "iphone_wait_for"] {
            XCTAssertFalse(try tool(name).capabilities.isDestructive, name)
        }
        for name in ["iphone_tap", "iphone_tap_element", "iphone_swipe", "iphone_long_press", "iphone_press_button", "iphone_launch_app", "iphone_terminate_app"] {
            let capabilities = try tool(name).capabilities
            XCTAssertTrue(capabilities.isDestructive, name)
            XCTAssertFalse(capabilities.requiresApprovalEveryTime, name)
        }
        for name in ["iphone_type_text", "iphone_open_url"] {
            let capabilities = try tool(name).capabilities
            XCTAssertTrue(capabilities.isDestructive, name)
            XCTAssertTrue(capabilities.requiresApprovalEveryTime, name)
        }
    }

    func testArgumentsAreTypedAndValidated() throws {
        let tap = try IphoneControlCatalog.arguments(for: "iphone_tap", from: ["x": "10.5", "y": "20", "then": "elements"])
        XCTAssertEqual(tap["x"] as? Double, 10.5)
        XCTAssertEqual(tap["y"] as? Double, 20)
        XCTAssertEqual(tap["then"] as? String, "elements")

        let list = try IphoneControlCatalog.arguments(for: "iphone_list_elements", from: ["limit": "5"])
        XCTAssertEqual(list["limit"] as? Int, 5)
        let typed = try IphoneControlCatalog.arguments(for: "iphone_type_text", from: ["text": "hola", "submit": "TRUE"])
        XCTAssertEqual(typed["submit"] as? Bool, true)

        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_tap", from: ["x": "1"]))            // missing y
        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_tap", from: ["x": "abc", "y": "1"])) // not a number
        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_tap", from: ["x": "nan", "y": "1"]))
        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_tap", from: ["x": "1", "y": "1", "extra": "x"]))
        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_press_button", from: ["button": "power"]))
        XCTAssertThrowsError(try IphoneControlCatalog.arguments(for: "iphone_select_device", from: ["device": "auto"]))
    }

    func testReportReadsTextAndMentionsImages() throws {
        let text = try IphoneControlCatalog.report(["content": [["type": "text", "text": "listo"]]])
        XCTAssertEqual(text, "listo")
        let image = try IphoneControlCatalog.report(["content": [["type": "image", "data": String(repeating: "a", count: 2048)], ["type": "text", "text": "pantalla"]]])
        XCTAssertTrue(image.contains("2 KB"))
        XCTAssertTrue(image.contains("pantalla"))
        XCTAssertThrowsError(try IphoneControlCatalog.report(["content": [["type": "text", "text": "falló"]], "isError": true]))
    }

    func testExecutorOffersIphoneToolsOnlyWhenTheComputerDoes() throws {
        let pairing = try SandboxPairing(host: "100.101.102.103", port: 8788, token: String(repeating: "t", count: 43), directory: "/p")
        let client = SandboxHostClient(pairing: pairing)
        func names(_ tools: [String]) -> [String] {
            let info = SandboxBridgeInfo(projectName: "p", repo: nil, defaultBranch: nil, hasGitHubAccount: false, iphoneTools: tools)
            return SandboxToolExecutor(client: client, sandboxID: "mc-abcdef", info: info).availableTools.map(\.name)
        }
        XCTAssertFalse(names([]).contains { $0.hasPrefix("iphone_") })
        XCTAssertTrue(names(["iphone_status"]).contains("iphone_status"))
        XCTAssertFalse(names(["iphone_status"]).contains("iphone_tap"))
        let info = SandboxBridgeInfo(projectName: "p", repo: nil, defaultBranch: nil, hasGitHubAccount: false, iphoneTools: [])
        XCTAssertFalse(SandboxToolExecutor(client: client, sandboxID: "mc-abcdef", info: info).systemPrompt.contains("iPhone real"))
    }

    func testExecutorRefusesAnIphoneToolTheComputerDidNotList() async throws {
        let pairing = try SandboxPairing(host: "100.101.102.103", port: 8788, token: String(repeating: "t", count: 43), directory: "/p")
        let info = SandboxBridgeInfo(projectName: "p", repo: nil, defaultBranch: nil, hasGitHubAccount: false, iphoneTools: ["iphone_status"])
        let executor = SandboxToolExecutor(client: SandboxHostClient(pairing: pairing), sandboxID: "mc-abcdef", info: info)
        let result = await executor.execute(ToolInvocation(name: "iphone_tap", arguments: ["x": "1", "y": "1"]))
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.output.isEmpty)
    }
}

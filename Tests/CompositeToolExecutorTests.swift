import XCTest
@testable import IysCodeMovilCore

/// The sandbox agent used only the sandbox's tools, so it could not read the person's mail. These tests pin what the
/// composite brings in (Google, notifications, Shortcuts), what it must keep out (the native file tools that clash with
/// the sandbox's), and that reading personal data asks first.
final class CompositeToolExecutorTests: XCTestCase {
    private final class FakeExecutor: ToolExecutor, @unchecked Sendable {
        let label: String
        let tools: [AgentTool]
        let context: String?
        private(set) var calls: [String] = []
        private(set) var approvals: [PermissionResponse.Decision?] = []

        init(label: String, tools: [AgentTool], context: String? = nil) {
            self.label = label
            self.tools = tools
            self.context = context
        }

        var availableTools: [AgentTool] { tools }

        func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
            await execute(invocation, approval: nil)
        }

        func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
            calls.append(invocation.name)
            approvals.append(approval)
            return ToolExecutionResult(toolCallId: invocation.id, output: "from \(label)", duration: 0)
        }

        func sharedContextForPrompt() async -> String? { context }
    }

    private func tool(_ name: String, capabilities: AgentTool.ToolCapabilities = .init()) -> AgentTool {
        AgentTool(name: name, description: name, properties: [:], capabilities: capabilities)
    }

    private func composite(consentForReads: Bool = true) -> (CompositeToolExecutor, FakeExecutor, FakeExecutor) {
        let primary = FakeExecutor(label: "sandbox", tools: [tool("read_file"), tool("run_command")], context: "sandbox context")
        let secondary = FakeExecutor(
            label: "native",
            tools: [
                tool("read_file"), tool("list"), tool("write"),
                tool("gmail.read.inbox", capabilities: .init(requiresNetwork: true)),
                tool("gmail.write.send", capabilities: .init(requiresNetwork: true, isDestructive: true, approvalReason: "Send mail?")),
                tool("notifications.schedule"), tool("shortcuts.run"), tool("update_shared_context")
            ],
            context: "native context"
        )
        return (CompositeToolExecutor(primary: primary, secondary: secondary, consentForReads: consentForReads), primary, secondary)
    }

    func testBringsInCompanionToolsAndKeepsNativeFileToolsOut() {
        let (executor, _, _) = composite()
        XCTAssertEqual(
            executor.availableTools.map(\.name),
            ["read_file", "run_command", "gmail.read.inbox", "gmail.write.send", "notifications.schedule", "shortcuts.run"]
        )
    }

    func testThePrimaryWinsANameClash() {
        let primary = FakeExecutor(label: "sandbox", tools: [tool("shortcuts.run", capabilities: .init(isDestructive: true))])
        let secondary = FakeExecutor(label: "native", tools: [tool("shortcuts.run"), tool("gmail.read.inbox")])
        let names = CompositeToolExecutor(primary: primary, secondary: secondary).availableTools.map(\.name)
        XCTAssertEqual(names.filter { $0 == "shortcuts.run" }.count, 1)
        XCTAssertTrue(names.contains("gmail.read.inbox"))
    }

    func testReadingPersonalDataAsksFirstWithoutAskingEveryTime() throws {
        let (executor, _, _) = composite()
        let read = try XCTUnwrap(executor.availableTools.first { $0.name == "gmail.read.inbox" })
        XCTAssertTrue(read.capabilities.isDestructive)
        XCTAssertFalse(read.capabilities.requiresApprovalEveryTime, "must allow 'approve always'")
        XCTAssertTrue(read.capabilities.requiresNetwork, "the original capabilities are kept")
        XCTAssertNotNil(read.capabilities.approvalReason)
    }

    func testWritesAndOtherToolsKeepTheirOwnApproval() throws {
        let (executor, _, _) = composite()
        let send = try XCTUnwrap(executor.availableTools.first { $0.name == "gmail.write.send" })
        XCTAssertEqual(send.capabilities.approvalReason, "Send mail?")
        let schedule = try XCTUnwrap(executor.availableTools.first { $0.name == "notifications.schedule" })
        XCTAssertFalse(schedule.capabilities.isDestructive)
    }

    func testConsentForReadsCanBeTurnedOff() throws {
        let (executor, _, _) = composite(consentForReads: false)
        let read = try XCTUnwrap(executor.availableTools.first { $0.name == "gmail.read.inbox" })
        XCTAssertFalse(read.capabilities.isDestructive)
    }

    func testRelevantToolsFollowTheSameRules() async {
        let (executor, _, _) = composite()
        let names = await executor.tools(relevantTo: []).map(\.name)
        XCTAssertEqual(names, ["read_file", "run_command", "gmail.read.inbox", "gmail.write.send", "notifications.schedule", "shortcuts.run"])
    }

    func testCallsGoToWhoOffersTheToolAndApprovalsPassThrough() async {
        let (executor, primary, secondary) = composite()
        let mail = await executor.execute(ToolInvocation(name: "gmail.read.inbox", arguments: [:]), approval: .allowOnce)
        XCTAssertEqual(mail.output, "from native")
        XCTAssertEqual(secondary.calls, ["gmail.read.inbox"])
        XCTAssertEqual(secondary.approvals, [.allowOnce])

        let file = await executor.execute(ToolInvocation(name: "read_file", arguments: [:]))
        XCTAssertEqual(file.output, "from sandbox", "a clash goes to the primary")
        XCTAssertEqual(primary.calls, ["read_file"])

        // A name nobody offers is not forwarded to the native executor's file tools.
        let unknown = await executor.execute(ToolInvocation(name: "write", arguments: [:]))
        XCTAssertEqual(unknown.output, "from sandbox")
        XCTAssertEqual(secondary.calls, ["gmail.read.inbox"])
    }

    func testPromptContextComesOnlyFromThePrimary() async {
        let (executor, _, _) = composite()
        let shared = await executor.sharedContextForPrompt()
        XCTAssertEqual(shared, "sandbox context")
    }

    func testLayersNoteTellsTheAgentToPreferTheInvisibleLayer() {
        XCTAssertTrue(CompositeToolExecutor.layersNote.contains("gmail."))
        XCTAssertTrue(CompositeToolExecutor.layersNote.contains("segundo plano"))
    }
}

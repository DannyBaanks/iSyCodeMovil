import Foundation
import XCTest
@testable import IysCodeMovilCore

final class AgentContractAndPythonTests: XCTestCase {
    // MARK: - Scenario E: Embedded Python Runtime (pocketpy 2.2.0)

    func testPythonRuntimeEvaluatesCSVAndJSONWithoutOSAccess() async {
        let csvInput = "sku,nombre,precio,stock\nA1,Café Orgánico,185.50,12\nA2,Taza Coral,120.00,5\n"
        let script = """
        rows = csv.parse(INPUT_TEXT)
        total = sum(float(r['precio']) for r in rows)
        print(json.dumps({'count': len(rows), 'total': round(total, 2)}))
        """
        let receipt = await PythonRuntimeService.shared.evaluate(script: script, inputText: csvInput, timeoutMs: 2000)
        XCTAssertTrue(receipt.succeeded, receipt.error ?? "failed")
        XCTAssertTrue(receipt.stdout.contains("\"count\": 2"))
        XCTAssertTrue(receipt.stdout.contains("305.5"))
        XCTAssertTrue(receipt.runtimeVersion.contains("PK_ENABLE_OS=0"))
    }

    func testPythonRuntimeBlocksOSModuleAndOpenBuiltin() async {
        let osReceipt = await PythonRuntimeService.shared.evaluate(script: "import os\n", inputText: "", timeoutMs: 1500)
        XCTAssertFalse(osReceipt.succeeded)
        XCTAssertTrue((osReceipt.error ?? "").contains("ImportError"))

        let openReceipt = await PythonRuntimeService.shared.evaluate(script: "open('/etc/passwd')\n", inputText: "", timeoutMs: 1500)
        XCTAssertFalse(openReceipt.succeeded)
    }

    func testPythonRuntimeWatchdogInterruptsInfiniteLoop() async {
        let receipt = await PythonRuntimeService.shared.evaluate(script: "while True:\n    pass\n", inputText: "", timeoutMs: 120)
        XCTAssertFalse(receipt.succeeded)
        XCTAssertTrue((receipt.error ?? "").contains("TimeoutError"))
    }

    // MARK: - Scenario B: L1 Strict Permission Inheritance & Cycle Protection

    func testL1EffectiveCapabilitiesNeverEscalateOrDropDestructiveRequirement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l1-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = DynamicToolRegistry(storageURL: dir.appendingPathComponent("l1_tools.json"))
        let sample = L1ToolDefinition.sampleCatalogImporter
        try await registry.upsert(sample)

        let l0Catalog: [String: AgentTool] = [
            "python_eval": AgentTool(name: "python_eval", description: "py", properties: [:]),
            "write_file": AgentTool(
                name: "write_file",
                description: "write",
                properties: [:],
                capabilities: .init(requiresFileSystem: true, isDestructive: true, requiresApprovalEveryTime: true)
            )
        ]

        let tools = await registry.allAgentTools(l0Catalog: l0Catalog)
        let imported = try XCTUnwrap(tools.first { $0.name == sample.name })
        XCTAssertTrue(imported.capabilities.isDestructive)
        XCTAssertTrue(imported.capabilities.requiresFileSystem)
        XCTAssertTrue(imported.capabilities.requiresApprovalEveryTime)
    }

    func testL1RejectsCycles() throws {
        let a = L1ToolDefinition(name: "tool_a", description: "a", steps: [.init(tool: "tool_b", args: [:])])
        let b = L1ToolDefinition(name: "tool_b", description: "b", steps: [.init(tool: "tool_a", args: [:])])
        XCTAssertThrowsError(try DynamicToolRegistry.validateNoCycles(candidate: b, existing: [a]))
    }

    // MARK: - Scenario A & D: .isyagent.json Contract Export/Import & Draft Persistence

    func testExportSanitizesLocalApprovalsAndImportNeverTransfersThem() throws {
        var contract = AgentTemplateCatalog.all[0].makeInitialContract()
        contract.localApprovalGrantedAt = Date()

        let json = try contract.exportSanitizedJSON()
        XCTAssertFalse(json.contains("localApprovalGrantedAt"))

        let imported = try AgentContract.importFromJSON(json)
        XCTAssertNil(imported.localApprovalGrantedAt)
        XCTAssertEqual(imported.name, contract.name)
        XCTAssertEqual(imported.l1Tools.count, contract.l1Tools.count)
    }

    @MainActor
    func testAgentBuilderDraftPersistsAndRecoversAcrossStoreInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = AgentContractStore(directoryURL: dir)
        var draft = AgentBuilderDraft()
        draft.currentStepIndex = 3
        draft.contract.name = "Mi Tienda Coral"
        store1.saveDraft(draft)

        let store2 = AgentContractStore(directoryURL: dir)
        XCTAssertEqual(store2.activeDraft?.currentStepIndex, 3)
        XCTAssertEqual(store2.activeDraft?.contract.name, "Mi Tienda Coral")
    }

    // MARK: - Bounded Sequence Scope & ISyMCP Signing

    func testSequenceApprovalScopeIsBoundedByBudgetAndExpiry() {
        let start = Date()
        var scope = SequenceApprovalScope(objective: "Abrir tienda", maxActions: 2, usedActions: 1, grantedAt: start, ttlSeconds: 60)
        XCTAssertTrue(scope.isValid(for: "iphone_tap", at: start.addingTimeInterval(10)))
        XCTAssertFalse(scope.isValid(for: "write_file", at: start.addingTimeInterval(10)))
        scope.usedActions = 2
        XCTAssertFalse(scope.isValid(for: "iphone_tap", at: start.addingTimeInterval(10)))
        scope.usedActions = 1
        XCTAssertFalse(scope.isValid(for: "iphone_tap", at: start.addingTimeInterval(61)))
    }

    func testISyMCPCanonicalStringAndPairingNormalization() {
        XCTAssertEqual(ISyMCPClient.normalizePairingCode("ab-o i l"), "AB011")
        let canonical = ISyMCPClient.canonicalString(
            method: "get",
            path: "/v1/status",
            ts: "1700000000000",
            nonce: "nonce123",
            body: Data(),
            key: .read
        )
        XCTAssertTrue(canonical.hasPrefix("ISY1\nGET\n/v1/status\n1700000000000\nnonce123\n"))
        XCTAssertTrue(canonical.hasSuffix("\nread"))
    }
}

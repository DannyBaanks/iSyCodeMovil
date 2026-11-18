import XCTest
@testable import IysCodeMovilCore

/// Several conversations at once: one folder each, cleanup that only touches those
/// folders, and a line for the on-device model.
final class ParallelConversationsTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallel-conversations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Folder names

    func testFolderNameIsOneSafePathComponent() {
        XCTAssertEqual(ConversationSandboxes.folderName(for: "ABC-123_x"), "sandbox-ABC-123_x")
        let hostile = ConversationSandboxes.folderName(for: "../../etc/passwd")
        XCTAssertTrue(hostile.hasPrefix("sandbox-"))
        XCTAssertFalse(hostile.contains("/"))
        XCTAssertFalse(hostile.contains(".."))
        XCTAssertEqual(ConversationSandboxes.folderName(for: ""), "sandbox-default")
        XCTAssertLessThanOrEqual(ConversationSandboxes.folderName(for: String(repeating: "a", count: 500)).count, 8 + 96)
    }

    func testEachConversationHasItsOwnActiveProjectKey() {
        let a = ConversationSandboxes.activeProjectKey(for: "A")
        let b = ConversationSandboxes.activeProjectKey(for: "B")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, SimpleWorkspaceToolExecutor.activeProjectKey)
        XCTAssertTrue(a.hasPrefix(SimpleWorkspaceToolExecutor.activeProjectKey))
    }

    // MARK: - Listing and cleanup

    @discardableResult
    private func makeFolder(_ conversationID: String, bytes: Int) throws -> URL {
        let url = base.appendingPathComponent(ConversationSandboxes.folderName(for: conversationID), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url.appendingPathComponent("file.txt"))
        return url
    }

    func testListOnlySeesSandboxFoldersAndMeasuresThem() throws {
        try makeFolder("live", bytes: 4096)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: base.appendingPathComponent("sandbox-not-a-folder"))

        let entries = ConversationSandboxes.list(in: base)
        XCTAssertEqual(entries.map(\.folderName), ["sandbox-live"])
        XCTAssertGreaterThanOrEqual(entries[0].byteCount, 4096)
    }

    func testOrphansAreFoldersOfDeletedConversations() throws {
        try makeFolder("kept", bytes: 10)
        try makeFolder("deleted", bytes: 10)
        let orphans = ConversationSandboxes.orphans(ConversationSandboxes.list(in: base), liveConversationIDs: ["kept"])
        XCTAssertEqual(orphans.map(\.folderName), ["sandbox-deleted"])
    }

    func testRemoveKeepsRunningConversationsAndNeverLeavesBase() throws {
        let idle = try makeFolder("idle", bytes: 2048)
        let running = try makeFolder("running", bytes: 2048)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        var entries = ConversationSandboxes.list(in: base)
        // A forged entry pointing outside `base` must be ignored.
        entries.append(ConversationSandboxes.Entry(folderName: outside.lastPathComponent, url: outside, byteCount: 1))

        let result = ConversationSandboxes.remove(entries, keepingRunning: ["running"], in: base)
        XCTAssertEqual(result.removedFolders, 1)
        XCTAssertEqual(result.skippedRunning, 1)
        XCTAssertGreaterThanOrEqual(result.freedBytes, 2048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - Separate active projects

    func testTwoConversationFoldersKeepTheirOwnActiveProject() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallel-\(UUID().uuidString)"))
        // Same kind of workspace the backend builds per conversation (Application Support).
        let workspaceA = try IOSWorkspace(rootName: ConversationSandboxes.folderName(for: "test-A-\(UUID().uuidString)"))
        let workspaceB = try IOSWorkspace(rootName: ConversationSandboxes.folderName(for: "test-B-\(UUID().uuidString)"))
        // IOSWorkspace is an actor: read the roots once, outside `defer`.
        let rootA = await workspaceA.rootURL
        let rootB = await workspaceB.rootURL
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("repo"), withIntermediateDirectories: true)

        let a = SimpleWorkspaceToolExecutor(
            workspace: workspaceA,
            defaults: defaults,
            activeProjectKey: ConversationSandboxes.activeProjectKey(for: "A")
        )
        let b = SimpleWorkspaceToolExecutor(
            workspace: workspaceB,
            defaults: defaults,
            activeProjectKey: ConversationSandboxes.activeProjectKey(for: "B")
        )
        await a.setActiveProject("repo")
        // B's folder has no "repo": with a shared key this used to erase A's project.
        let bProject = await b.activeProject()
        let aProject = await a.activeProject()
        XCTAssertNil(bProject)
        XCTAssertEqual(aProject, "repo")
    }

    // MARK: - On-device model line

    func testLocalModelGateServesOneConversationAtATimeInOrder() async {
        let gate = LocalModelTurnGate()
        let first = await gate.acquire()
        XCTAssertTrue(first)
        let busy = await gate.isBusy
        XCTAssertTrue(busy)

        let order = OrderRecorder()
        let second = Task {
            let got = await gate.acquire()
            await order.append("second:\(got)")
        }
        let third = Task {
            // Make sure "second" is queued first.
            while await gate.waitingCount < 1 { await Task.yield() }
            let got = await gate.acquire()
            await order.append("third:\(got)")
        }
        while await gate.waitingCount < 2 { await Task.yield() }
        let none = await order.values
        XCTAssertEqual(none, [], "nobody runs while the model is busy")

        await gate.release()
        await second.value
        await gate.release()
        await third.value
        await gate.release()

        let values = await order.values
        XCTAssertEqual(values, ["second:true", "third:true"])
        let free = await gate.isBusy
        XCTAssertFalse(free)
    }

    func testCancelledWaiterLeavesTheLineWithoutTakingTheModel() async {
        let gate = LocalModelTurnGate()
        _ = await gate.acquire()
        let waiter = Task { await gate.acquire() }
        while await gate.waitingCount < 1 { await Task.yield() }
        waiter.cancel()
        let got = await waiter.value
        XCTAssertFalse(got)
        while await gate.waitingCount > 0 { await Task.yield() }
        await gate.release()
        let free = await gate.isBusy
        XCTAssertFalse(free, "a cancelled waiter must not be handed the model")
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

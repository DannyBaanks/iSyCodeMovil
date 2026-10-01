import XCTest
@testable import IysCodeMovilCore

/// Tests de Workspace / Persistence / Tools / AgentLoop end-to-end.
/// Usan un workspace de tests aislado (raíz en App Support con prefijo único).
final class WorkspaceTests: XCTestCase {
    var workspace: IOSWorkspace!

    override func setUp() async throws {
        workspace = try IOSWorkspace(rootName: "test_workspace_\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: await workspace.rootURL)
    }

    func testCreateAndReadFile() async throws {
        try await workspace.writeFile(at: "test.txt", data: Data("hello".utf8))
        let data = try await workspace.readFile(at: "test.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testListDirectory() async throws {
        try await workspace.createDirectory(at: "sub")
        try await workspace.writeFile(at: "sub/a.txt", data: Data("1".utf8))
        try await workspace.writeFile(at: "sub/b.txt", data: Data("2".utf8))
        let items = try await workspace.listDirectory(at: "sub")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
    }

    func testMoveFile() async throws {
        try await workspace.writeFile(at: "from.txt", data: Data("x".utf8))
        try await workspace.moveFile(from: "from.txt", to: "to.txt")
        let exists = await workspace.fileExists(at: "to.txt")
        XCTAssertTrue(exists)
        let gone = await workspace.fileExists(at: "from.txt")
        XCTAssertFalse(gone)
    }

    func testDeleteFile() async throws {
        try await workspace.writeFile(at: "doomed.txt", data: Data("x".utf8))
        try await workspace.deleteFile(at: "doomed.txt")
        let exists = await workspace.fileExists(at: "doomed.txt")
        XCTAssertFalse(exists)
    }

    func testPathTraversalBlocked() async throws {
        do {
            _ = try await workspace.readFile(at: "../outside")
            XCTFail("esperaba pathNotInSandbox")
        } catch WorkspaceError.pathNotInSandbox {
            // OK
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }
}

final class PersistenceTests: XCTestCase {
    var persistence: IOSPersistence!

    override func setUp() async throws {
        persistence = try IOSPersistence()
    }

    func testSaveLoadConversation() async throws {
        var conv = Conversation(id: "t-1", title: "T")
        conv.messages.append(Message(role: .user, content: "hi"))
        try await persistence.saveConversation(conv)
        let loaded = try await persistence.loadConversation(id: "t-1")
        XCTAssertEqual(loaded?.id, "t-1")
        XCTAssertEqual(loaded?.messages.count, 1)
    }

    func testEventLoggingJSONL() async throws {
        let id = UUID().uuidString
        try await persistence.appendEvent(AgentEvent(conversationId: id, type: .userInput, payload: ["content": "x"]))
        let events = try await persistence.loadEvents(conversationId: id, since: nil)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .userInput)
    }

    func testConfigurationRoundtrip() async throws {
        var cfg = Configuration()
        cfg.defaultModelName = "gpt-test"
        cfg.fontSize = 20
        try await persistence.saveConfiguration(cfg)
        let loaded = try await persistence.loadConfiguration()
        XCTAssertEqual(loaded?.defaultModelName, "gpt-test")
        XCTAssertEqual(loaded?.fontSize, 20)
    }
}

final class ToolsDefinitionTests: XCTestCase {
    func testAllFilesystemToolsPresent() async throws {
        let ws = try IOSWorkspace(rootName: "tools_test_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let exec = FileSystemToolExecutor(workspace: ws)
        let names = await exec.availableTools.map { $0.name }.sorted()
        let expected = ["create_directory","delete_file","edit_file","file_info","list_directory","move_file","read_file","search_files","write_file"]
        XCTAssertEqual(names, expected)
    }

    func testWriteFileIsMarkedDestructive() async throws {
        let ws = try IOSWorkspace(rootName: "destructive_test_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let exec = FileSystemToolExecutor(workspace: ws)
        let write = await exec.availableTools.first { $0.name == "write_file" }
        XCTAssertTrue(write?.capabilities.isDestructive ?? false)
    }

    func testRecursiveDeleteRemovesNestedTree() async throws {
        let ws = try IOSWorkspace(rootName: "recursive_delete_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try await ws.createDirectory(at: "a")
        try await ws.createDirectory(at: "a/b")
        try await ws.writeFile(at: "a/b/file.txt", data: Data("x".utf8))

        let exec = FileSystemToolExecutor(workspace: ws)
        let result = await exec.execute(ToolInvocation(
            name: "delete_file",
            arguments: ["path": "a", "recursive": "true"]
        ))

        XCTAssertNil(result.error)
        let exists = await ws.fileExists(at: "a")
        XCTAssertFalse(exists)
    }
}

/// End-to-end: AgentLoop con ScriptedModelProvider sobre workspace sandbox real.
/// Verifica el flujo agente → tools → workspace → resultado sin red.
final class AgentEndToEndTests: XCTestCase {
    func testScriptedAgentRunsFullFlowAndWritesWorkspace() async throws {
        let rootName = "e2e_\(UUID().uuidString)"
        let ws = try IOSWorkspace(rootName: rootName)
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Workspace de persisted: usamos un persistence dedicado
        let ps = try IOSPersistence()
        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        let exec = FileSystemToolExecutor(workspace: ws)
        let ctx = AgentContext(
            conversationId: UUID().uuidString,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            toolExecutor: exec,
            systemPrompt: "test",
            maxTurns: 15,
            permissionHandler: { request in
                PermissionResponse(requestId: request.id, decision: .allowAlways)
            }
        )
        let loop = AgentLoop(context: ctx)

        var events: [AgentLoopEvent] = []
        await loop.setEventHandler { events.append($0) }

        let final = try await loop.run(userInput: "demo list-read-write-verify")

        XCTAssertFalse(final.isEmpty)
        // El script debe haber emitido tool results sin error (write_file, read_file, list_directory)
        let toolResults = events.compactMap { event -> ToolExecutionResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertFalse(toolResults.isEmpty)
        XCTAssertTrue(toolResults.allSatisfy { $0.error == nil }, "alguna tool falló: \(toolResults)")
        let permissionRequests = events.compactMap { event -> PermissionRequest? in
            if case .permissionRequested(let request) = event { return request } else { return nil }
        }
        XCTAssertEqual(permissionRequests.count, 1, "allowAlways debe evitar repetir el permiso para write_file")
        // El archivo notes.txt debe existir y tener 2 líneas al final.
        let exists = await ws.fileExists(at: "notes.txt")
        XCTAssertTrue(exists, "notes.txt no creado por el agente")
        let data = try await ws.readFile(at: "notes.txt")
        let content = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(content.split(separator: "\n", omittingEmptySubsequences: true).count, 2)
    }

    func testDestructiveToolsFailClosedWithoutPermissionHandler() async throws {
        let rootName = "e2e_fail_closed_\(UUID().uuidString)"
        let ws = try IOSWorkspace(rootName: rootName)
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let ps = try IOSPersistence()
        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        let exec = FileSystemToolExecutor(workspace: ws)
        let ctx = AgentContext(
            conversationId: UUID().uuidString,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            toolExecutor: exec,
            systemPrompt: "test",
            maxTurns: 15
        )
        let loop = AgentLoop(context: ctx)

        var denied = false
        await loop.setEventHandler { event in
            if case .toolResult(let result) = event,
               result.error?.contains("Permission required") == true {
                denied = true
            }
        }

        _ = try await loop.run(userInput: "demo")
        XCTAssertTrue(denied)
        let fileExistsWithoutHandler = await ws.fileExists(at: "notes.txt")
        XCTAssertFalse(fileExistsWithoutHandler, "a missing approval handler must not mutate files")
    }

    func testDeniedApprovalLeavesWorkspaceUnchanged() async throws {
        let rootName = "e2e_denied_\(UUID().uuidString)"
        let ws = try IOSWorkspace(rootName: rootName)
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        let exec = FileSystemToolExecutor(workspace: ws)
        let ctx = AgentContext(
            conversationId: UUID().uuidString,
            workspace: ws,
            persistence: try IOSPersistence(),
            modelProvider: provider,
            toolExecutor: exec,
            systemPrompt: "test",
            maxTurns: 15,
            permissionHandler: { request in
                PermissionResponse(requestId: request.id, decision: .deny)
            }
        )
        let loop = AgentLoop(context: ctx)
        var asked = 0
        await loop.setEventHandler { event in
            if case .permissionRequested = event { asked += 1 }
        }

        _ = try await loop.run(userInput: "write a disposable note")

        XCTAssertGreaterThan(asked, 0)
        let fileExistsAfterDenial = await ws.fileExists(at: "notes.txt")
        XCTAssertFalse(fileExistsAfterDenial, "denial must leave the workspace unchanged")
    }
    func testConversationContinuesAcrossMultipleUserPrompts() async throws {
        let rootName = "e2e_continuity_\(UUID().uuidString)"
        let ws = try IOSWorkspace(rootName: rootName)
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let ps = try IOSPersistence()
        let conversationId = UUID().uuidString
        let provider = ScriptedModelProvider(scriptResponses: ["first response", "second response"])
        let exec = FileSystemToolExecutor(workspace: ws)
        let ctx = AgentContext(
            conversationId: conversationId,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            toolExecutor: exec,
            systemPrompt: "test",
            maxTurns: 2
        )
        let loop = AgentLoop(context: ctx)

        _ = try await loop.run(userInput: "first prompt")
        _ = try await loop.run(userInput: "second prompt")

        let saved = try await ps.loadConversation(id: conversationId)
        let userMessages = saved?.messages.filter { $0.role == .user }.map { $0.content } ?? []
        XCTAssertEqual(userMessages, ["first prompt", "second prompt"])
    }

}

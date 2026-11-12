import XCTest
@testable import IysCodeMovilCore

private actor GrammarCaptureEngine: LocalInferenceEngine {
    private(set) var grammars: [String?] = []
    private let failOnGrammar: Bool

    init(failOnGrammar: Bool = false) { self.failOnGrammar = failOnGrammar }
    func load(modelURL: URL, contextTokens: Int) async throws {}
    func unload() async {}
    func cancel() async {}
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String { "ok" }
    func generateMeasured(messages: [ModelMessage], options: GenerationOptions, grammar: String?) async throws -> LocalGeneration {
        grammars.append(grammar)
        if failOnGrammar, grammar != nil {
            throw ModelProviderError.invalidRequest("The tool grammar could not be parsed.")
        }
        return try await generateMeasured(messages: messages, options: options)
    }
}

private func definitions(_ tools: [AgentTool]) -> [ToolDefinition] {
    tools.map { tool in
        ToolDefinition(
            name: tool.name,
            description: tool.description,
            parameters: .init(
                properties: tool.parameters.properties.mapValues {
                    .init(type: $0.type, description: $0.description, enumValues: $0.enumValues)
                },
                required: tool.parameters.required
            )
        )
    }
}

final class PhoneSandboxTests: XCTestCase {
    // MARK: - Grammar

    /// Must stay identical to scripts/gus_catalog/tool_grammar.gbnf, which CI checks
    /// against every llama.cpp tokenizer with the real bridge.
    private let simpleToolGrammar = #"""
root ::= ws think? (call | answer)
ws ::= [ \t\n]{0,4}
think ::= "<think>" ([^<] | "<" [^/])* "</think>" ws
answer ::= [^< \t\n] [^\x00]*
call ::= "<GUS_TOOL_CALL>" (t0 | t1 | t2 | t3 | t4 | t5 | t6) "</GUS_TOOL_CALL>"
t0 ::= "{\"name\":\"clone\",\"arguments\":{" "\"repo\":" string "}}"
t1 ::= "{\"name\":\"list\",\"arguments\":{" ("\"path\":" string)? "}}"
t2 ::= "{\"name\":\"read\",\"arguments\":{" "\"path\":" string ("," "\"from_line\":" integer)? "}}"
t3 ::= "{\"name\":\"find\",\"arguments\":{" "\"text\":" string "}}"
t4 ::= "{\"name\":\"edit\",\"arguments\":{" "\"path\":" string "," "\"old_text\":" string "," "\"new_text\":" string "}}"
t5 ::= "{\"name\":\"write\",\"arguments\":{" "\"path\":" string "," "\"content\":" string "}}"
t6 ::= "{\"name\":\"undo\",\"arguments\":{" "}}"
string ::= "\"" char* "\""
char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
hex ::= [0-9a-fA-F]
integer ::= "-"? [0-9]+
number ::= "-"? [0-9]+ ("." [0-9]+)?
boolean ::= "true" | "false"

"""#

    func testGrammarForSimpleToolsMatchesTheFixtureCheckedInCI() {
        let grammar = GUSToolCallGrammar.gbnf(for: definitions(SimpleWorkspaceToolExecutor.tools(disposable: true)))
        XCTAssertEqual(grammar, simpleToolGrammar)
    }

    func testGrammarOrdersArgumentsAndRestrictsEnumsAndTypes() throws {
        let tool = ToolDefinition(name: "demo", description: "", parameters: .init(
            properties: [
                "zeta": .init(type: "boolean", description: nil, enumValues: nil),
                "alpha": .init(type: "number", description: nil, enumValues: nil),
                "path": .init(type: "string", description: nil, enumValues: nil),
                "mode": .init(type: "string", description: nil, enumValues: ["fast", "slow"])
            ],
            required: ["path", "mode"]
        ))
        let grammar = try XCTUnwrap(GUSToolCallGrammar.gbnf(for: [tool]))
        XCTAssertTrue(grammar.contains(
            #"t0 ::= "{\"name\":\"demo\",\"arguments\":{" "\"path\":" string "," "\"mode\":" ("\"fast\"" | "\"slow\"") ("," "\"alpha\":" number)? ("," "\"zeta\":" boolean)? "}}""#
        ))
        let order = GUSToolCallGrammar.orderedArguments(for: tool)
        XCTAssertEqual(order.required, ["path", "mode"])
        XCTAssertEqual(order.optional, ["alpha", "zeta"])
    }

    func testGrammarLetsAnyOptionalArgumentComeFirstWhenNoneIsRequired() throws {
        let tool = ToolDefinition(name: "opt", description: "", parameters: .init(
            properties: [
                "a": .init(type: "string", description: nil, enumValues: nil),
                "b": .init(type: "integer", description: nil, enumValues: nil)
            ],
            required: []
        ))
        let grammar = try XCTUnwrap(GUSToolCallGrammar.gbnf(for: [tool]))
        XCTAssertTrue(grammar.contains(#"("\"a\":" string ("," "\"b\":" integer)? | "\"b\":" integer)? "}}""#))
        XCTAssertNil(GUSToolCallGrammar.gbnf(for: []))
    }

    func testLocalProviderConstrainsOnlyTurnsThatHaveTools() async throws {
        let engine = GrammarCaptureEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/model.gguf"), engine: engine)
        let tools = definitions(SimpleWorkspaceToolExecutor.tools(disposable: true))
        _ = try await provider.generate(messages: [ModelMessage(role: .user, content: "hola")], tools: tools, options: GenerationOptions(maxTokens: 16))
        _ = try await provider.generate(messages: [ModelMessage(role: .user, content: "hola")], tools: nil, options: GenerationOptions(maxTokens: 16))
        let grammars = await engine.grammars
        XCTAssertEqual(grammars.count, 2)
        XCTAssertEqual(grammars[0], simpleToolGrammar)
        XCTAssertNil(grammars[1])
    }

    func testLocalProviderFallsBackWhenTheRuntimeRejectsTheGrammar() async throws {
        let engine = GrammarCaptureEngine(failOnGrammar: true)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/model.gguf"), engine: engine)
        let tools = definitions(SimpleWorkspaceToolExecutor.tools(disposable: true))
        let response = try await provider.generate(messages: [ModelMessage(role: .user, content: "hola")], tools: tools, options: GenerationOptions(maxTokens: 16))
        XCTAssertEqual(response.content, "ok")
        let grammars = await engine.grammars
        XCTAssertEqual(grammars.count, 2)
        XCTAssertNotNil(grammars[0])
        XCTAssertNil(grammars[1])
    }

    // MARK: - Repository archive

    private func tarEntry(_ name: String, type: Character = "0", body: String = "", prefix: String = "") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            let bytes = Array(text.utf8.prefix(length))
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        let payload = Data(body.utf8)
        put(name, at: 0, length: 100)
        put(String(payload.count, radix: 8), at: 124, length: 11)
        header[156] = type.asciiValue ?? 48
        put("ustar", at: 257, length: 5)
        put(prefix, at: 345, length: 155)
        var entry = Data(header)
        entry.append(payload)
        entry.append(Data(repeating: 0, count: (512 - payload.count % 512) % 512))
        return entry
    }

    private func gzip(_ data: Data) throws -> Data {
        var wrapped = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        wrapped.append(try (data as NSData).compressed(using: .zlib) as Data)
        wrapped.append(Data(repeating: 0, count: 8))
        return wrapped
    }

    private func sampleArchive() throws -> Data {
        var tar = Data()
        tar.append(tarEntry("pax_global_header", type: "g", body: "52 comment=abc\n"))
        tar.append(tarEntry("me-app-abc123/", type: "5"))
        tar.append(tarEntry("me-app-abc123/README.md", body: "# app\n"))
        tar.append(tarEntry("me-app-abc123/src/", type: "5"))
        tar.append(tarEntry("main.py", body: "print(\"hola\")\n", prefix: "me-app-abc123/src"))
        tar.append(tarEntry("me-app-abc123/link", type: "2"))
        tar.append(tarEntry("me-app-abc123/../../escape.txt", body: "x"))
        tar.append(tarEntry("ignored", type: "x", body: "40 path=me-app-abc123/docs/long name.md\n"))
        tar.append(tarEntry("me-app-abc123/short", body: "largo\n"))
        tar.append(Data(repeating: 0, count: 1024))
        return try gzip(tar)
    }

    func testArchiveStripsTheTopFolderAndSkipsLinksAndEscapes() throws {
        let contents = try RepositoryArchive.read(gzip: sampleArchive())
        XCTAssertEqual(contents.entries.map(\.path), ["README.md", "src", "src/main.py", "docs/long name.md"])
        XCTAssertEqual(contents.entries.map(\.isDirectory), [false, true, false, false])
        XCTAssertEqual(String(decoding: contents.entries[2].data, as: UTF8.self), "print(\"hola\")\n")
        XCTAssertEqual(String(decoding: contents.entries[3].data, as: UTF8.self), "largo\n")
        XCTAssertEqual(contents.skipped, ["link", "me-app-abc123/../../escape.txt"])
    }

    func testArchiveRejectsWhatIsNotATarball() {
        XCTAssertThrowsError(try RepositoryArchive.read(gzip: Data("{\"message\":\"Not Found\"}".utf8))) { error in
            XCTAssertEqual(error as? RepositoryArchiveError, .notGzip)
        }
        XCTAssertNil(RepositoryArchive.repositoryPath("/etc/passwd"))
        XCTAssertNil(RepositoryArchive.repositoryPath("top/../x"))
        XCTAssertNil(RepositoryArchive.repositoryPath("top"))
        XCTAssertEqual(RepositoryArchive.repositoryPath("top/a/b.txt"), "a/b.txt")
    }

    func testRepositoryReferenceAcceptsOnlyGitHubShapes() throws {
        let plain = try XCTUnwrap(GitHubRepositoryReference.parse("octocat/Hello-World"))
        XCTAssertEqual(plain.fullName, "octocat/Hello-World")
        XCTAssertEqual(plain.directory, "repos/octocat-Hello-World")
        XCTAssertEqual(plain.tarballURL?.absoluteString, "https://api.github.com/repos/octocat/Hello-World/tarball")

        let url = try XCTUnwrap(GitHubRepositoryReference.parse(" https://github.com/DannyBaanks/MovilClaw.git "))
        XCTAssertEqual(url.fullName, "DannyBaanks/MovilClaw")
        XCTAssertEqual(GitHubRepositoryReference.parse("git@github.com:a/b.git")?.fullName, "a/b")

        let branch = try XCTUnwrap(GitHubRepositoryReference.parse("https://github.com/a/b/tree/feature/x"))
        XCTAssertEqual(branch.ref, "feature/x")
        XCTAssertEqual(branch.tarballURL?.absoluteString, "https://api.github.com/repos/a/b/tarball/feature/x")
        XCTAssertEqual(GitHubRepositoryReference.parse("a/b@v1.2")?.ref, "v1.2")

        for bad in ["", "solo", "a/b/c", "../x/y", "a/b@../../x", "https://gitlab.com/a/b", "a b/c", "a/b@-rf"] {
            XCTAssertNil(GitHubRepositoryReference.parse(bad), bad)
        }
    }

    // MARK: - Simple tools

    func testEditPrefersAnExactUniqueMatch() throws {
        let outcome = try SimpleWorkspaceToolExecutor.applyEdit(to: "a = 1\nb = 2\n", oldText: "b = 2", newText: "b = 3", path: "x.py")
        XCTAssertEqual(outcome, .init(text: "a = 1\nb = 3\n", firstLine: 2, wasTolerant: false))
    }

    func testEditToleratesWhitespaceAndKeepsIndentation() throws {
        let original = "def f():\n\tif x:\n\t\treturn 1\n\treturn 0\n"
        let outcome = try SimpleWorkspaceToolExecutor.applyEdit(
            to: original, oldText: "  if x:\n    return 1  \n", newText: "if x:\n    return 2", path: "x.py"
        )
        XCTAssertTrue(outcome.wasTolerant)
        XCTAssertEqual(outcome.firstLine, 2)
        // The block is shifted to where it belongs and keeps its own inner indentation.
        XCTAssertEqual(outcome.text, "def f():\n\tif x:\n\t    return 2\n\treturn 0\n")

        let flat = try SimpleWorkspaceToolExecutor.applyEdit(to: original, oldText: "return 0", newText: "return -1", path: "x.py")
        XCTAssertFalse(flat.wasTolerant)
        XCTAssertEqual(flat.text, "def f():\n\tif x:\n\t\treturn 1\n\treturn -1\n")

        let reindented = try SimpleWorkspaceToolExecutor.applyEdit(to: "{\n    a();\n    b();\n}\n", oldText: "a();\nb();", newText: "c();", path: "x.js")
        XCTAssertEqual(reindented.text, "{\n    c();\n}\n")
    }

    func testEditErrorsSayWhatToDoNext() {
        XCTAssertThrowsError(try SimpleWorkspaceToolExecutor.applyEdit(to: "x\nx\n", oldText: "x", newText: "y", path: "a.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 veces"))
        }
        XCTAssertThrowsError(try SimpleWorkspaceToolExecutor.applyEdit(to: "let total = 1\n", oldText: "total = 2", newText: "y", path: "a.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("read"))
        }
    }

    func testReadWindowNumbersLinesAndSaysHowToContinue() {
        let text = (1...200).map { "linea \($0)" }.joined(separator: "\n") + "\n"
        let first = SimpleWorkspaceToolExecutor.numberedWindow(of: text, fromLine: 1, path: "a.txt")
        XCTAssertTrue(first.hasPrefix("1: linea 1\n2: linea 2\n"))
        XCTAssertTrue(first.hasSuffix("[líneas 1-80 de 200. Para seguir usa read con from_line=81]"))
        let last = SimpleWorkspaceToolExecutor.numberedWindow(of: text, fromLine: 161, path: "a.txt")
        XCTAssertTrue(last.hasSuffix("200: linea 200\n[líneas 161-200 de 200. Fin del archivo]"))
        XCTAssertEqual(SimpleWorkspaceToolExecutor.numberedWindow(of: "", fromLine: 1, path: "a.txt"), "a.txt está vacío.")
    }

    func testPathsCannotLeaveTheScope() throws {
        XCTAssertEqual(try SimpleWorkspaceToolExecutor.cleanPath(" ./src//app.js "), "src/app.js")
        XCTAssertEqual(try SimpleWorkspaceToolExecutor.cleanPath("", allowEmpty: true), "")
        for bad in ["../x", "a/../../x", "/etc/passwd", "~/x", "a\\b", ""] {
            XCTAssertThrowsError(try SimpleWorkspaceToolExecutor.cleanPath(bad), bad)
        }
        XCTAssertEqual(SimpleWorkspaceToolExecutor.join("repos/a-b", "src/x"), "repos/a-b/src/x")
        XCTAssertEqual(SimpleWorkspaceToolExecutor.join(nil, "src/x"), "src/x")
    }

    private func makeExecutor() throws -> (SimpleWorkspaceToolExecutor, IOSWorkspace, UserDefaults, String) {
        let suite = "PhoneSandboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = try IOSWorkspace(rootName: "phone_sandbox_\(UUID().uuidString)")
        let archive = try sampleArchive()
        let cloner = RepositoryCloner { _ in (archive, 200) }
        return (SimpleWorkspaceToolExecutor(workspace: workspace, defaults: defaults, cloner: cloner), workspace, defaults, suite)
    }

    func testCloneScopesToolsToADisposableCopyWithUndo() async throws {
        let (executor, workspace, defaults, suite) = try makeExecutor()
        let root = await workspace.rootURL
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        // Without a project, a change needs approval.
        let denied = await executor.execute(ToolInvocation(name: "write", arguments: ["path": "n.txt", "content": "x"]), approval: nil)
        XCTAssertNotNil(denied.error)
        let beforeClone = await executor.tools()
        XCTAssertTrue(beforeClone.first { $0.name == "edit" }?.capabilities.isDestructive == true)

        let cloned = await executor.execute(ToolInvocation(name: "clone", arguments: ["repo": "me/app"]), approval: nil)
        XCTAssertNil(cloned.error)
        XCTAssertTrue(cloned.output.contains("Clonado me/app: 3 archivos."))
        XCTAssertTrue(cloned.output.contains("src/"))
        let project = await executor.activeProject()
        XCTAssertEqual(project, "repos/me-app")
        let afterClone = await executor.tools()
        XCTAssertTrue(afterClone.allSatisfy { !$0.capabilities.isDestructive })

        // Paths are relative to the clone, and edits apply without approval.
        let read = await executor.execute(ToolInvocation(name: "read", arguments: ["path": "src/main.py"]), approval: nil)
        XCTAssertTrue(read.output.hasPrefix("1: print(\"hola\")"))
        let edited = await executor.execute(ToolInvocation(name: "edit", arguments: [
            "path": "src/main.py", "old_text": "print(\"hola\")", "new_text": "print(\"adiós\")"
        ]), approval: nil)
        XCTAssertNil(edited.error)
        let changed = try await workspace.readFile(at: "repos/me-app/src/main.py")
        XCTAssertEqual(String(decoding: changed, as: UTF8.self), "print(\"adiós\")\n")

        let found = await executor.execute(ToolInvocation(name: "find", arguments: ["text": "adiós"]), approval: nil)
        XCTAssertEqual(found.output, "src/main.py:1: print(\"adiós\")")

        let created = await executor.execute(ToolInvocation(name: "write", arguments: ["path": "notas.txt", "content": "uno\ndos"]), approval: nil)
        XCTAssertTrue(created.output.hasPrefix("Creado notas.txt (2 líneas)"))

        // Undo walks back: first the new file, then the edit.
        _ = await executor.execute(ToolInvocation(name: "undo", arguments: [:]), approval: nil)
        let stillThere = await workspace.fileExists(at: "repos/me-app/notas.txt")
        XCTAssertFalse(stillThere)
        _ = await executor.execute(ToolInvocation(name: "undo", arguments: [:]), approval: nil)
        let restored = try await workspace.readFile(at: "repos/me-app/src/main.py")
        XCTAssertEqual(String(decoding: restored, as: UTF8.self), "print(\"hola\")\n")
        let nothingLeft = await executor.execute(ToolInvocation(name: "undo", arguments: [:]), approval: nil)
        XCTAssertNotNil(nothingLeft.error)

        // The scope cannot be escaped, and a second clone never overwrites the first.
        let escape = await executor.execute(ToolInvocation(name: "read", arguments: ["path": "../../secret"]), approval: nil)
        XCTAssertNotNil(escape.error)
        let again = await executor.execute(ToolInvocation(name: "clone", arguments: ["repo": "me/app"]), approval: nil)
        XCTAssertTrue(again.error?.contains("ya está clonado") == true)
    }

    func testCloneReportsGitHubFailuresInWords() async throws {
        let workspace = try IOSWorkspace(rootName: "phone_sandbox_\(UUID().uuidString)")
        let root = await workspace.rootURL
        defer { try? FileManager.default.removeItem(at: root) }
        for (status, expected) in [(404, RepositoryCloner.CloneError.notFound("me/app")), (403, .rateLimited)] {
            do {
                _ = try await RepositoryCloner { _ in (Data(), status) }.clone("me/app", into: workspace)
                XCTFail("expected a failure for \(status)")
            } catch {
                XCTAssertEqual(error as? RepositoryCloner.CloneError, expected)
            }
        }
        do {
            _ = try await RepositoryCloner { _ in (Data(), 200) }.clone("not a repo", into: workspace)
            XCTFail("expected an invalid reference")
        } catch {
            XCTAssertEqual(error as? RepositoryCloner.CloneError, .invalidReference)
        }
    }

    func testLocalModelsGetTheSimpleSurfaceAndCloudModelsKeepTheFullOne() async throws {
        let suite = "PhoneSandboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = try IOSWorkspace(rootName: "phone_sandbox_\(UUID().uuidString)")
        let root = await workspace.rootURL
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = NativeCapabilityToolExecutor(workspace: workspace, defaults: defaults)
        let message = [ModelMessage(role: .user, content: "arregla el bug")]

        await executor.configureSharedMemory(localOnly: true, conversationID: "c")
        let local = await executor.tools(relevantTo: message).map(\.name)
        XCTAssertEqual(Array(local.prefix(7)), ["clone", "list", "read", "find", "edit", "write", "undo"])
        XCTAssertFalse(local.contains("read_file"))

        await executor.configureSharedMemory(localOnly: false, conversationID: "c")
        let cloud = await executor.tools(relevantTo: message).map(\.name)
        XCTAssertTrue(cloud.contains("read_file"))
        XCTAssertTrue(cloud.contains("clone"))
        XCTAssertFalse(cloud.contains("undo"))
    }
}

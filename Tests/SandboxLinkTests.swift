import XCTest
@testable import IysCodeMovilCore

final class SandboxLinkTests: XCTestCase {
    private let token = String(repeating: "t", count: 43)

    func testParsesSandboxPairingLink() throws {
        let link = "isysandbox://pair?host=100.101.102.103&port=8788&token=\(token)&directory=%2Fhome%2Fme%2FISyCo%20Git%2Fapp"
        let pairing = try SandboxPairing.parse(link)
        XCTAssertEqual(pairing.host, "100.101.102.103")
        XCTAssertEqual(pairing.port, 8788)
        XCTAssertEqual(pairing.token, token)
        XCTAssertEqual(pairing.directory, "/home/me/ISyCo Git/app")
        XCTAssertEqual(pairing.projectName, "app")
        XCTAssertEqual(pairing.baseURL.absoluteString, "http://100.101.102.103:8788")
    }

    func testRecognisesSandboxLinksBeforeOtherBackends() {
        XCTAssertTrue(SandboxPairing.isPairingLink("  isysandbox://pair?host=100.64.0.1 "))
        XCTAssertFalse(SandboxPairing.isPairingLink("grok://pair?host=100.64.0.1"))
        XCTAssertFalse(SandboxPairing.isPairingLink("iyscodemovil://pair?host=10.0.0.2"))
    }

    func testRejectsHostsOutsideTheTailnet() {
        for host in ["192.168.1.20", "10.0.0.5", "example.com", "100.63.0.1", "100.128.0.1", "0.0.0.0"] {
            XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?host=\(host)&port=8788&token=\(token)&directory=%2Fp"), host)
        }
        XCTAssertNoThrow(try SandboxPairing.parse("isysandbox://pair?host=127.0.0.1&port=8788&token=\(token)&directory=%2Fp"))
    }

    func testRejectsMalformedLinks() {
        let base = "host=100.101.102.103&port=8788&directory=%2Fp"
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?\(base)&token=short"))
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?\(base)"))
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?\(base)&token=\(token)&token=\(token)"))
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?\(base)&token=\(token)&extra=1"))
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://other?\(base)&token=\(token)"))
        XCTAssertThrowsError(try SandboxPairing.parse("grok://pair?\(base)&token=\(token)"))
        XCTAssertThrowsError(try SandboxPairing.parse("isysandbox://pair?host=100.101.102.103&port=0&token=\(token)&directory=%2Fp"))
    }

    func testListingBecomesSortedFileNodes() {
        let listing = """
        total 20
        drwxr-xr-x  5 sandbox sandbox 4096 Nov 12 07:31 .
        drwxr-xr-x 16 sandbox sandbox 4096 Nov 12 07:17 ..
        -rw-r--r--  1 sandbox sandbox  549 Nov 12 07:17 package.json
        drwxr-xr-x  2 sandbox sandbox 4096 Nov 12 07:32 bin
        -rw-r--r--  1 sandbox sandbox   12 Nov 12 07:17 My Notes.txt
        lrwxrwxrwx  1 sandbox sandbox    7 Nov 12 07:17 latest -> bin/run
        """
        let nodes = SandboxToolExecutor.fileNodes(fromListing: listing, directory: "Bridge")
        XCTAssertEqual(nodes.map(\.name), ["bin", "latest", "My Notes.txt", "package.json"])
        XCTAssertEqual(nodes.map(\.path), ["Bridge/bin", "Bridge/latest", "Bridge/My Notes.txt", "Bridge/package.json"])
        XCTAssertEqual(nodes.map(\.isDirectory), [true, false, false, false])
        XCTAssertEqual(nodes.last?.size, 549)

        let root = SandboxToolExecutor.fileNodes(fromListing: listing, directory: "")
        XCTAssertEqual(root.first?.path, "bin")
    }

    func testToolOutputHelpers() {
        XCTAssertEqual(
            SandboxToolExecutor.relativeMatches("/work/app/src/a.js:3:hola\n/work/app/b.js:1:hola"),
            "src/a.js:3:hola\nb.js:1:hola"
        )
        XCTAssertEqual(
            SandboxToolExecutor.commandReport(["code": 1, "out": "2 passed", "err": "1 failed"]),
            "código de salida: 1\n2 passed\nstderr:\n1 failed"
        )
        XCTAssertEqual(SandboxToolExecutor.commandReport(["code": 0, "out": "", "err": ""]), "código de salida: 0")

        let long = String(repeating: "x", count: SandboxToolExecutor.maxOutputCharacters + 25)
        let clipped = SandboxToolExecutor.clipped(long)
        XCTAssertTrue(clipped.hasSuffix("[salida recortada: 25 caracteres más]"))
        XCTAssertEqual(SandboxToolExecutor.clipped("corto"), "corto")

        XCTAssertThrowsError(try SandboxToolExecutor.required("path", in: ["path": ""]))
        XCTAssertEqual(try SandboxToolExecutor.required("path", in: ["path": "a.txt"]), "a.txt")
    }

    func testPullRequestToolNeedsAccountAndRepository() throws {
        let pairing = try SandboxPairing(host: "100.101.102.103", port: 8788, token: token, directory: "/p")
        let client = SandboxHostClient(pairing: pairing)
        func toolNames(repo: String?, account: Bool) -> [String] {
            let info = SandboxBridgeInfo(projectName: "p", repo: repo, defaultBranch: "main", hasGitHubAccount: account)
            return SandboxToolExecutor(client: client, sandboxID: "mc-abcdef", info: info).availableTools.map(\.name)
        }
        XCTAssertTrue(toolNames(repo: "me/p", account: true).contains("open_pull_request"))
        XCTAssertFalse(toolNames(repo: nil, account: true).contains("open_pull_request"))
        XCTAssertFalse(toolNames(repo: "me/p", account: false).contains("open_pull_request"))

        let info = SandboxBridgeInfo(projectName: "p", repo: "me/p", defaultBranch: "main", hasGitHubAccount: true)
        let tools = SandboxToolExecutor(client: client, sandboxID: "mc-abcdef", info: info).availableTools
        let publish = try XCTUnwrap(tools.first { $0.name == "open_pull_request" })
        XCTAssertTrue(publish.capabilities.isDestructive)
        XCTAssertTrue(publish.capabilities.requiresApprovalEveryTime)
        // Work inside the disposable sandbox does not interrupt the person for approval.
        XCTAssertTrue(tools.filter { $0.name != "open_pull_request" }.allSatisfy { !$0.capabilities.isDestructive })
    }

    func testRemainingLabel() {
        var link = SandboxLinkState(
            projectName: "p", directory: "/p", repo: "me/p", defaultBranch: "main", hasGitHubAccount: true,
            sandboxID: "mc-abcdef", phase: "active", remainingMs: 80 * 60_000, explanation: "",
            excludedFiles: [], lastPullRequest: nil
        )
        XCTAssertEqual(link.remainingLabel, "1 h 20 min")
        link.remainingMs = 120 * 60_000
        XCTAssertEqual(link.remainingLabel, "2 h")
        link.remainingMs = 11.2 * 60_000
        XCTAssertEqual(link.remainingLabel, "12 min")
        link.phase = "suspended"
        XCTAssertNil(link.remainingLabel)
        XCTAssertEqual(link.phaseLabel, "En pausa")
        XCTAssertTrue(link.canOpenPullRequest)
        link.repo = nil
        XCTAssertFalse(link.canOpenPullRequest)
    }

    func testConversationExportKeepsMessagesAndToolNames() {
        let events: [TimelineEvent] = [
            .system("conectado"),
            .userPrompt("Arregla el test", agentMode: .build),
            .toolCall(name: "run_command", arguments: ["command": "npm test"], agentMode: .build),
            .assistantText("Listo, pasan los 3.", agentMode: .build)
        ]
        let markdown = ConversationExport.markdown(title: "Arreglar test", project: "app · sandbox", events: events)
        XCTAssertTrue(markdown.hasPrefix("# Arreglar test\n_Proyecto: app · sandbox_\n"))
        XCTAssertTrue(markdown.contains("## Tú\nArregla el test"))
        XCTAssertTrue(markdown.contains("- `run_command` command=npm test"))
        XCTAssertTrue(markdown.contains("## Asistente\nListo, pasan los 3."))
        XCTAssertFalse(markdown.contains("conectado"))
    }
}

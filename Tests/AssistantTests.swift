import XCTest
@testable import IysCodeMovilCore

/// Mirrors android/.../AssistantTest.kt so both apps agree on the same rules.
final class AssistantTests: XCTestCase {
    private let nodes = [
        ContextNode(id: "a", title: "Paridad Swift y Kotlin", summary: "El modo oscuro automático debe funcionar igual en iPhone y Android",
                    path: ["Ingeniería", "Apps móviles", "Swift y Kotlin"], priority: .critical),
        ContextNode(id: "b", title: "Juntas de equipo", summary: "Las reuniones de equipo se agendan en bloques de 45 minutos en el calendario",
                    path: ["Google y vida diaria", "Comunicación y agenda", "Correo y calendario"], priority: .high),
        ContextNode(id: "c", title: "Café para trabajar", summary: "Prefiero cafeterías con buen wifi cerca de Reforma",
                    path: ["Lugares", "Ubicaciones y rutas", "Sitios guardados"]),
        ContextNode(id: "d", title: "Correos del equipo", summary: "Los correos al equipo van con resumen de reuniones y calendario semanal",
                    path: ["Google y vida diaria", "Documentos y pendientes", "Drive, Docs y Tasks"]),
    ]

    func testPathsAreThreeLevelsAndIgnoreAccents() {
        XCTAssertEqual(SemanticContext.inferPath("Agenda una reunión con el equipo"),
                       ["Google y vida diaria", "Comunicación y agenda", "Correo y calendario"])
        XCTAssertEqual(SemanticContext.inferPath("Compila la app de iOS"), ["Ingeniería", "Apps móviles", "Swift y Kotlin"])
        XCTAssertEqual(SemanticContext.inferPath("Busca un café cerca"), ["Lugares", "Ubicaciones y rutas", "Sitios guardados"])
        XCTAssertEqual(SemanticContext.inferPath("un programa de radio"), SemanticContext.defaultPath)
        XCTAssertEqual(SemanticContext.cleanPath([" A ", "", "B", "C", "D"]), ["A", "B", "C"])
    }

    func testTreeAndRetrieval() {
        let google = SemanticContext.buildTree(nodes).first { $0.name == "Google y vida diaria" }!
        XCTAssertEqual(google.totalNodes, 2)
        XCTAssertEqual(google.subfolders.count, 2)
        let result = SemanticContext.retrieve(nodes, prompt: "¿Cuándo es la reunión del equipo en el calendario?", priority: false)
        XCTAssertEqual(result.nodes.first?.id, "b")
        XCTAssertTrue(result.nodes.contains { $0.id == "d" })
        XCTAssertLessThanOrEqual(result.nodes.count, 3)
        XCTAssertTrue(SemanticContext.retrieve(nodes, prompt: "¿Cuándo es la reunión del equipo?", priority: true).nodes.contains { $0.id == "a" })
        XCTAssertNil(SemanticContext.promptContext([], prompt: "hola", priority: false))
        XCTAssertTrue(SemanticContext.promptContext(nodes, prompt: "reunión de equipo", priority: false)?.hasPrefix("MEMORIA DEL USUARIO") ?? false)
    }

    func testFuzzySearch() {
        XCTAssertGreaterThan(SemanticContext.fuzzyScore("Correo y calendario", query: "calndario"), 0)
        XCTAssertGreaterThan(SemanticContext.fuzzyScore("Swift y Kotlin", query: "swft ktln"), 0)
        XCTAssertGreaterThanOrEqual(SemanticContext.fuzzyScore("Reunión", query: "reunion"), 100)
        XCTAssertEqual(SemanticContext.fuzzyScore("Café para trabajar", query: "kotlin"), 0)
        XCTAssertEqual(SemanticContext.fuzzyFilter(nodes, query: "kotln").first?.node.id, "a")
    }

    func testGraphBridgesAndDeterministicLayout() {
        let graph = SemanticContext.buildGraph(nodes)
        XCTAssertEqual(graph.nodes.filter { $0.kind == .domain }.count, 3)
        XCTAssertEqual(graph.nodes.filter { $0.kind == .cluster }.count, 4)
        let bridges = graph.links.filter { $0.kind == .semantic }
        XCTAssertEqual(bridges.count, 1)
        XCTAssertEqual(Set([bridges[0].source, bridges[0].target]), ["b", "d"])
        XCTAssertEqual(SemanticContext.layout(graph), SemanticContext.layout(graph))
        XCTAssertEqual(SemanticContext.layout(graph).count, graph.nodes.count)
    }

    func testCatalogRoutingAndConfirmation() {
        XCTAssertEqual(AssistantCatalog.selectTools("Redacta un correo al equipo").first, "gmail.write.send")
        XCTAssertEqual(AssistantCatalog.selectTools("¿Qué tengo en mi agenda hoy?").first, "googlecalendar.read.events")
        XCTAssertEqual(AssistantCatalog.selectTools("Busca un café cerca de Reforma").first, AssistantCatalog.mapsSearch)
        XCTAssertEqual(AssistantCatalog.selectTools("Recuerda que prefiero reuniones cortas").first, AssistantCatalog.saveContext)
        XCTAssertTrue(AssistantCatalog.selectTools("hola, ¿cómo estás?").isEmpty)
        XCTAssertTrue(AssistantCatalog.requiresConfirmation(["gmail.read.inbox", "gmail.write.send"]))
        XCTAssertFalse(AssistantCatalog.requiresConfirmation(["gmail.read.inbox"]))
        XCTAssertFalse(AssistantCatalog.sections(developerMode: false).contains(.log))
        let ids = AssistantCatalog.tools.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        // Every agent tool is in the catalog, and every write asks each time.
        for definition in AssistantToolExecutor.definitions {
            let info = AssistantCatalog.tool(definition.tool.name)
            XCTAssertNotNil(info, definition.tool.name)
            if info?.mode == .writeConfirmed {
                XCTAssertTrue(definition.tool.capabilities.isDestructive && definition.tool.capabilities.requiresApprovalEveryTime, definition.tool.name)
            }
        }
    }

    func testGmailRawIsHeaderSafe() {
        let raw = AssistantCatalog.encodeGmailRaw(to: "a@b.co\r\nBcc: x@y.z", subject: "Hola ñ", body: "Cuerpo")
        XCTAssertFalse(raw.contains("+") || raw.contains("/") || raw.contains("="))
        var padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let mime = String(data: Data(base64Encoded: padded)!, encoding: .utf8)!
        XCTAssertTrue(mime.hasPrefix("To: a@b.co Bcc: x@y.z\r\n"))
        XCTAssertFalse(mime.contains("\r\nBcc:"))
        XCTAssertTrue(mime.hasSuffix("\r\n\r\nCuerpo"))
        XCTAssertTrue(AssistantCatalog.isPlausibleEmail("ana@empresa.mx"))
        XCTAssertFalse(AssistantCatalog.isPlausibleEmail("a@b.co, c@d.co"))
    }

    func testOAuthPKCEAndTokens() throws {
        XCTAssertEqual(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(GoogleOAuth.redirectURI(clientId: "123-abc.apps.googleusercontent.com"), "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertNil(GoogleOAuth.redirectURI(clientId: "nope"))
        let url = GoogleOAuth.authURL(clientId: "123-abc.apps.googleusercontent.com", redirectURI: "x:/cb",
                                      scopes: GoogleOAuth.scopes([.tasks]), challenge: "CH", state: "ST")!.absoluteString
        XCTAssertTrue(url.contains("code_challenge=CH") && url.contains("code_challenge_method=S256") && url.contains("state=ST"))

        let payload = AssistantCatalog.base64URL(Data(#"{"email":"ana@x.mx"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1000)
        let first = try GoogleOAuth.parseToken(Data(#"{"access_token":"A1","refresh_token":"R1","expires_in":3600,"scope":"email https://www.googleapis.com/auth/tasks","id_token":"h.\#(payload).s"}"#.utf8), now: now)
        XCTAssertEqual(first.email, "ana@x.mx")
        XCTAssertTrue(GoogleService.tasks.isGranted(first.scopes))
        XCTAssertTrue(first.isFresh(at: now))
        let refreshed = try GoogleOAuth.parseToken(Data(#"{"access_token":"A2","expires_in":60}"#.utf8), now: now, previous: first)
        XCTAssertEqual(refreshed.refreshToken, "R1")
        XCTAssertEqual(refreshed.scopes, first.scopes)
        XCTAssertThrowsError(try GoogleOAuth.parseToken(Data(#"{"error":"invalid_grant","error_description":"revoked"}"#.utf8), now: now))
    }

    func testParsersAndManifest() {
        let mail = GoogleParsers.message(Data(#"{"id":"m1","snippet":"Hola","payload":{"headers":[{"name":"From","value":"Ana"},{"name":"subject","value":"Junta"}]}}"#.utf8))
        XCTAssertEqual(mail.subject, "Junta")
        XCTAssertEqual(GoogleParsers.events(Data(#"{"items":[{"id":"e1","start":{"date":"2026-11-20"}}]}"#.utf8)).first?.title, "(sin título)")
        XCTAssertEqual(GoogleParsers.sheetRows(Data(#"{"values":[["a",1],["b"]]}"#.utf8)), [["a", "1"], ["b"]])
        XCTAssertEqual(GoogleParsers.spreadsheetId("https://docs.google.com/spreadsheets/d/1BxiM/edit#gid=0"), "1BxiM")
        XCTAssertEqual(GoogleClient.a1("Mis datos", "A1"), "%27Mis%20datos%27%21A1")

        let tasks = DaemonManifest.parse(Data(#"{"tasks":[{"id":"t1","title":"Build listo"},{"id":"","title":"x"},"texto",{"id":"t2","title":"Correo","summary":"de Ana"}]}"#.utf8))
        XCTAssertEqual(tasks.map(\.id), ["t1", "t2"])
        XCTAssertEqual(tasks[1].body, "de Ana")
        XCTAssertEqual(DaemonManifest.newTasks(seen: ["t1"], incoming: tasks).map(\.id), ["t2"])
        XCTAssertTrue(DaemonManifest.isAllowedURL("https://raw.githubusercontent.com/u/r/main/tareas.json"))
        XCTAssertTrue(DaemonManifest.isAllowedURL("http://192.168.1.20:8787/tareas.json"))
        XCTAssertFalse(DaemonManifest.isAllowedURL("http://example.com/tareas.json"))
    }

    func testMemoryFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memory.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let node = try AssistantMemoryFile.append(title: "", summary: "Prefiero reuniones de 45 minutos",
                                                  path: ["Google y vida diaria", " ", "Agenda"], priority: .high, source: "test", to: url)
        XCTAssertEqual(node.path, ["Google y vida diaria", "Agenda"])
        XCTAssertEqual(AssistantMemoryFile.load(from: url).map(\.id), [node.id])
    }

    func testAgentWritesNeedApproval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memory.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let executor = AssistantToolExecutor(memoryURL: url, grantedScopes: { [] })
        let save = ToolInvocation(name: AssistantCatalog.saveContext, arguments: ["summary": "Uso Kotlin en Android"])
        let denied = await executor.execute(save, approval: nil)
        XCTAssertNotNil(denied.error)
        XCTAssertTrue(AssistantMemoryFile.load(from: url).isEmpty)
        let allowed = await executor.execute(save, approval: .allowOnce)
        XCTAssertNil(allowed.error)
        XCTAssertEqual(AssistantMemoryFile.load(from: url).first?.path, ["Ingeniería", "Apps móviles", "Swift y Kotlin"])
        // Google tools are hidden until the user grants the permission.
        let tools = await executor.tools(relevantTo: [ModelMessage(role: .user, content: "Revisa mi correo")])
        XCTAssertFalse(tools.contains { $0.name.hasPrefix("gmail.") })
        XCTAssertTrue(tools.contains { $0.name == AssistantCatalog.readContext })
        let mail = await executor.execute(ToolInvocation(name: "gmail.read.inbox", arguments: [:]), approval: nil)
        XCTAssertNotNil(mail.error)
    }
}

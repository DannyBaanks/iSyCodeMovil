package dev.iyscode.movil

import dev.iyscode.movil.assistant.AssistantCatalog
import dev.iyscode.movil.assistant.AssistantSection
import dev.iyscode.movil.assistant.ContextNode
import dev.iyscode.movil.assistant.ContextPriority
import dev.iyscode.movil.assistant.DaemonManifest
import dev.iyscode.movil.assistant.DaemonManifestClient
import dev.iyscode.movil.assistant.DaemonTask
import dev.iyscode.movil.assistant.GoogleApiException
import dev.iyscode.movil.assistant.GoogleClient
import dev.iyscode.movil.assistant.GoogleOAuth
import dev.iyscode.movil.assistant.GoogleParsers
import dev.iyscode.movil.assistant.GoogleService
import dev.iyscode.movil.assistant.GoogleToken
import dev.iyscode.movil.assistant.GraphLinkKind
import dev.iyscode.movil.assistant.GraphNodeKind
import dev.iyscode.movil.assistant.ManifestPoll
import dev.iyscode.movil.assistant.MemoryStore
import dev.iyscode.movil.assistant.SemanticContext
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.util.Base64

private fun node(id: String, title: String, summary: String, path: List<String>, priority: ContextPriority = ContextPriority.NORMAL) =
    ContextNode(id, title, summary, path, priority)

class SemanticContextTest {
    private val nodes = listOf(
        node("a", "Paridad Swift y Kotlin", "El modo oscuro automático debe funcionar igual en iPhone y Android",
            listOf("Ingeniería", "Apps móviles", "Swift y Kotlin"), ContextPriority.CRITICAL),
        node("b", "Juntas de equipo", "Las reuniones de equipo se agendan en bloques de 45 minutos en el calendario",
            listOf("Google y vida diaria", "Comunicación y agenda", "Correo y calendario"), ContextPriority.HIGH),
        node("c", "Café para trabajar", "Prefiero cafeterías con buen wifi cerca de Reforma",
            listOf("Lugares", "Ubicaciones y rutas", "Sitios guardados")),
        node("d", "Correos del equipo", "Los correos al equipo van con resumen de reuniones y calendario semanal",
            listOf("Google y vida diaria", "Documentos y pendientes", "Drive, Docs y Tasks")),
    )

    @Test fun pathsAreThreeLevelsAndIgnoreAccents() {
        assertEquals(listOf("Google y vida diaria", "Comunicación y agenda", "Correo y calendario"),
            SemanticContext.inferPath("Agenda una reunión con el equipo"))
        assertEquals(listOf("Ingeniería", "Apps móviles", "Swift y Kotlin"), SemanticContext.inferPath("Compila la app de iOS"))
        assertEquals(listOf("Lugares", "Ubicaciones y rutas", "Sitios guardados"), SemanticContext.inferPath("Busca un café cerca"))
        assertEquals(SemanticContext.defaultPath, SemanticContext.inferPath("hola"))
        // "rama" must not match inside "programa".
        assertEquals(SemanticContext.defaultPath, SemanticContext.inferPath("un programa de radio"))
        SemanticContext.pathRulesCheck()
    }

    @Test fun cleanPathTrimsAndFallsBack() {
        assertEquals(listOf("A", "B", "C"), SemanticContext.cleanPath(listOf(" A ", "", "B", "C", "D")))
        assertEquals(SemanticContext.defaultPath, SemanticContext.cleanPath(listOf(" ", "")))
    }

    @Test fun treeAggregatesCountsPerLevel() {
        val tree = SemanticContext.buildTree(nodes)
        val google = tree.first { it.name == "Google y vida diaria" }
        assertEquals(2, google.totalNodes)
        assertEquals(2, google.subfolders.size)
        val leaf = google.subfolders.first { it.name == "Comunicación y agenda" }.subfolders.single()
        assertEquals(3, leaf.depth)
        assertEquals(listOf("b"), leaf.nodes.map { it.id })
        assertEquals(nodes.sumOf { it.estimatedTokens }, tree.sumOf { it.totalTokens })
    }

    @Test fun retrievalPrefersTheBranchThenSharedWordsThenCritical() {
        val result = SemanticContext.retrieve(nodes, "¿Cuándo es la reunión del equipo en el calendario?", priority = false)
        assertEquals("b", result.nodes.first().id)
        assertTrue("shares 'equipo'/'calendario'", result.nodes.any { it.id == "d" })
        assertTrue(result.nodes.size <= 3)
        assertEquals(4, result.steps.size)
        val wide = SemanticContext.retrieve(nodes, "¿Cuándo es la reunión del equipo?", priority = true)
        assertTrue(wide.nodes.size <= 5)
        assertTrue("critical notes join in priority mode", wide.nodes.any { it.id == "a" })
    }

    @Test fun promptContextIsBoundedAndNullWhenEmpty() {
        assertNull(SemanticContext.promptContext(emptyList(), "hola", false))
        val text = SemanticContext.promptContext(nodes, "reunión de equipo", false, maxChars = 200)
        assertNotNull(text)
        assertTrue(text!!.startsWith("MEMORIA DEL USUARIO"))
        assertTrue(text.length < 200 + 140)
    }

    @Test fun fuzzySearchToleratesTyposAndAbbreviations() {
        assertTrue(SemanticContext.fuzzyScore("Correo y calendario", "calndario") > 0)
        assertTrue(SemanticContext.fuzzyScore("Swift y Kotlin", "swft ktln") > 0)
        assertTrue(SemanticContext.fuzzyScore("Reunión", "reunion") >= 100)
        assertEquals(0, SemanticContext.fuzzyScore("Café para trabajar", "kotlin"))
        val ranked = SemanticContext.fuzzyFilter(nodes, "kotln")
        assertEquals("a", ranked.first().node.id)
        assertEquals(nodes.size, SemanticContext.fuzzyFilter(nodes, "  ").size)
    }

    @Test fun graphHasHierarchyAndCrossBranchBridges() {
        val graph = SemanticContext.buildGraph(nodes)
        assertEquals(3, graph.nodes.count { it.kind == GraphNodeKind.DOMAIN })
        assertEquals(4, graph.nodes.count { it.kind == GraphNodeKind.CLUSTER })
        assertEquals(4, graph.nodes.count { it.kind == GraphNodeKind.CONTEXT })
        val ids = graph.nodes.map { it.id }.toSet()
        assertTrue(graph.links.all { it.source in ids && it.target in ids })
        val bridge = graph.links.single { it.kind == GraphLinkKind.SEMANTIC }
        assertEquals(setOf("b", "d"), setOf(bridge.source, bridge.target))
        val layout = SemanticContext.layout(graph)
        assertEquals(graph.nodes.size, layout.size)
        assertTrue(layout.values.all { it.x.isFinite() && it.y.isFinite() })
        assertEquals("deterministic", layout, SemanticContext.layout(graph))
    }
}

/** Keeps the rule table honest: every inferred path is three levels deep. */
private fun SemanticContext.pathRulesCheck() {
    listOf("correo", "drive", "github", "modelo", "mapa", "swift", "nada").forEach {
        assertEquals(3, inferPath(it).size)
    }
}

class AssistantCatalogTest {
    @Test fun toolIdsAreUniqueAndWritesNeedConfirmation() {
        val ids = AssistantCatalog.tools.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        assertTrue(ids.containsAll(listOf("as.save.context", "as.read.context_tree", "gmail.write.send", "googlesheets.read.range")))
        assertTrue(AssistantCatalog.requiresConfirmation(listOf("gmail.read.inbox", "gmail.write.send")))
        assertFalse(AssistantCatalog.requiresConfirmation(listOf("gmail.read.inbox", "googlecalendar.read.events")))
        assertTrue(AssistantCatalog.requiresConfirmation(listOf(AssistantCatalog.SAVE_CONTEXT)))
        AssistantCatalog.quickActions.forEach { assertNotNull(it.toolId, AssistantCatalog.tool(it.toolId)) }
    }

    @Test fun routingPicksTheRightTools() {
        assertEquals("gmail.write.send", AssistantCatalog.selectTools("Redacta un correo al equipo").first())
        assertEquals("gmail.read.inbox", AssistantCatalog.selectTools("¿Tengo correos nuevos?").first())
        assertEquals("googlecalendar.read.events", AssistantCatalog.selectTools("¿Qué tengo en mi agenda hoy?").first())
        assertEquals(AssistantCatalog.MAPS_SEARCH, AssistantCatalog.selectTools("Busca un café cerca de Reforma").first())
        assertEquals(AssistantCatalog.SAVE_CONTEXT, AssistantCatalog.selectTools("Recuerda que prefiero reuniones cortas").first())
        assertTrue(AssistantCatalog.selectTools("hola, ¿cómo estás?").isEmpty())
    }

    @Test fun developerSectionsAreHiddenByDefault() {
        assertFalse(AssistantCatalog.sections(false).contains(AssistantSection.LOG))
        assertTrue(AssistantCatalog.sections(true).contains(AssistantSection.LOG))
    }

    @Test fun gmailRawIsBase64UrlAndHeaderSafe() {
        val raw = AssistantCatalog.encodeGmailRaw("a@b.co\r\nBcc: x@y.z", "Hola ñ", "Cuerpo")
        assertFalse(raw.contains('+') || raw.contains('/') || raw.contains('='))
        val mime = String(Base64.getUrlDecoder().decode(raw), Charsets.UTF_8)
        assertTrue(mime.startsWith("To: a@b.co Bcc: x@y.z\r\n"))
        assertFalse("no injected header line", mime.contains("\r\nBcc:"))
        assertTrue(mime.contains("Subject: =?utf-8?B?" + Base64.getEncoder().encodeToString("Hola ñ".toByteArray()) + "?="))
        assertTrue(mime.endsWith("\r\n\r\nCuerpo"))
        assertTrue(AssistantCatalog.isPlausibleEmail("ana@empresa.mx"))
        assertFalse(AssistantCatalog.isPlausibleEmail("ana@empresa"))
        assertFalse(AssistantCatalog.isPlausibleEmail("a@b.co, c@d.co"))
    }
}

class GoogleOAuthTest {
    @Test fun pkceMatchesTheRfcExample() {
        // RFC 7636, appendix B.
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        val verifier = GoogleOAuth.newVerifier()
        assertTrue(verifier.length in 43..128)
        assertFalse(verifier == GoogleOAuth.newVerifier())
    }

    @Test fun authUrlCarriesScopesAndPkce() {
        val scopes = GoogleOAuth.scopes(listOf(GoogleService.GMAIL, GoogleService.TASKS))
        assertTrue(scopes.containsAll(listOf("openid", "email", "https://www.googleapis.com/auth/tasks")))
        val url = GoogleOAuth.authUrl("123-abc.apps.googleusercontent.com", GoogleOAuth.ANDROID_REDIRECT, scopes, "CH", "ST")
        assertTrue(url.startsWith(GoogleOAuth.AUTH_ENDPOINT + "?client_id=123-abc.apps.googleusercontent.com"))
        assertTrue(url.contains("code_challenge=CH") && url.contains("code_challenge_method=S256") && url.contains("state=ST"))
        assertTrue(url.contains("redirect_uri=dev.iyscode.movil%3A%2Foauth2redirect"))
        assertTrue(GoogleOAuth.isPlausibleClientId(" 123-abc.apps.googleusercontent.com "))
        assertFalse(GoogleOAuth.isPlausibleClientId("apps.googleusercontent.com"))
        assertEquals("com.googleusercontent.apps.123-abc:/oauth2redirect", GoogleOAuth.iosRedirect("123-abc.apps.googleusercontent.com"))
    }

    @Test fun tokenParsingKeepsRefreshTokenAcrossRefreshes() {
        val payload = Base64.getUrlEncoder().withoutPadding().encodeToString("""{"email":"ana@x.mx"}""".toByteArray())
        val first = GoogleOAuth.parseToken(
            """{"access_token":"A1","refresh_token":"R1","expires_in":3600,"scope":"email https://www.googleapis.com/auth/tasks","id_token":"h.$payload.s"}""",
            now = 1_000)
        assertEquals("R1", first.refreshToken)
        assertEquals("ana@x.mx", first.email)
        assertEquals(3_601_000, first.expiresAt)
        assertTrue(GoogleService.TASKS.isGranted(first.scopes))
        assertTrue(first.isFresh(now = 2_000))
        assertFalse(first.isFresh(now = 3_560_000))
        val refreshed = GoogleOAuth.parseToken("""{"access_token":"A2","expires_in":60}""", now = 5_000, previous = first)
        assertEquals("R1", refreshed.refreshToken)
        assertEquals(first.scopes, refreshed.scopes)
        assertEquals("ana@x.mx", refreshed.email)
        try {
            GoogleOAuth.parseToken("""{"error":"invalid_grant","error_description":"Token has been revoked."}""", 0)
            fail("expected an error")
        } catch (e: GoogleApiException) {
            assertEquals("Token has been revoked.", e.message)
        }
    }
}

class GoogleParsersTest {
    @Test fun parsesTheFieldsTheAppShows() {
        val mail = GoogleParsers.message("""{"id":"m1","snippet":"Hola","payload":{"headers":[
            {"name":"From","value":"Ana <ana@x.mx>"},{"name":"subject","value":"Junta"},{"name":"Date","value":"Thu"}]}}""")
        assertEquals("Junta", mail.subject)
        assertEquals("Ana <ana@x.mx>", mail.from)
        val events = GoogleParsers.events("""{"items":[{"id":"e1","summary":"Demo","start":{"dateTime":"2026-11-20T10:00:00-06:00"},
            "end":{"date":"2026-11-20"},"location":"Reforma 222"},{"id":"e2"}]}""")
        assertEquals(listOf("Demo", "(sin título)"), events.map { it.title })
        assertEquals("2026-11-20T10:00:00-06:00", events[0].start)
        assertEquals("2026-11-20", events[0].end)
        assertEquals(listOf("Comprar"), GoogleParsers.tasks("""{"items":[{"id":"t1","title":"Comprar"},{"id":"t2","title":"  "}]}""").map { it.title })
        val contact = GoogleParsers.contacts("""{"connections":[{"names":[{"displayName":"Ana"}],"emailAddresses":[{"value":"ana@x.mx"}]},{}]}""")
        assertEquals(1, contact.size)
        assertEquals("Hoja 1", GoogleParsers.firstSheetTitle("""{"sheets":[{"properties":{"title":"Hoja 1"}}]}"""))
        assertEquals(listOf(listOf("a", "1"), listOf("b")), GoogleParsers.sheetRows("""{"values":[["a","1"],["b"]]}"""))
        assertEquals("1BxiM", GoogleParsers.spreadsheetId("https://docs.google.com/spreadsheets/d/1BxiM/edit#gid=0"))
        assertEquals("abc", GoogleParsers.spreadsheetId(" abc "))
        assertEquals("Request had insufficient authentication scopes.",
            GoogleParsers.errorMessage("""{"error":{"code":403,"message":"Request had insufficient authentication scopes."}}"""))
        assertNull(GoogleParsers.errorMessage("not json"))
    }

    @Test fun clientSendsBearerTokenAndExplainsFailures() = runBlocking {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"items":[{"id":"t1","title":"Revisar PR"}]}"""))
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":{"message":"Tasks API has not been used"}}"""))
        server.enqueue(MockResponse().setBody("""{"sheets":[{"properties":{"title":"Mis datos"}}]}"""))
        server.enqueue(MockResponse().setBody("""{"updates":{}}"""))
        server.start()
        try {
            val client = GoogleClient(tokenProvider = { "TOKEN" }, baseOverride = server.url("/").toString())
            assertEquals("Revisar PR", client.openTasks().single().title)
            val first = server.takeRequest()
            assertEquals("Bearer TOKEN", first.getHeader("Authorization"))
            assertTrue(first.path!!.startsWith("/tasks/v1/lists/@default/tasks?"))
            try {
                client.openTasks(); fail("expected 403")
            } catch (e: GoogleApiException) {
                assertEquals(403, e.status)
                assertTrue(e.message!!.contains("Tasks API has not been used"))
            }
            server.takeRequest()
            client.appendRow("https://docs.google.com/spreadsheets/d/SHEET/edit", listOf("a", "b"))
            server.takeRequest()
            val append = server.takeRequest()
            assertEquals("POST", append.method)
            assertEquals("/v4/spreadsheets/SHEET/values/%27Mis%20datos%27%21A1:append?valueInputOption=RAW", append.path)
            assertEquals("""{"values":[["a","b"]]}""", append.body.readUtf8())
        } finally {
            server.shutdown()
        }
    }
}

class DaemonManifestTest {
    @Test fun parsesBothShapesAndSkipsBrokenEntries() {
        val wrapped = DaemonManifest.parse("""{"tasks":[{"id":"t1","title":"Build listo","body":"iOS ok","source":"pc.tui"},
            {"id":"","title":"sin id"},{"title":"sin id"},"texto",{"id":"t2","title":"Correo","summary":"de Ana"}]}""")
        assertEquals(listOf("t1", "t2"), wrapped.map { it.id })
        assertEquals("de Ana", wrapped[1].body)
        assertEquals("pc", wrapped[1].source)
        assertEquals(listOf("x"), DaemonManifest.parse("""[{"id":"x","title":"y"}]""").map { it.id })
        val many = (1..80).joinToString(",", "[", "]") { """{"id":"$it","title":"t"}""" }
        assertEquals(DaemonManifest.MAX_TASKS, DaemonManifest.parse(many).size)
    }

    @Test fun onlyUnseenTasksAreNew() {
        val tasks = listOf(DaemonTask("a", "A"), DaemonTask("b", "B"))
        assertEquals(listOf("b"), DaemonManifest.newTasks(setOf("a"), tasks).map { it.id })
    }

    @Test fun urlPolicyAllowsHttpsAndLocalHttpOnly() {
        assertTrue(DaemonManifest.isAllowedUrl("https://raw.githubusercontent.com/u/r/main/tareas.json"))
        assertTrue(DaemonManifest.isAllowedUrl("http://192.168.1.20:8787/tareas.json"))
        assertTrue(DaemonManifest.isAllowedUrl("http://mi-pc.local/tareas.json"))
        assertFalse(DaemonManifest.isAllowedUrl("http://example.com/tareas.json"))
        assertFalse(DaemonManifest.isAllowedUrl("http://172.40.0.1/x"))
        assertFalse(DaemonManifest.isAllowedUrl("ftp://x"))
    }

    @Test fun pollUsesEtag() = runBlocking {
        val server = MockWebServer()
        server.enqueue(MockResponse().setHeader("ETag", "\"v1\"").setBody("""{"tasks":[{"id":"1","title":"Hola"}]}"""))
        server.enqueue(MockResponse().setResponseCode(304))
        server.start()
        try {
            val client = DaemonManifestClient()
            val url = server.url("/tareas.json").toString()
            val first = client.poll(url, null) as ManifestPoll.Changed
            assertEquals("\"v1\"", first.etag)
            assertEquals(1, first.tasks.size)
            assertEquals(ManifestPoll.NotModified, client.poll(url, first.etag))
            server.takeRequest()
            assertEquals("\"v1\"", server.takeRequest().getHeader("If-None-Match"))
        } finally {
            server.shutdown()
        }
    }
}

class MemoryStoreTest {
    @Test fun savesDeletesAndSurvivesReload() {
        val dir = Files.createTempDirectory("memory").toFile()
        val file = java.io.File(dir, "assistant/memory.json")
        val store = MemoryStore(file) { 42L }
        val saved = store.save("", "Prefiero reuniones de 45 minutos", listOf("Google y vida diaria", " ", "Agenda"), ContextPriority.HIGH, "test")
        assertEquals("Prefiero reuniones de 45 minutos".take(60), saved.title)
        assertEquals(listOf("Google y vida diaria", "Agenda"), saved.path)
        assertEquals(42L, saved.createdAt)
        assertEquals(listOf(saved), MemoryStore(file).nodes.value)
        store.delete(saved.id)
        assertTrue(MemoryStore(file).nodes.value.isEmpty())
        file.writeText("{corrupt")
        assertTrue(MemoryStore(file).nodes.value.isEmpty())
        dir.deleteRecursively()
    }
}

class GoogleTokenTest {
    @Test fun freshnessLeavesAMinuteOfMargin() {
        val token = GoogleToken("A", expiresAt = 100_000)
        assertTrue(token.isFresh(39_000))
        assertFalse(token.isFresh(41_000))
        assertFalse(GoogleToken("", expiresAt = 100_000).isFresh(0))
    }
}

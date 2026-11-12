import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  ContextError, buildGraph, buildTree, createNode, editDistance, estimateTokens, exportDocument,
  formatForPrompt, normalizeText, parseDocument, retrieve, scoreFuzzy, searchNodes, significantWords, suggestPath,
} from "../workspace/semantic-context.mjs";
import { createContextStore } from "../workspace/context-store.mjs";
import {
  GOOGLE_TOOLS, allScopes, encodeGmailRawMessage, readOnlyScopes, requiresConfirmation, scopesForTools,
  selectToolsForPrompt, toGeminiDeclarations,
} from "../workspace/google-tools.mjs";
import { GoogleError, createGoogleClient, docText, driveQuote } from "../workspace/google-api.mjs";
import { GoogleOAuthError, buildAuthUrl, createGoogleSession, pkcePair, requireClient } from "../workspace/google-oauth.mjs";

const FIXED = new Date("2026-11-12T12:00:00Z");
const node = (title, summary, semanticPath, priority = "normal", id = title) =>
  createNode({ title, summary, semanticPath, priority }, { now: FIXED, id });

const SAMPLE = [
  node("Paridad SwiftUI y Kotlin", "La app de iPhone y la de Android deben verse igual en los dos temas.", ["Desarrollo", "Apps móviles", "iOS y Android"], "high"),
  node("Confirmar antes de enviar correos", "Todo correo o evento de calendario se confirma con la persona antes de enviarse.", ["Google Workspace", "Comunicación y agenda", "Correo y calendario"], "critical"),
  node("Hoja de seguimiento de sprints", "La hoja de Google Sheets del sprint tiene las métricas de compilación por semana.", ["Google Workspace", "Conocimiento y métricas", "Documentos, hojas y notas"]),
  node("Modelos locales pequeños", "GUS usa modelos GGUF pequeños; conviene recortar el contexto para que quepan en el iPhone.", ["Desarrollo", "Agentes y modelos", "Modelos y contexto"], "high"),
];

// ---------------------------------------------------------------- semantic-context

test("normalizeText quita acentos y mayúsculas", () => {
  assert.equal(normalizeText("  Ingeniería ÁRBOL "), "ingenieria arbol");
});

test("editDistance es acotada", () => {
  assert.equal(editDistance("kotlin", "kotlin"), 0);
  assert.equal(editDistance("kotlin", "kotlim"), 1);
  assert.equal(editDistance("kotlin", "x"), 99);
});

test("scoreFuzzy: exacta > errata > letras en orden; y exige todas las palabras", () => {
  const text = "Paridad SwiftUI y Kotlin";
  const exact = scoreFuzzy(text, "kotlin");
  const typo = scoreFuzzy(text, "kotlim");
  const letters = scoreFuzzy(text, "swft");
  assert.ok(exact > typo && exact > letters && typo > 0 && letters > 0, `${exact} ${typo} ${letters}`);
  assert.equal(scoreFuzzy(text, "kotlin cocina"), 0);
  assert.equal(scoreFuzzy(text, ""), 100);
  assert.equal(scoreFuzzy(text, "zzzz"), 0);
});

test("scoreFuzzy no acepta letras dispersas por todo el texto", () => {
  assert.equal(scoreFuzzy("a very long sentence about nothing relevant here at all", "xqz"), 0);
  assert.equal(scoreFuzzy("la zorra queda muy lejos del xilófono, qué rara", "zqx"), 0);
});

test("significantWords descarta stopwords, repetidos y palabras cortas", () => {
  assert.deepEqual(significantWords("Quiero que la app de iOS use el contexto, el contexto"), ["app", "ios", "use", "contexto"]);
});

test("createNode valida ruta, prioridad y tamaños", () => {
  assert.throws(() => createNode({ title: "", summary: "x", semanticPath: ["a", "b", "c"] }), ContextError);
  assert.throws(() => createNode({ title: "t", summary: "x", semanticPath: ["a", "b"] }), /tres carpetas/);
  assert.throws(() => createNode({ title: "t", summary: "x", semanticPath: ["a", "b", ""] }), /vacía/);
  assert.throws(() => createNode({ title: "t", summary: "x", semanticPath: ["a", "b", "c›d"] }), /›/);
  assert.throws(() => createNode({ title: "t", summary: "x", semanticPath: ["a", "b", "c"], priority: "root" }), /Prioridad/);
  assert.throws(() => createNode({ title: "t".repeat(121), summary: "x", semanticPath: ["a", "b", "c"] }), /título/);
  const ok = createNode({ title: " Hola  mundo ", summary: "x".repeat(40), semanticPath: [" a ", "b", "c"] }, { now: FIXED });
  assert.equal(ok.title, "Hola mundo");
  assert.equal(ok.estimatedTokens, estimateTokens("Hola mundo\n" + "x".repeat(40)));
  assert.equal(ok.createdAt, FIXED.toISOString());
  assert.deepEqual(ok.semanticPath, ["a", "b", "c"]);
});

test("buildTree agrupa y suma tokens por nivel", () => {
  const tree = buildTree(SAMPLE);
  assert.deepEqual(tree.map((f) => f.name), ["Desarrollo", "Google Workspace"]);
  const workspace = tree[1];
  assert.equal(workspace.totalDescendantNodes, 2);
  assert.equal(workspace.subfolders.length, 2);
  assert.equal(workspace.totalEstimatedTokens, SAMPLE[1].estimatedTokens + SAMPLE[2].estimatedTokens);
  assert.equal(workspace.subfolders[0].subfolders[0].nodes[0].id, SAMPLE[1].id);
});

test("searchNodes encuentra con erratas y por ruta", () => {
  assert.equal(searchNodes(SAMPLE, "calendar")[0].node.id, SAMPLE[1].id);
  assert.equal(searchNodes(SAMPLE, "comunicacion agenda")[0].matchedField, "semanticPath");
  assert.equal(searchNodes(SAMPLE, "").length, SAMPLE.length);
  assert.equal(searchNodes(SAMPLE, "xyzzy").length, 0);
});

test("retrieve recorre las ramas parecidas y siempre suma los críticos", () => {
  const result = retrieve(SAMPLE, "Necesito ajustar la app de iPhone para que se vea igual que la de Android");
  const ids = result.selectedNodes.map((n) => n.id);
  assert.equal(ids[0], SAMPLE[0].id);
  assert.ok(ids.includes(SAMPLE[1].id), "el crítico entra aunque el mensaje no hable de correo");
  assert.ok(!ids.includes(SAMPLE[2].id), "la hoja de sprints no se parece al mensaje");
  assert.ok(result.traversalSteps[0].startsWith("Dominio:"));
  assert.ok(result.traversalSteps.some((s) => s.startsWith("Categoría:")));
  assert.match(result.traversalSteps.at(-1), /por parecido, 1 crítico\(s\) siempre activos/);
});

test("retrieve respeta el presupuesto de tokens y el máximo de nodos", () => {
  const big = Array.from({ length: 8 }, (_, i) =>
    node(`Regla ${i} sobre swift`, "swift ".repeat(100), ["Desarrollo", "Apps móviles", `Tema ${i}`], "normal", `n${i}`));
  const limited = retrieve(big, "swift", { maxNodes: 5, tokenBudget: 400 });
  assert.ok(limited.selectedNodes.length >= 1 && limited.selectedNodes.length <= 3, String(limited.selectedNodes.length));
  assert.ok(limited.estimatedTokens <= 400 || limited.selectedNodes.length === 1);
  assert.equal(retrieve(big, "swift", { maxNodes: 2, tokenBudget: 9999 }).selectedNodes.length, 2);
});

test("retrieve sin palabras con significado solo usa críticos", () => {
  const result = retrieve(SAMPLE, "de la el y a");
  assert.deepEqual(result.selectedNodes.map((n) => n.id), [SAMPLE[1].id]);
  assert.match(result.traversalSteps.join("\n"), /solo se usan las reglas críticas/);
  assert.equal(retrieve([], "hola mundo").selectedNodes.length, 0);
  assert.equal(formatForPrompt(retrieve([], "hola")), null);
});

test("formatForPrompt marca el bloque como referencia", () => {
  const text = formatForPrompt(retrieve(SAMPLE, "correo del calendario"));
  assert.match(text, /^CONTEXTO GUARDADO \(referencia/);
  assert.match(text, /\[Google Workspace › Comunicación y agenda › Correo y calendario\]/);
});

test("suggestPath siempre devuelve tres carpetas", () => {
  for (const text of ["revisa mi gmail", "una hoja de calculo", "app de swift", "el modelo llama", "mapa de la ruta", "otra cosa"]) {
    assert.equal(suggestPath(text).length, 3, text);
  }
});

test("buildGraph: jerarquía y puentes por palabras compartidas", () => {
  const extra = node("Seguimiento semanal", "Revisar las métricas y el seguimiento de la hoja cada semana.", ["Desarrollo", "Procesos", "Rutina"]);
  const { graphNodes, graphLinks } = buildGraph([...SAMPLE, extra]);
  assert.equal(graphNodes.filter((n) => n.kind === "domain-hub").length, 2);
  assert.equal(graphNodes.filter((n) => n.kind === "path-cluster").length, 5);
  assert.equal(graphNodes.filter((n) => n.kind === "context-node").length, 5);
  const bridges = graphLinks.filter((l) => l.kind === "cross-semantic");
  assert.equal(bridges.length, 1);
  assert.deepEqual([bridges[0].source, bridges[0].target].sort(), [SAMPLE[2].id, extra.id].sort());
  assert.match(bridges[0].relationshipLabel, /seguimiento/);
  for (const link of graphLinks) {
    assert.ok(graphNodes.some((n) => n.id === link.source) && graphNodes.some((n) => n.id === link.target), link.id);
  }
});

test("export/parse son inversos y parse rechaza lo ajeno", () => {
  const doc = exportDocument(SAMPLE, FIXED);
  assert.equal(doc.schema, "isycode.semantic-context.v1");
  assert.deepEqual(parseDocument(JSON.stringify(doc)), SAMPLE);
  assert.throws(() => parseDocument({ schema: "otra", nodes: [] }), /no reconocido/);
  assert.throws(() => parseDocument({ schema: doc.schema, nodes: [{ title: "x" }] }), ContextError);
});

// ---------------------------------------------------------------- context-store

async function tempStore() {
  const dir = await mkdtemp(path.join(os.tmpdir(), "isy-ctx-"));
  return createContextStore({ file: path.join(dir, "ctx.json"), now: () => FIXED });
}

test("store: vacío al inicio, upsert deduplica y conserva id y fecha", async () => {
  const store = await tempStore();
  assert.deepEqual(await store.list(), []);
  const input = { title: "Regla uno", summary: "primera", semanticPath: ["A", "B", "C"] };
  const first = await store.upsert(input);
  assert.equal(first.created, true);
  const second = await store.upsert({ ...input, title: "regla UNO", summary: "segunda" });
  assert.equal(second.created, false);
  assert.equal(second.node.id, first.node.id);
  const nodes = await store.list();
  assert.equal(nodes.length, 1);
  assert.equal(nodes[0].summary, "segunda");
});

test("store: el archivo queda con permisos 0600 y escrituras simultáneas no se pisan", async () => {
  const store = await tempStore();
  await Promise.all(Array.from({ length: 12 }, (_, i) =>
    store.upsert({ title: `Nodo ${i}`, summary: "x", semanticPath: ["A", "B", "C"] })));
  assert.equal((await store.list()).length, 12);
  if (process.platform !== "win32") assert.equal((await stat(store.file)).mode & 0o777, 0o600);
});

test("store: remove e import sin duplicados", async () => {
  const store = await tempStore();
  const { node: saved } = await store.upsert({ title: "Uno", summary: "x", semanticPath: ["A", "B", "C"] });
  assert.equal(await store.remove(saved.id), true);
  assert.equal(await store.remove(saved.id), false);
  const doc = exportDocument(SAMPLE, FIXED);
  assert.deepEqual(await store.importDocument(doc), { added: 4, skipped: 0 });
  assert.deepEqual(await store.importDocument(doc), { added: 0, skipped: 4 });
  assert.equal((await store.exportDocument()).nodes.length, 4);
});

test("store: un archivo dañado se aparta, no se borra", async () => {
  const store = await tempStore();
  await writeFile(store.file, "{ esto no es json");
  await assert.rejects(store.list(), /dañado/);
  assert.equal(await readFile(`${store.file}.corrupt`, "utf8"), "{ esto no es json");
  assert.deepEqual(await store.list(), []);
});

// ---------------------------------------------------------------- google-tools

test("las herramientas que cambian algo exigen confirmación", () => {
  assert.equal(requiresConfirmation(["gmail_read_inbox", "calendar_list_events"]), false);
  for (const name of ["gmail_send_reply", "calendar_schedule_task", "docs_append_summary", "drive_create_doc",
    "classroom_post_announcement", "tasks_create_item", "googlekeep_write_note", "googlesheets_append_row", "as_save_context"]) {
    assert.equal(requiresConfirmation(["gmail_read_inbox", name]), true, name);
  }
});

test("catálogo: nombres únicos, esquemas válidos y escritura siempre dice que requiere confirmación", () => {
  assert.equal(new Set(GOOGLE_TOOLS.map((t) => t.name)).size, GOOGLE_TOOLS.length);
  assert.equal(new Set(GOOGLE_TOOLS.map((t) => t.id)).size, GOOGLE_TOOLS.length);
  for (const tool of GOOGLE_TOOLS) {
    assert.equal(tool.inputSchema.type, "object", tool.name);
    for (const key of tool.inputSchema.required) assert.ok(tool.inputSchema.properties[key], `${tool.name}.${key}`);
    if (tool.mode === "write") assert.match(tool.description, /confirmación/, tool.name);
    if (!tool.local) assert.ok(tool.scopes.length > 0, tool.name);
  }
});

test("scopes: mínimos, y solo-lectura no incluye ningún permiso de escritura", () => {
  const read = readOnlyScopes();
  assert.ok(read.includes("https://www.googleapis.com/auth/gmail.readonly"));
  for (const scope of read) assert.ok(!/gmail\.send|calendar\.events$|\/drive$|\/documents$|\/tasks$|\/spreadsheets$|keep$/.test(scope), scope);
  const all = allScopes();
  assert.ok(all.includes("https://www.googleapis.com/auth/gmail.send"));
  assert.ok(!all.includes("https://www.googleapis.com/auth/drive"), "nunca pedimos todo Drive");
  assert.ok(all.length < 25, `${all.length} permisos`);
  assert.deepEqual(scopesForTools(["as_save_context"]), ["openid", "email"]);
});

test("selectToolsForPrompt adjunta lectura y escritura según el mensaje", () => {
  assert.deepEqual(selectToolsForPrompt("¿qué tengo en el calendario hoy?"), ["calendar_list_events"]);
  assert.ok(selectToolsForPrompt("redacta y envía un correo al equipo").includes("gmail_send_reply"));
  assert.ok(selectToolsForPrompt("lo que sea", { priorityContext: true }).includes("as_save_context"));
  assert.deepEqual(selectToolsForPrompt("hola"), []);
});

test("toGeminiDeclarations usa tipos en mayúsculas y sin additionalProperties", () => {
  const [first] = toGeminiDeclarations();
  assert.equal(first.parameters.type, "OBJECT");
  assert.equal(first.parameters.properties.query.type, "STRING");
  assert.ok(!JSON.stringify(toGeminiDeclarations()).includes("additionalProperties"));
});

test("encodeGmailRawMessage codifica bien y bloquea inyección de encabezados", () => {
  const raw = encodeGmailRawMessage("ana@example.com", "Reunión ñandú", "Hola\nmundo");
  const mime = Buffer.from(raw, "base64url").toString("utf8");
  assert.match(mime, /^To: ana@example\.com\r\n/);
  const subject = /Subject: =\?utf-8\?B\?([^?]+)\?=/.exec(mime)[1];
  assert.equal(Buffer.from(subject, "base64").toString("utf8"), "Reunión ñandú");
  const body = mime.split("\r\n\r\n")[1].replace(/\r\n/g, "");
  assert.equal(Buffer.from(body, "base64").toString("utf8"), "Hola\r\nmundo");
  assert.ok(!/[+/=]/.test(raw));
  assert.throws(() => encodeGmailRawMessage("ana@example.com\r\nBcc: x@y.com", "a", "b"), /saltos de línea/);
  assert.throws(() => encodeGmailRawMessage("ana@example.com", "a\nBcc: x@y.com", "b"), /saltos de línea/);
  assert.throws(() => encodeGmailRawMessage("no-es-correo", "a", "b"), /correo válido/);
});

// ---------------------------------------------------------------- google-api

function fakeGoogle(routes, tokenValue = "tok") {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, method: init.method ?? "GET", headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined });
    for (const [pattern, reply] of routes) {
      if (pattern.test(url)) {
        const { status = 200, body = {} } = typeof reply === "function" ? reply(url, init) : reply;
        return { ok: status >= 200 && status < 300, status, json: async () => body };
      }
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  return { calls, client: createGoogleClient({ getAccessToken: async () => tokenValue, fetchImpl, now: () => FIXED }) };
}

test("api: las herramientas de escritura no corren sin confirmed:true", async () => {
  const { client, calls } = fakeGoogle([]);
  await assert.rejects(client.call("gmail_send_reply", { to: "a@b.co", subject: "s", body: "b" }), (e) => e.code === "CONFIRMATION_REQUIRED");
  await assert.rejects(client.call("gmail_send_reply", { to: "a@b.co", subject: "s", body: "b" }, { confirmed: "yes" }), (e) => e.code === "CONFIRMATION_REQUIRED");
  assert.equal(calls.length, 0);
  await assert.rejects(client.call("nope"), (e) => e.code === "UNKNOWN_TOOL");
});

test("api: sin sesión de Google no se llama a Google", async () => {
  const calls = [];
  const client = createGoogleClient({ getAccessToken: async () => null, fetchImpl: async (...a) => { calls.push(a); } });
  await assert.rejects(client.call("tasks_list_items"), (e) => e.code === "NO_TOKEN" && e.status === 401);
  assert.equal(calls.length, 0);
});

test("api: Gmail lee con filtro y manda el token como Bearer", async () => {
  const { client, calls } = fakeGoogle([
    [/messages\?/, { body: { messages: [{ id: "m1", threadId: "t1" }] } }],
    [/messages\/m1/, { body: { snippet: "hola", payload: { headers: [{ name: "Subject", value: "Asunto" }, { name: "From", value: "x@y.co" }] } } }],
  ]);
  const { messages } = await client.call("gmail_read_inbox", { query: "is:unread", maxResults: 999 });
  assert.deepEqual(messages, [{ id: "m1", threadId: "t1", subject: "Asunto", from: "x@y.co", date: "", snippet: "hola" }]);
  assert.match(calls[0].url, /maxResults=25&q=is%3Aunread/);
  assert.equal(calls[0].headers.Authorization, "Bearer tok");
});

test("api: Gmail envía el correo ya codificado", async () => {
  const { client, calls } = fakeGoogle([[/messages\/send/, { body: { id: "sent1", threadId: "t9" } }]]);
  assert.deepEqual(await client.call("gmail_send_reply", { to: "a@b.co", subject: "Hola", body: "x" }, { confirmed: true }), { id: "sent1", threadId: "t9" });
  assert.match(Buffer.from(calls[0].body.raw, "base64url").toString(), /^To: a@b\.co/);
});

test("api: Calendar de hoy usa una ventana que termina ese mismo día y el evento dura 1 h por defecto", async () => {
  const { client, calls } = fakeGoogle([
    [/events\?/, { body: { items: [{ id: "e1", summary: "Standup", start: { dateTime: "2026-11-12T15:00:00Z" }, end: { date: "2026-11-12" } }] } }],
    [/calendars\/primary\/events$/, (_u, init) => ({ body: { id: "new", ...JSON.parse(init.body) } })],
  ]);
  const { events } = await client.call("calendar_list_events", { timeRange: "today" });
  assert.equal(events[0].summary, "Standup");
  const params = new URL(calls[0].url).searchParams;
  assert.equal(params.get("timeMin"), FIXED.toISOString());
  assert.ok(Date.parse(params.get("timeMax")) - FIXED.getTime() < 24 * 3600_000);
  await client.call("calendar_schedule_task", { summary: "Revisión", startIso: "2026-11-13T10:00:00-06:00" }, { confirmed: true });
  assert.equal(calls[1].body.end.dateTime, "2026-11-13T17:00:00.000Z");
  await assert.rejects(client.call("calendar_schedule_task", { summary: "x", startIso: "mañana" }, { confirmed: true }), (e) => e.code === "BAD_ARGS");
  await assert.rejects(client.call("calendar_schedule_task", { summary: "x", startIso: "2026-11-13T10:00:00Z", endIso: "2026-11-13T09:00:00Z" }, { confirmed: true }), /termina antes/);
});

test("api: Drive escapa las comillas de la búsqueda", async () => {
  assert.equal(driveQuote("o'brien\\x"), "'o\\'brien\\\\x'");
  const { client, calls } = fakeGoogle([[/drive\/v3\/files/, { body: { files: [{ id: "f" }] } }]]);
  await client.call("drive_search_files", { query: "x' or name contains 'secreto" });
  const q = new URL(calls[0].url).searchParams.get("q");
  assert.equal(q, "trashed = false and name contains 'x\\' or name contains \\'secreto'");
});

test("api: Docs extrae texto y recorta", async () => {
  const doc = { documentId: "d", title: "T", body: { content: [{ paragraph: { elements: [{ textRun: { content: "Hola " } }, { textRun: { content: "mundo" } }] } }, { sectionBreak: {} }] } };
  assert.equal(docText(doc), "Hola mundo");
  const { client } = fakeGoogle([[/documents\/d$/, { body: doc }]]);
  assert.deepEqual(await client.call("docs_read_document", { documentId: "d" }), { documentId: "d", title: "T", text: "Hola mundo", truncated: false });
});

test("api: Contactos no inventa correos que no existen", async () => {
  const { client } = fakeGoogle([[/searchContacts/, { body: { results: [{ person: { resourceName: "people/1", names: [{ displayName: "Ana" }] } }] } }]]);
  assert.deepEqual((await client.call("contacts_lookup_person", { nameQuery: "ana" })).contacts[0], {
    resourceName: "people/1", displayName: "Ana", email: null, phone: null, organization: null,
  });
});

test("api: Sheets lee tal cual (sin columnas inventadas) y escribe como texto, no como fórmula", async () => {
  const { client, calls } = fakeGoogle([
    [/\?fields=sheets/, { body: { sheets: [{ properties: { title: "Sprint 3" } }] } }],
    [/values\/Sprint%203!A1%3AZ25$/, { body: { range: "Sprint 3!A1:Z25", values: [["a"], ["b", "c"]] } }],
    [/:append/, { body: { updates: { updatedRange: "Sprint 3!A9:B9" } } }],
  ]);
  assert.deepEqual(await client.call("googlesheets_read_range", { spreadsheetId: "S" }), { range: "Sprint 3!A1:Z25", values: [["a"], ["b", "c"]] });
  const result = await client.call("googlesheets_append_row", { spreadsheetId: "S", values: ["=IMPORTDATA(\"http://x\")", "2"] }, { confirmed: true });
  assert.equal(result.updatedRange, "Sprint 3!A9:B9");
  const append = calls.at(-1);
  assert.match(append.url, /valueInputOption=RAW/);
  assert.deepEqual(append.body, { values: [["=IMPORTDATA(\"http://x\")", "2"]] });
  await assert.rejects(client.call("googlesheets_append_row", { spreadsheetId: "S", values: "a,b" }, { confirmed: true }), (e) => e.code === "BAD_ARGS");
});

test("api: errores de Google se explican en español y no se disfrazan de éxito", async () => {
  for (const [status, expected] of [[401, /venció/], [403, /negó el permiso \(keep\.googleapis\.com\)/], [404, /no encontró/], [429, /esperar/], [500, /500/]]) {
    const { client } = fakeGoogle([[/./, { status, body: { error: { message: "detalle" } } }]]);
    await assert.rejects(client.call("googlekeep_read_notes", {}), (e) => e instanceof GoogleError && expected.test(e.message) && /detalle/.test(e.message) && e.status === status);
  }
});

test("api: las herramientas de contexto usan el almacén y piden ruta de tres carpetas", async () => {
  const store = await tempStore();
  const { client } = fakeGoogle([]);
  const withContext = createGoogleClient({ getAccessToken: async () => null, context: store });
  void client;
  const saved = await withContext.call("as_save_context", {
    title: "Preferencia", summary: "Siempre confirmar correos", domainFolder: "Google Workspace", categoryFolder: "Comunicación", topicFolder: "Correo", priority: "critical",
  }, { confirmed: true });
  assert.equal(saved.created, true);
  const read = await withContext.call("as_read_context_tree", { domainQuery: "correo" });
  assert.equal(read.selectedNodes[0].title, "Preferencia");
  assert.match(read.prompt, /Siempre confirmar correos/);
  await assert.rejects(withContext.call("as_save_context", { title: "", summary: "x", domainFolder: "a", categoryFolder: "b", topicFolder: "c" }, { confirmed: true }), (e) => e.code === "BAD_ARGS");
  await assert.rejects(createGoogleClient({ getAccessToken: async () => null }).call("as_read_context_tree", { domainQuery: "x" }), (e) => e.code === "NO_CONTEXT");
});

// ---------------------------------------------------------------- google-oauth

test("oauth: PKCE usa SHA-256 y la URL pide offline + S256 con los permisos dados", () => {
  const { verifier, challenge } = pkcePair();
  assert.equal(challenge, createHash("sha256").update(verifier).digest("base64url"));
  const url = new URL(buildAuthUrl({ clientId: "cid", redirectUri: "http://127.0.0.1:9/callback", scopes: ["openid", "email"], state: "st", challenge }));
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("scope"), "openid email");
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("state"), "st");
});

test("oauth: sin client_id explica cómo crearlo y no usa uno ajeno", () => {
  assert.throws(() => requireClient({}), (e) => e instanceof GoogleOAuthError && /ISY_GOOGLE_CLIENT_ID/.test(e.message) && /No usamos el client_id de otra app/.test(e.message));
  assert.deepEqual(requireClient({ ISY_GOOGLE_CLIENT_ID: " abc ", ISY_GOOGLE_CLIENT_SECRET: "" }), { clientId: "abc", clientSecret: undefined });
});

function oauthFetch(log, { expiresIn = 3600 } = {}) {
  return async (url, init = {}) => {
    const body = init.body ? Object.fromEntries(new URLSearchParams(init.body)) : {};
    log.push({ url, body, headers: init.headers });
    const json = (data, ok = true) => ({ ok, status: ok ? 200 : 400, json: async () => data });
    if (url.endsWith("/token") && body.grant_type === "authorization_code") {
      return json({ access_token: "A1", refresh_token: "R1", expires_in: expiresIn, scope: "openid email" });
    }
    if (url.endsWith("/token") && body.grant_type === "refresh_token") return json({ access_token: "A2", expires_in: 3600 });
    if (url.includes("userinfo")) return json({ email: "yo@example.com", name: "Yo" });
    if (url.endsWith("/revoke")) return json({});
    return json({}, false);
  };
}

test("oauth: flujo completo por loopback, canje con verificador PKCE, renovación y cierre de sesión", async () => {
  const log = [];
  let clock = 1_000_000;
  const session = createGoogleSession({ client: { clientId: "cid", clientSecret: "sec" }, fetchImpl: oauthFetch(log, { expiresIn: 3600 }), now: () => clock });
  assert.equal(await session.getAccessToken(), null);
  const { authUrl, done } = await session.beginLogin({ scopes: ["openid", "email"] });
  const auth = new URL(authUrl);
  const redirect = new URL(auth.searchParams.get("redirect_uri"));
  assert.equal(redirect.hostname, "127.0.0.1");

  const wrong = await fetch(`${redirect.origin}/callback?state=otro&code=X`);
  assert.equal(wrong.status, 400);
  assert.equal(log.length, 0, "un state ajeno no dispara ningún canje");

  const ok = await fetch(`${redirect.origin}/callback?state=${auth.searchParams.get("state")}&code=CODE`);
  assert.equal(ok.status, 200);
  const status = await done;
  assert.deepEqual(status, { configured: true, signedIn: true, email: "yo@example.com", name: "Yo", scopes: ["openid", "email"], loginPending: false });

  const exchange = log.find((entry) => entry.body.grant_type === "authorization_code");
  assert.equal(exchange.body.code, "CODE");
  assert.equal(exchange.body.client_secret, "sec");
  assert.equal(createHash("sha256").update(exchange.body.code_verifier).digest("base64url"), auth.searchParams.get("code_challenge"));

  assert.equal(await session.getAccessToken(), "A1");
  clock += 3600_000 - 30_000; // quedan 30 s: dentro del margen de renovación
  assert.equal(await session.getAccessToken(), "A2");
  assert.equal(log.at(-1).body.refresh_token, "R1");

  await session.logout();
  assert.equal(log.at(-1).body.token, "R1");
  assert.equal(session.status().signedIn, false);
  assert.equal(await session.getAccessToken(), null);
});

test("oauth: si la persona cancela en Google, la promesa falla y no queda nada abierto", async () => {
  const session = createGoogleSession({ client: { clientId: "cid" }, fetchImpl: oauthFetch([]) });
  const { authUrl, done } = await session.beginLogin({ scopes: ["openid"] });
  const auth = new URL(authUrl);
  const redirect = new URL(auth.searchParams.get("redirect_uri"));
  const rejected = assert.rejects(done, /no concedió el acceso \(access_denied\)/);
  await fetch(`${redirect.origin}/callback?state=${auth.searchParams.get("state")}&error=access_denied`);
  await rejected;
  assert.equal(session.status().loginPending, false);
  assert.equal(session.status().signedIn, false);
});

test("oauth: una renovación fallida cierra la sesión en vez de seguir usando un token muerto", async () => {
  let clock = 0;
  const base = oauthFetch([]);
  const fetchImpl = async (url, init) => (/token$/.test(url) && /refresh_token/.test(init?.body ?? "")
    ? { ok: false, status: 400, json: async () => ({ error: "invalid_grant", error_description: "Token has been revoked." }) }
    : base(url, init));
  const session = createGoogleSession({ client: { clientId: "cid" }, fetchImpl, now: () => clock });
  const { authUrl, done } = await session.beginLogin({ scopes: ["openid"] });
  const auth = new URL(authUrl);
  await fetch(`${new URL(auth.searchParams.get("redirect_uri")).origin}/callback?state=${auth.searchParams.get("state")}&code=C`);
  await done;
  clock += 7200_000;
  await assert.rejects(session.getAccessToken(), /rechazó la solicitud: Token has been revoked/);
  assert.equal(session.status().signedIn, false);
});

// ---------------------------------------------------------------- CLI

test("cli context: add, list, search, show, export/import, remove", async () => {
  const { runContextCommand } = await import("../bin/context_cli.mjs");
  const store = await tempStore();
  const lines = [];
  const errors = [];
  const run = (...args) => runContextCommand(args, { store, out: (l) => lines.push(l), err: (l) => errors.push(l) });

  assert.equal(await run("list"), 0);
  assert.match(lines.at(-1), /Todavía no hay contexto/);
  assert.equal(await run("add", "Google Workspace", "Comunicación", "Correo", "Confirmar correos", "Siempre confirmar antes de enviar", "--priority", "critical"), 0);
  assert.match(lines.at(-1), /^Guardado: ctx-/);
  assert.equal(await run("add", "solo", "dos"), 1);
  assert.match(errors.at(-1), /^uso:/);

  assert.equal(await run("list"), 0);
  assert.ok(lines.some((l) => l.includes("[critical] Confirmar correos")));
  assert.equal(await run("search", "confirmr"), 0);
  assert.match(lines.at(-1), /Confirmar correos/);
  assert.equal(await run("show", "voy a mandar un correo"), 0);
  assert.ok(lines.some((l) => l.startsWith("CONTEXTO GUARDADO")));

  const file = path.join(path.dirname(store.file), "export.json");
  assert.equal(await run("export", file), 0);
  const other = await tempStore();
  assert.equal(await runContextCommand(["import", file], { store: other, out: (l) => lines.push(l), err: () => {} }), 0);
  assert.match(lines.at(-1), /Importados 1, ya existían 0/);
  const [{ id }] = await store.list();
  assert.equal(await run("remove", id), 0);
  assert.equal(await run("remove", id), 1);
  assert.equal(await run("nada"), 2);
  await writeFile(file, "no es json");
  assert.equal(await runContextCommand(["import", file], { store: other, out: () => {}, err: (l) => errors.push(l) }), 1);
});

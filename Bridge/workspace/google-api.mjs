/**
 * Ejecuta las herramientas de Google Workspace contra las APIs REST.
 *
 * - El token de acceso lo da quien llama (`getAccessToken`); este archivo nunca lo guarda ni lo imprime.
 * - Las herramientas `write` exigen `confirmed: true`. Quien llama es responsable de haber
 *   mostrado la acción a la persona; aquí solo se impone que el interruptor exista.
 * - `fetch` se inyecta para que las pruebas corran sin red.
 * - Cuando Google responde con un error se dice cuál, sin inventar un resultado de relleno.
 */
import { GOOGLE_TOOLS, encodeGmailRawMessage, getTool } from "./google-tools.mjs";
import { ContextError, buildTree, formatForPrompt, retrieve, suggestPath } from "./semantic-context.mjs";

export class GoogleError extends Error {
  constructor(message, { status, code } = {}) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me";
const CALENDAR = "https://www.googleapis.com/calendar/v3/calendars/primary";
const DRIVE = "https://www.googleapis.com/drive/v3";
const DOCS = "https://docs.googleapis.com/v1/documents";
const PEOPLE = "https://people.googleapis.com/v1";
const CLASSROOM = "https://classroom.googleapis.com/v1";
const TASKS = "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks";
const KEEP = "https://keep.googleapis.com/v1/notes";
const SHEETS = "https://sheets.googleapis.com/v4/spreadsheets";

const MAX_TEXT = 8000;
const clampInt = (value, min, max, fallback) => {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
};

function requireString(args, key, max = 10_000) {
  const value = args?.[key];
  if (typeof value !== "string" || !value.trim()) throw new GoogleError(`Falta "${key}".`, { code: "BAD_ARGS" });
  if (value.length > max) throw new GoogleError(`"${key}" pasa de ${max} caracteres.`, { code: "BAD_ARGS" });
  return value;
}

function optionalString(args, key, max = 10_000) {
  const value = args?.[key];
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > max) throw new GoogleError(`"${key}" no es válido.`, { code: "BAD_ARGS" });
  return value;
}

function requireIso(args, key) {
  const value = requireString(args, key, 64);
  if (Number.isNaN(Date.parse(value))) throw new GoogleError(`"${key}" no es una fecha ISO 8601.`, { code: "BAD_ARGS" });
  return new Date(value).toISOString();
}

/** Texto plano de un documento de Google Docs. */
export function docText(document) {
  const out = [];
  for (const block of document?.body?.content ?? []) {
    for (const element of block.paragraph?.elements ?? []) out.push(element.textRun?.content ?? "");
  }
  return out.join("");
}

/** Escapa una cadena para usarla entre comillas simples en el parámetro q de Drive. */
export function driveQuote(text) {
  return `'${String(text).replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

export function createGoogleClient({ getAccessToken, fetchImpl = fetch, context = null, now = () => new Date() }) {
  async function api(url, { method = "GET", body } = {}) {
    const token = await getAccessToken();
    if (!token) throw new GoogleError("No hay sesión de Google. Inicia sesión primero.", { status: 401, code: "NO_TOKEN" });
    const response = await fetchImpl(url, {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.ok) return response.status === 204 ? {} : response.json();
    let detail = "";
    try {
      detail = (await response.json())?.error?.message ?? "";
    } catch { /* sin cuerpo */ }
    const host = new URL(url).hostname;
    const reason =
      response.status === 401 ? "La sesión de Google venció; vuelve a iniciar sesión."
      : response.status === 403 ? `Google negó el permiso (${host}). Revisa que la API esté habilitada en tu proyecto y que hayas aceptado el permiso.`
      : response.status === 404 ? "Google no encontró lo que se pidió (revisa el ID)."
      : response.status === 429 ? "Google pidió esperar un momento (demasiadas peticiones)."
      : `Google respondió ${response.status}.`;
    throw new GoogleError(detail ? `${reason} ${detail}` : reason, { status: response.status, code: "GOOGLE_HTTP" });
  }

  async function firstSheetTitle(spreadsheetId) {
    const meta = await api(`${SHEETS}/${encodeURIComponent(spreadsheetId)}?fields=sheets.properties.title`);
    const title = meta.sheets?.[0]?.properties?.title;
    if (!title) throw new GoogleError("La hoja no tiene pestañas legibles.", { code: "GOOGLE_HTTP" });
    return title;
  }

  const handlers = {
    async gmail_read_inbox(args) {
      const max = clampInt(args.maxResults, 1, 25, 8);
      const q = optionalString(args, "query", 300);
      const list = await api(`${GMAIL}/messages?maxResults=${max}${q ? `&q=${encodeURIComponent(q)}` : ""}`);
      const messages = await Promise.all(
        (list.messages ?? []).map(async ({ id, threadId }) => {
          const m = await api(`${GMAIL}/messages/${id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date`);
          const header = (name) => m.payload?.headers?.find((h) => h.name.toLowerCase() === name)?.value ?? "";
          return { id, threadId, subject: header("subject"), from: header("from"), date: header("date"), snippet: m.snippet ?? "" };
        }),
      );
      return { messages };
    },

    async gmail_send_reply(args) {
      const raw = encodeGmailRawMessage(requireString(args, "to", 320), requireString(args, "subject", 300), requireString(args, "body", 20_000));
      const sent = await api(`${GMAIL}/messages/send`, { method: "POST", body: { raw } });
      return { id: sent.id, threadId: sent.threadId };
    },

    async calendar_list_events(args) {
      const start = now();
      const end = new Date(start);
      if (optionalString(args, "timeRange", 16) === "week") end.setDate(end.getDate() + 7);
      else end.setHours(23, 59, 59, 999);
      const params = new URLSearchParams({ timeMin: start.toISOString(), timeMax: end.toISOString(), singleEvents: "true", orderBy: "startTime", maxResults: "25" });
      const data = await api(`${CALENDAR}/events?${params}`);
      return {
        events: (data.items ?? []).map((e) => ({
          id: e.id, summary: e.summary ?? "(sin título)", start: e.start?.dateTime ?? e.start?.date ?? "",
          end: e.end?.dateTime ?? e.end?.date ?? "", location: e.location, htmlLink: e.htmlLink,
        })),
      };
    },

    async calendar_schedule_task(args) {
      const startIso = requireIso(args, "startIso");
      const endIso = optionalString(args, "endIso", 64) ? requireIso(args, "endIso") : new Date(Date.parse(startIso) + 60 * 60_000).toISOString();
      if (Date.parse(endIso) <= Date.parse(startIso)) throw new GoogleError("El evento termina antes de empezar.", { code: "BAD_ARGS" });
      const e = await api(`${CALENDAR}/events`, {
        method: "POST",
        body: {
          summary: requireString(args, "summary", 300), location: optionalString(args, "location", 300),
          description: "Creado desde iSyCode Móvil.", start: { dateTime: startIso }, end: { dateTime: endIso },
        },
      });
      return { id: e.id, summary: e.summary, start: e.start?.dateTime, end: e.end?.dateTime, htmlLink: e.htmlLink };
    },

    async drive_search_files(args) {
      const q = optionalString(args, "query", 200);
      const clauses = ["trashed = false", ...(q ? [`name contains ${driveQuote(q)}`] : [])];
      const params = new URLSearchParams({ pageSize: "15", orderBy: "modifiedTime desc", q: clauses.join(" and "), fields: "files(id,name,mimeType,modifiedTime,webViewLink)" });
      return { files: (await api(`${DRIVE}/files?${params}`)).files ?? [] };
    },

    async docs_read_document(args) {
      const doc = await api(`${DOCS}/${encodeURIComponent(requireString(args, "documentId", 200))}`);
      const text = docText(doc);
      return { documentId: doc.documentId, title: doc.title, text: text.slice(0, MAX_TEXT), truncated: text.length > MAX_TEXT };
    },

    async docs_append_summary(args) {
      const id = encodeURIComponent(requireString(args, "documentId", 200));
      await api(`${DOCS}/${id}:batchUpdate`, {
        method: "POST",
        body: { requests: [{ insertText: { endOfSegmentLocation: { segmentId: "" }, text: `\n${requireString(args, "content", 20_000)}\n` } }] },
      });
      return { documentId: args.documentId, appended: true };
    },

    async drive_create_doc(args) {
      const created = await api(DOCS, { method: "POST", body: { title: requireString(args, "title", 300) } });
      const content = optionalString(args, "content", 20_000);
      if (content) {
        await api(`${DOCS}/${encodeURIComponent(created.documentId)}:batchUpdate`, {
          method: "POST", body: { requests: [{ insertText: { endOfSegmentLocation: { segmentId: "" }, text: content } }] },
        });
      }
      return { documentId: created.documentId, title: created.title };
    },

    async contacts_lookup_person(args) {
      const query = requireString(args, "nameQuery", 200);
      const readMask = "names,emailAddresses,phoneNumbers,organizations";
      const params = new URLSearchParams({ query, readMask, pageSize: "10" });
      const data = await api(`${PEOPLE}/people:searchContacts?${params}`);
      return {
        contacts: (data.results ?? []).map(({ person: p }) => ({
          resourceName: p.resourceName, displayName: p.names?.[0]?.displayName ?? null,
          email: p.emailAddresses?.[0]?.value ?? null, phone: p.phoneNumbers?.[0]?.value ?? null, organization: p.organizations?.[0]?.name ?? null,
        })),
      };
    },

    async classroom_list_courses() {
      const data = await api(`${CLASSROOM}/courses?courseStates=ACTIVE&pageSize=20`);
      return { courses: (data.courses ?? []).map((c) => ({ id: c.id, name: c.name, section: c.section, alternateLink: c.alternateLink })) };
    },

    async classroom_post_announcement(args) {
      const a = await api(`${CLASSROOM}/courses/${encodeURIComponent(requireString(args, "courseId", 64))}/announcements`, {
        method: "POST", body: { text: requireString(args, "text", 20_000), state: "PUBLISHED" },
      });
      return { id: a.id };
    },

    async tasks_list_items() {
      const data = await api(`${TASKS}?maxResults=25&showCompleted=false`);
      return { tasks: (data.items ?? []).map((t) => ({ id: t.id, title: t.title, notes: t.notes ?? null, due: t.due ?? null, status: t.status })) };
    },

    async tasks_create_item(args) {
      const t = await api(TASKS, { method: "POST", body: { title: requireString(args, "title", 1024), notes: optionalString(args, "notes", 8192) } });
      return { id: t.id, title: t.title };
    },

    async googlekeep_read_notes(args) {
      const filter = optionalString(args, "filter", 200);
      const data = await api(`${KEEP}?pageSize=20${filter ? `&filter=${encodeURIComponent(filter)}` : ""}`);
      return { notes: (data.notes ?? []).map((n) => ({ name: n.name, title: n.title ?? "", text: n.body?.text?.text ?? "", updateTime: n.updateTime })) };
    },

    async googlekeep_write_note(args) {
      const n = await api(KEEP, { method: "POST", body: { title: requireString(args, "title", 1000), body: { text: { text: requireString(args, "bodyText", 20_000) } } } });
      return { name: n.name };
    },

    async googlesheets_read_range(args) {
      const id = requireString(args, "spreadsheetId", 200);
      const given = optionalString(args, "range", 200);
      const range = given ?? `${await firstSheetTitle(id)}!A1:Z25`;
      const data = await api(`${SHEETS}/${encodeURIComponent(id)}/values/${encodeURIComponent(range)}`);
      return { range: data.range ?? range, values: (data.values ?? []).slice(0, 50) };
    },

    async googlesheets_append_row(args) {
      const id = requireString(args, "spreadsheetId", 200);
      if (!Array.isArray(args.values) || args.values.length === 0 || args.values.length > 50 || args.values.some((v) => typeof v !== "string" || v.length > 2000)) {
        throw new GoogleError('"values" debe ser una lista de 1 a 50 textos.', { code: "BAD_ARGS" });
      }
      const range = `${await firstSheetTitle(id)}!A1`;
      // RAW, no USER_ENTERED: un valor que empiece con "=" no debe convertirse en fórmula
      // (=IMPORTDATA(...) sacaría datos de la hoja hacia un servidor ajeno).
      const result = await api(`${SHEETS}/${encodeURIComponent(id)}/values/${encodeURIComponent(range)}:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS`, {
        method: "POST", body: { values: [args.values] },
      });
      return { updatedRange: result.updates?.updatedRange ?? null };
    },

    async as_read_context_tree(args) {
      if (!context) throw new GoogleError("El contexto semántico no está configurado.", { code: "NO_CONTEXT" });
      const nodes = await context.list();
      const query = requireString(args, "domainQuery", 500);
      const result = retrieve(nodes, query);
      return { ...result, prompt: formatForPrompt(result), folders: buildTree(nodes).map((f) => ({ name: f.name, nodes: f.totalDescendantNodes })) };
    },

    async as_save_context(args) {
      if (!context) throw new GoogleError("El contexto semántico no está configurado.", { code: "NO_CONTEXT" });
      const path = [optionalString(args, "domainFolder", 60), optionalString(args, "categoryFolder", 60), optionalString(args, "topicFolder", 60)];
      const fallback = suggestPath(`${args.title ?? ""} ${args.summary ?? ""}`);
      try {
        const { node, created } = await context.upsert({
          title: args.title, summary: args.summary, priority: optionalString(args, "priority", 16) ?? "normal",
          semanticPath: path.map((segment, i) => segment ?? fallback[i]), sourceTool: "as.save.context",
        });
        return { id: node.id, created, semanticPath: node.semanticPath };
      } catch (error) {
        if (error instanceof ContextError) throw new GoogleError(error.message, { code: "BAD_ARGS" });
        throw error;
      }
    },
  };

  return {
    tools: GOOGLE_TOOLS,

    /** Ejecuta una herramienta. Las de escritura necesitan `confirmed: true`. */
    async call(name, args = {}, { confirmed = false } = {}) {
      const tool = getTool(name);
      if (!tool) throw new GoogleError(`Herramienta desconocida: ${name}.`, { code: "UNKNOWN_TOOL" });
      if (tool.mode === "write" && confirmed !== true) {
        throw new GoogleError(`"${name}" cambia algo y necesita tu confirmación.`, { code: "CONFIRMATION_REQUIRED" });
      }
      if (typeof args !== "object" || args === null || Array.isArray(args)) throw new GoogleError("Los argumentos deben ser un objeto.", { code: "BAD_ARGS" });
      return handlers[name](args);
    },
  };
}

/**
 * Catálogo de herramientas de Google Workspace que un modelo puede pedir.
 *
 * Dos reglas que vienen del resto del proyecto:
 *  1. Lo que cambia algo (mandar un correo, agendar, escribir en una hoja) es `write` y NUNCA
 *     corre sin una confirmación explícita de la persona. Leer es `read`.
 *  2. Cada herramienta declara sus permisos de Google uno por uno. La sesión pide solo los de las
 *     herramientas que se van a usar, no una lista gigante "por si acaso".
 *
 * No hay herramienta para ejecutar comandos en la computadora ni para mandar push: eso vive en
 * otras capas (el sandbox Docker y la app) con sus propias aprobaciones.
 */
import { Buffer } from "node:buffer";

const S = "https://www.googleapis.com/auth/";

/** @typedef {{name:string,id:string,service:string,mode:'read'|'write',scopes:string[],description:string,inputSchema:object,local?:boolean}} GoogleTool */

const str = (description) => ({ type: "string", description });
const obj = (properties, required = []) => ({ type: "object", properties, required, additionalProperties: false });

/** @type {GoogleTool[]} */
export const GOOGLE_TOOLS = [
  {
    name: "gmail_read_inbox", id: "gmail.read.inbox", service: "Gmail", mode: "read",
    scopes: [`${S}gmail.readonly`],
    description: "Lee los correos recientes de Gmail (asunto, remitente y fragmento). Acepta un filtro de Gmail como is:unread.",
    inputSchema: obj({ query: str("Filtro de Gmail, ej. is:unread o from:cliente"), maxResults: { type: "integer", description: "Entre 1 y 25" } }),
  },
  {
    name: "gmail_send_reply", id: "gmail.write.send", service: "Gmail", mode: "write",
    scopes: [`${S}gmail.send`],
    description: "Envía un correo. Requiere confirmación de la persona.",
    inputSchema: obj({ to: str("Correo del destinatario"), subject: str("Asunto"), body: str("Cuerpo del mensaje") }, ["to", "subject", "body"]),
  },
  {
    name: "calendar_list_events", id: "googlecalendar.read.availability", service: "Google Calendar", mode: "read",
    scopes: [`${S}calendar.events.readonly`],
    description: "Lista los próximos eventos del calendario principal para ver disponibilidad.",
    inputSchema: obj({ timeRange: str("today o week (por defecto today)") }),
  },
  {
    name: "calendar_schedule_task", id: "googlecalendar.write.event", service: "Google Calendar", mode: "write",
    scopes: [`${S}calendar.events`],
    description: "Crea un evento en el calendario principal. Requiere confirmación de la persona.",
    inputSchema: obj({ summary: str("Título"), startIso: str("Inicio, ISO 8601 con zona horaria"), endIso: str("Fin, ISO 8601 (por defecto una hora después)"), location: str("Lugar") }, ["summary", "startIso"]),
  },
  {
    name: "drive_search_files", id: "googledrive.read.files", service: "Google Drive", mode: "read",
    scopes: [`${S}drive.metadata.readonly`],
    description: "Busca archivos por nombre en Drive (solo metadatos: nombre, tipo, fecha y enlace).",
    inputSchema: obj({ query: str("Texto a buscar en el nombre del archivo") }),
  },
  {
    name: "docs_read_document", id: "googledocs.read.document", service: "Google Docs", mode: "read",
    scopes: [`${S}documents.readonly`],
    description: "Lee el texto de un documento de Google Docs a partir de su ID.",
    inputSchema: obj({ documentId: str("ID del documento (la parte larga de la URL)") }, ["documentId"]),
  },
  {
    name: "docs_append_summary", id: "googledocs.write.append", service: "Google Docs", mode: "write",
    scopes: [`${S}documents`],
    description: "Agrega texto al final de un documento existente. Requiere confirmación de la persona.",
    inputSchema: obj({ documentId: str("ID del documento"), content: str("Texto a agregar") }, ["documentId", "content"]),
  },
  {
    name: "drive_create_doc", id: "googledrive.write.doc", service: "Google Docs", mode: "write",
    scopes: [`${S}documents`],
    description: "Crea un documento nuevo de Google Docs con un texto inicial. Requiere confirmación de la persona.",
    inputSchema: obj({ title: str("Título"), content: str("Texto inicial") }, ["title"]),
  },
  {
    name: "contacts_lookup_person", id: "googlecontacts.read.lookup", service: "Google Contacts", mode: "read",
    scopes: [`${S}contacts.readonly`],
    description: "Busca un contacto por nombre o correo y devuelve nombre, correo, teléfono y organización.",
    inputSchema: obj({ nameQuery: str("Nombre o correo") }, ["nameQuery"]),
  },
  {
    name: "classroom_list_courses", id: "googleclassroom.read.courses", service: "Google Classroom", mode: "read",
    scopes: [`${S}classroom.courses.readonly`],
    description: "Lista los cursos activos de Google Classroom.",
    inputSchema: obj({}),
  },
  {
    name: "classroom_post_announcement", id: "googleclassroom.write.announcement", service: "Google Classroom", mode: "write",
    scopes: [`${S}classroom.announcements`],
    description: "Publica un anuncio en un curso. Requiere confirmación de la persona.",
    inputSchema: obj({ courseId: str("ID del curso"), text: str("Texto del anuncio") }, ["courseId", "text"]),
  },
  {
    name: "tasks_list_items", id: "googletasks.read.list", service: "Google Tasks", mode: "read",
    scopes: [`${S}tasks.readonly`],
    description: "Lista los pendientes de la lista predeterminada de Google Tasks.",
    inputSchema: obj({}),
  },
  {
    name: "tasks_create_item", id: "googletasks.write.create", service: "Google Tasks", mode: "write",
    scopes: [`${S}tasks`],
    description: "Crea un pendiente en Google Tasks. Requiere confirmación de la persona.",
    inputSchema: obj({ title: str("Título"), notes: str("Notas") }, ["title"]),
  },
  {
    name: "googlekeep_read_notes", id: "googlekeep.read.notes", service: "Google Keep", mode: "read",
    scopes: [`${S}keep.readonly`],
    description: "Lee notas de Google Keep. La API de Keep solo está disponible en cuentas de Google Workspace.",
    inputSchema: obj({ filter: str("Filtro opcional de Keep") }),
  },
  {
    name: "googlekeep_write_note", id: "googlekeep.write.note", service: "Google Keep", mode: "write",
    scopes: [`${S}keep`],
    description: "Crea una nota en Google Keep (solo Google Workspace). Requiere confirmación de la persona.",
    inputSchema: obj({ title: str("Título"), bodyText: str("Contenido") }, ["title", "bodyText"]),
  },
  {
    name: "googlesheets_read_range", id: "googlesheets.read.range", service: "Google Sheets", mode: "read",
    scopes: [`${S}spreadsheets.readonly`],
    description: "Lee un rango de una hoja. Si no das rango, lee las primeras filas de la primera pestaña.",
    inputSchema: obj({ spreadsheetId: str("ID de la hoja de cálculo"), range: str("Rango A1, ej. Hoja1!A1:E10 (opcional)") }, ["spreadsheetId"]),
  },
  {
    name: "googlesheets_append_row", id: "googlesheets.write.append_row", service: "Google Sheets", mode: "write",
    scopes: [`${S}spreadsheets`],
    description: "Agrega una fila al final de la primera pestaña. Los valores se guardan como texto, no como fórmulas. Requiere confirmación de la persona.",
    inputSchema: obj({ spreadsheetId: str("ID de la hoja de cálculo"), values: { type: "array", items: { type: "string" }, description: "Un valor por columna" } }, ["spreadsheetId", "values"]),
  },
  {
    name: "as_read_context_tree", id: "as.read.context_tree", service: "Contexto semántico", mode: "read", local: true,
    scopes: [],
    description: "Recorre el árbol de contexto guardado y devuelve los nodos relevantes para un tema.",
    inputSchema: obj({ domainQuery: str("Tema a explorar") }, ["domainQuery"]),
  },
  {
    name: "as_save_context", id: "as.save.context", service: "Contexto semántico", mode: "write", local: true,
    scopes: [],
    description: "Guarda un acuerdo o preferencia en el árbol de contexto (tres carpetas). Requiere confirmación de la persona.",
    inputSchema: obj({
      title: str("Título corto"), summary: str("Resumen de la decisión o preferencia"),
      domainFolder: str("Carpeta 1: dominio"), categoryFolder: str("Carpeta 2: categoría"), topicFolder: str("Carpeta 3: tema"),
      priority: { type: "string", enum: ["normal", "high", "critical"], description: "Importancia" },
    }, ["title", "summary", "domainFolder", "categoryFolder", "topicFolder"]),
  },
];

const byName = new Map(GOOGLE_TOOLS.map((tool) => [tool.name, tool]));

export function getTool(name) {
  return byName.get(name) ?? null;
}

export function isWriteTool(name) {
  return getTool(name)?.mode === "write";
}

/** ¿Alguna de estas herramientas cambia algo y por tanto exige confirmación? */
export function requiresConfirmation(names) {
  return names.some((name) => isWriteTool(name));
}

/** Los permisos de Google que hacen falta para usar estas herramientas, sin repetir. */
export function scopesForTools(names) {
  const scopes = new Set(["openid", "email"]);
  for (const name of names) for (const scope of getTool(name)?.scopes ?? []) scopes.add(scope);
  return [...scopes];
}

/** Permisos de solo lectura de todo el catálogo: el arranque por defecto. */
export function readOnlyScopes() {
  return scopesForTools(GOOGLE_TOOLS.filter((tool) => tool.mode === "read").map((tool) => tool.name));
}

/** Todos los permisos, incluidos los de escritura. Solo si la persona lo pide con --write. */
export function allScopes() {
  return scopesForTools(GOOGLE_TOOLS.map((tool) => tool.name));
}

/** Declaraciones en el formato de function calling de @google/genai (type en MAYÚSCULAS). */
export function toGeminiDeclarations(tools = GOOGLE_TOOLS) {
  const upper = (schema) => {
    if (Array.isArray(schema)) return schema.map(upper);
    if (!schema || typeof schema !== "object") return schema;
    return Object.fromEntries(
      Object.entries(schema)
        .filter(([key]) => key !== "additionalProperties")
        .map(([key, value]) => [key, key === "type" && typeof value === "string" ? value.toUpperCase() : upper(value)]),
    );
  };
  return tools.map((tool) => ({
    name: tool.name,
    description: `[${tool.id}] ${tool.description}`,
    parameters: upper(tool.inputSchema),
  }));
}

/**
 * Qué herramientas adjuntar a un mensaje. Es una heurística por palabras: un respaldo para el
 * panel y para modelos pequeños que se confunden con 19 herramientas. No decide permisos.
 */
export function selectToolsForPrompt(prompt, { priorityContext = false } = {}) {
  const text = String(prompt ?? "").toLowerCase();
  const tools = new Set();
  const has = (pattern) => pattern.test(text);

  if (priorityContext || has(/as\.save\.context|guard\w*.*contexto|guarda.*pl[aá]tica|recordar|memori[az]|contexto prioritario|[aá]rbol de contexto|carpeta sem[aá]ntica/)) {
    tools.add("as_read_context_tree");
    tools.add("as_save_context");
  } else if (has(/contexto|context|sem[aá]ntic|precisi[oó]n/)) {
    tools.add("as_read_context_tree");
  }
  if (has(/correo|email|gmail|mensaje|inbox|responder|draft/)) {
    tools.add("gmail_read_inbox");
    if (has(/enviar|responde|reply|send|avisa|redacta|draft/)) tools.add("gmail_send_reply");
  }
  if (has(/calendario|calendar|agenda|reuni[oó]n|cita|evento|schedule|availability|disponibilidad/)) {
    tools.add("calendar_list_events");
    if (has(/agend[a-z]*|crear|programa|schedule|nuevo evento/)) tools.add("calendar_schedule_task");
  }
  if (has(/drive|archivo|carpeta|folder|subir|file/)) {
    tools.add("drive_search_files");
    if (has(/crea|nuevo|guardar|exporta/)) tools.add("drive_create_doc");
  }
  if (has(/docs|documento|reporte|minuta|apunte/)) {
    tools.add("docs_read_document");
    if (has(/agrega|escribe|actualiza|append|anota|resumen/)) tools.add("docs_append_summary");
  }
  if (has(/contacto|contacts|people|tel[eé]fono|directorio|persona/)) tools.add("contacts_lookup_person");
  if (has(/classroom|clase|curso|tarea escolar|entrega|anuncio|profesor|estudiante/)) {
    tools.add("classroom_list_courses");
    if (has(/publica|anuncio|anunciar|post|aviso/)) tools.add("classroom_post_announcement");
  }
  if (has(/tasks|pendiente|to-do|todo|lista de tareas/)) {
    tools.add("tasks_list_items");
    if (has(/agregar|crear|nueva tarea|anotar|add/)) tools.add("tasks_create_item");
  }
  if (has(/keep|nota r[aá]pida|notas|checklist/)) {
    tools.add("googlekeep_read_notes");
    if (has(/crea|escribe|write|anota|nueva nota|guardar/)) tools.add("googlekeep_write_note");
  }
  if (has(/sheets|spreadsheet|hoja de c[aá]lculo|celda|fila|rango|tabla|m[eé]tricas/)) {
    tools.add("googlesheets_read_range");
    if (has(/append|agrega|insertar|fila|escribe|write|actualiza/)) tools.add("googlesheets_append_row");
  }
  return [...tools];
}

/**
 * Cuerpo "raw" de Gmail (RFC 2822 en base64url).
 * Rechaza saltos de línea en destinatario y asunto: sin esa regla, un texto con "\r\nBcc: x"
 * (de un correo entrante, por ejemplo) metería encabezados que la persona nunca aprobó.
 */
export function encodeGmailRawMessage(to, subject, bodyText) {
  const address = String(to ?? "").trim();
  const title = String(subject ?? "");
  if (/[\r\n]/.test(address) || /[\r\n]/.test(title)) {
    throw new Error("El destinatario y el asunto no pueden llevar saltos de línea.");
  }
  if (!/^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/.test(address)) {
    throw new Error("El destinatario no parece un correo válido.");
  }
  const body = String(bodyText ?? "").replace(/\r?\n/g, "\r\n");
  const mime = [
    `To: ${address}`,
    `Subject: =?utf-8?B?${Buffer.from(title, "utf8").toString("base64")}?=`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    Buffer.from(body, "utf8").toString("base64").replace(/(.{76})/g, "$1\r\n"),
  ].join("\r\n");
  return Buffer.from(mime, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

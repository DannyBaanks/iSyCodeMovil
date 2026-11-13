// Tareas del daemon para el teléfono.
//
//   iyscodemovil notify "Build listo" --body "xcodebuild OK" [--source pc.tui] [--ntfy mi-tema]
//   iyscodemovil tasks serve [--port 8787]
//   iyscodemovil tasks list
//
// `notify` agrega la tarea al manifiesto que vigila el Asistente de iSyCode
// Móvil (formato en docs/GOOGLE_ASSISTANT.md) y, si hay un tema de ntfy,
// manda además un push que llega con el teléfono bloqueado. `tasks serve`
// publica ese manifiesto en tu red local con ETag, para que el teléfono solo
// descargue cuando algo cambió.

import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

export const MAX_TASKS = 50;
const FIELD_LIMITS = { id: 120, title: 200, body: 1000, source: 40, status: 40 };

export function defaultManifestPath(env = process.env) {
    return env.IYSCODEMOVIL_TASKS_FILE || path.join(os.homedir(), ".iyscodemovil", "tasks.json");
}

export function readManifest(file) {
    if (!existsSync(file)) return [];
    try {
        const parsed = JSON.parse(readFileSync(file, "utf8"));
        const tasks = Array.isArray(parsed) ? parsed : parsed?.tasks;
        return Array.isArray(tasks) ? tasks.filter((t) => t && typeof t.id === "string" && typeof t.title === "string") : [];
    } catch {
        return [];
    }
}

function clean(value, limit) {
    return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, limit);
}

/** Builds a task the phone accepts: id and title required, everything bounded. */
export function makeTask({ id, title, body = "", source = "pc", status = "completed" }, now = new Date()) {
    const cleanTitle = clean(title, FIELD_LIMITS.title);
    if (!cleanTitle) throw new Error("La tarea necesita un título.");
    return {
        id: clean(id, FIELD_LIMITS.id) || `${now.getTime().toString(36)}-${randomBytes(3).toString("hex")}`,
        title: cleanTitle,
        body: String(body ?? "").trim().slice(0, FIELD_LIMITS.body),
        source: clean(source, FIELD_LIMITS.source) || "pc",
        status: clean(status, FIELD_LIMITS.status) || "completed",
        createdAt: now.toISOString(),
    };
}

/** Newest first, one entry per id, at most MAX_TASKS. */
export function addTask(tasks, task) {
    return [task, ...tasks.filter((t) => t.id !== task.id)].slice(0, MAX_TASKS);
}

export function writeManifest(file, tasks) {
    mkdirSync(path.dirname(file), { recursive: true });
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, `${JSON.stringify({ tasks }, null, 2)}\n`, { mode: 0o600 });
    renameSync(temp, file);
}

export function etagFor(text) {
    return `"${createHash("sha256").update(text).digest("base64url").slice(0, 22)}"`;
}

/** Sends a push through ntfy (https://ntfy.sh or your own server). */
export async function sendNtfy({ server = "https://ntfy.sh", topic, task, token, fetchImpl = fetch }) {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(topic ?? "")) throw new Error("El tema de ntfy solo admite letras, números, - y _ (máximo 64).");
    const headers = {
        // HTTP headers must be ASCII; ntfy decodes RFC 2047 encoded words.
        Title: `=?UTF-8?B?${Buffer.from(`iSyCode · ${task.title}`).toString("base64")}?=`,
        Tags: task.status === "failed" ? "warning" : "white_check_mark",
    };
    if (token) headers.Authorization = `Bearer ${token}`;
    const response = await fetchImpl(`${server.replace(/\/+$/, "")}/${topic}`, {
        method: "POST",
        headers,
        body: task.body || task.status,
    });
    if (!response.ok) throw new Error(`ntfy respondió HTTP ${response.status}.`);
}

/** Serves GET /tasks.json with ETag / If-None-Match. Read-only; nothing else is exposed. */
export function createTasksServer(file) {
    return http.createServer((request, response) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (request.method !== "GET" && request.method !== "HEAD") {
            response.writeHead(405, { Allow: "GET, HEAD" }).end();
            return;
        }
        if (url.pathname !== "/tasks.json") {
            response.writeHead(404).end();
            return;
        }
        const text = `${JSON.stringify({ tasks: readManifest(file) })}\n`;
        const etag = etagFor(text);
        if (request.headers["if-none-match"] === etag) {
            response.writeHead(304, { ETag: etag }).end();
            return;
        }
        response.writeHead(200, {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-cache",
            ETag: etag,
        });
        response.end(request.method === "HEAD" ? undefined : text);
    });
}

function lanAddress() {
    for (const entries of Object.values(os.networkInterfaces())) {
        for (const entry of entries ?? []) {
            if (entry.family === "IPv4" && !entry.internal && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(entry.address)) return entry.address;
        }
    }
    return "localhost";
}

export function parseFlags(args) {
    const flags = {};
    const positional = [];
    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        if (arg.startsWith("--")) {
            const key = arg.slice(2);
            const next = args[i + 1];
            if (next === undefined || next.startsWith("--")) flags[key] = true;
            else { flags[key] = next; i += 1; }
        } else {
            positional.push(arg);
        }
    }
    return { flags, positional };
}

const NOTIFY_HELP = `uso: iyscodemovil notify "<título>" [--body texto] [--source pc.tui] [--status completed|failed]
                          [--id id] [--file ruta] [--ntfy tema] [--ntfy-server url]

  Agrega una tarea al manifiesto (${"$"}IYSCODEMOVIL_TASKS_FILE o ~/.iyscodemovil/tasks.json).
  Con --ntfy (o ${"$"}IYSCODEMOVIL_NTFY_TOPIC) también manda un push por ntfy.`;

export async function runNotifyCommand(args, env = process.env, { fetchImpl = fetch, now = new Date(), log = console.log } = {}) {
    const { flags, positional } = parseFlags(args);
    if (flags.help || positional.length === 0) {
        log(NOTIFY_HELP);
        return positional.length === 0 && !flags.help ? 2 : 0;
    }
    const file = typeof flags.file === "string" ? flags.file : defaultManifestPath(env);
    let task;
    try {
        task = makeTask({ id: flags.id, title: positional.join(" "), body: flags.body, source: flags.source, status: flags.status }, now);
    } catch (error) {
        console.error(error.message);
        return 2;
    }
    writeManifest(file, addTask(readManifest(file), task));
    log(`tarea ${task.id} guardada en ${file}`);
    const topic = typeof flags.ntfy === "string" ? flags.ntfy : env.IYSCODEMOVIL_NTFY_TOPIC;
    if (topic) {
        try {
            await sendNtfy({
                server: typeof flags["ntfy-server"] === "string" ? flags["ntfy-server"] : env.IYSCODEMOVIL_NTFY_SERVER,
                topic, task, token: env.IYSCODEMOVIL_NTFY_TOKEN, fetchImpl,
            });
            log(`push enviado por ntfy (tema ${topic})`);
        } catch (error) {
            // The task is saved either way; the phone still sees it on its next check.
            console.error(`no se pudo mandar el push: ${error.message}`);
            return 1;
        }
    }
    return 0;
}

export async function runTasksCommand(args, env = process.env) {
    const { flags, positional } = parseFlags(args);
    const file = typeof flags.file === "string" ? flags.file : defaultManifestPath(env);
    const sub = positional[0];
    if (sub === "list") {
        const tasks = readManifest(file);
        if (tasks.length === 0) console.log(`sin tareas en ${file}`);
        for (const t of tasks) console.log(`${t.createdAt ?? ""}  [${t.status ?? ""}] ${t.title}  (${t.id})`);
        return 0;
    }
    if (sub === "serve") {
        const port = Number(flags.port ?? 8787);
        const host = typeof flags.host === "string" ? flags.host : "0.0.0.0";
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
            console.error("--port debe ser un número entre 1 y 65535.");
            return 2;
        }
        const server = createTasksServer(file);
        await new Promise((resolve) => server.listen(port, host, resolve));
        console.log("");
        console.log("iyscode · tareas para el teléfono");
        console.log("────────────────────────────────────────");
        console.log(`manifiesto  ${file}`);
        console.log(`pega en el Asistente › Opciones › Tu PC:`);
        console.log("");
        console.log(`  http://${host === "0.0.0.0" ? lanAddress() : host}:${port}/tasks.json`);
        console.log("");
        console.log("Solo lectura y sin cifrar: úsalo en tu red local o por VPN, nunca expuesto a internet.");
        console.log("Ctrl+C lo detiene.");
        return server;
    }
    console.log(`uso: iyscodemovil tasks serve [--port 8787] [--host 0.0.0.0] [--file ruta]
       iyscodemovil tasks list [--file ruta]`);
    return sub ? 2 : 0;
}

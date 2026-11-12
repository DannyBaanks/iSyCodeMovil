/**
 * HTTP surface of the orchestrator. Deliberately small: five operations, no frameworks,
 * no dependencies, and no path that can reach the host filesystem.
 *
 * It binds to loopback by default. Exposing it to a network is a decision the operator
 * makes explicitly (and should put behind TLS), not something this file does on its own.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { extname, join, normalize, resolve } from "node:path";
import { homedir } from "node:os";
import { OrchestratorError, createOrchestrator } from "./orchestrator.mjs";
import { createSealedStore } from "./sealed.mjs";
import { createCredentialStore } from "./credentials.mjs";
import { describeConfiguration, instructions, requestDeviceCode, waitForToken } from "./oauth.mjs";
import { describeClientId, loadEnvFile } from "./env.mjs";
import { listRepos, whoami } from "./github.mjs";
import { open as openSealed, seal as sealBytes } from "../web/seal.mjs";
import { issueGrant, verifyGrant } from "./grant.mjs";

/**
 * The PWA is served by this same process, on this same port.
 *
 * It used to live on a second port behind a proxy, and the very first thing a person did
 * was open the API port, get `{"error":"not found"}` and reasonably conclude it was broken.
 * One process, one port, one URL: /api/* is the API and everything else is the app.
 */
const WEB_ROOT = resolve(fileURLToPath(new URL("../web", import.meta.url)), ".");
const STATIC_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  // The page imports seal.mjs: without the JS type the browser refuses to run it.
  ".mjs": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json",
};

/** One file from web/, or null. Refuses anything that tries to climb out of the folder. */
async function staticFile(pathname) {
  const safe = normalize(pathname).replace(/^(\.[./\\])+/, "");
  const file = join(WEB_ROOT, safe === "/" || safe === "." ? "index.html" : safe);
  if (!file.startsWith(WEB_ROOT)) return null;
  try {
    return { body: await readFile(file), type: STATIC_TYPES[extname(file)] ?? "application/octet-stream" };
  } catch {
    return null;
  }
}

// iSyCode patch: upstream allows 16 KiB, too small for a `write` tool call carrying a
// source file. The orchestrator still caps file content at 1 MB.
const MAX_BODY_BYTES = 2 * 1024 * 1024;

function send(res, code, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    // no caching: a sandbox state is only true for a moment
    "cache-control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new OrchestratorError("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (!chunks.length) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new OrchestratorError("body must be JSON"));
      }
    });
    req.on("error", reject);
  });
}

/** Read a body up to a limit, as raw bytes. Used for sealed blobs and work archives. */
function readRawBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new OrchestratorError(`the payload exceeds ${Math.floor(limit / 1024 / 1024)} MiB`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/** Device flows in progress, keyed by the short user_code. In memory: an unfinished login is not state. */
const pendingCodes = new Map();

export function createApi(
  orch = createOrchestrator(),
  // State lives in its own directory, not in the project tree: a sealed blob is data,
  // not source, and finding it inside the checkout invites committing it by accident.
  sealedStore = createSealedStore(process.env.MOVILCLAW_STATE ?? join(homedir(), ".movilclaw")),
  credentials = createCredentialStore({ seal: sealBytes, open: openSealed }),
) {
  return createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const parts = url.pathname.split("/").filter(Boolean); // ["api","sandboxes","<id>","snapshot"]
    try {
      // Everything that is not the API is the app itself.
      if (parts[0] !== "api") {
        const asset = await staticFile(url.pathname);
        if (asset) {
          res.writeHead(200, {
            "content-type": asset.type,
            "content-length": asset.body.length,
            "cache-control": "no-store",
          });
          return res.end(asset.body);
        }
        res.writeHead(404, { "content-type": "text/html; charset=utf-8" });
        return res.end(
          "<!doctype html><meta charset=utf-8><body style=\"font:15px system-ui;background:#120d22;color:#f2eefc;padding:24px\">" +
            "<h1>MovilClaw</h1><p>Esa ruta no existe. La app está en <a style=\"color:#00dec6\" href=\"/\">/</a> " +
            "y la API en <code>/api/health</code>.</p></body>",
        );
      }

      // GET /api/health
      if (req.method === "GET" && parts[1] === "health") {
        return send(res, 200, { ok: true, service: "movilclaw", version: 1 });
      }

      /**
       * Sign in with GitHub, on the host.
       *
       * GET  /api/auth/github          what is configured, and how to register the app
       * POST /api/auth/github/start    ask GitHub for a code to show the person
       * POST /api/auth/github/wait     wait until the person approves, then keep the token
       *
       * The token never travels to a sandbox and is never returned by any of these routes.
       */
      if (parts[1] === "auth" && parts[2] === "github") {
        if (parts.length === 3 && req.method === "GET") {
          return send(res, 200, describeConfiguration());
        }
        if (parts[3] === "start" && req.method === "POST") {
          const pending = await requestDeviceCode();
          // The device_code stays here; only the short code the person types goes back.
          // The flow is keyed by that short code, because it is the only handle the
          // browser has: asking it to echo the device_code back could never work,
          // and that is exactly what broke the first real login.
          pendingCodes.set(pending.userCode, { ...pending, startedAt: Date.now() });
          return send(res, 201, {
            ...instructions(pending),
            note: "El codigo caduca. Cuando lo autorices, MovilClaw recibe el token y lo guarda en el servidor.",
          });
        }
        if (parts[3] === "wait" && req.method === "POST") {
          const body = await readBody(req);
          const userCode = String(body.userCode ?? "").trim();
          const pending = pendingCodes.get(userCode);
          if (!pending) return send(res, 409, { error: "no hay ningun inicio de sesion en curso con ese codigo" });
          if (Date.now() - pending.startedAt > pending.expiresInMs) {
            pendingCodes.delete(userCode);
            return send(res, 409, { error: "ese codigo ya caduco; pide uno nuevo" });
          }
          try {
            const result = await waitForToken({ deviceCode: pending.deviceCode, intervalMs: pending.intervalMs });
            // Stored exactly like a pasted token: in memory, or sealed if a passphrase came.
            const stored = await credentials.put(body.id ?? "github", result.token, {
              scopes: result.scopes,
              passphrase: body.passphrase ?? null,
            });
            return send(res, 201, { ...stored, via: "github-device-flow" });
          } finally {
            // Whether it ended in a token, a denial or an expiry, the flow is over.
            pendingCodes.delete(userCode);
          }
        }
        return send(res, 404, { error: "ruta de autenticacion desconocida" });
      }

      /**
       * Host-level account: the credential store belongs to the server, not to one sandbox,
       * so saving a token must not require a sandbox to exist first. The token travels in
       * the body once and is never echoed back.
       */
      if (parts[1] === "account" && parts.length === 2) {
        if (req.method === "POST") {
          const body = await readBody(req);
          const stored = await credentials.put(body.id ?? "github", String(body.token ?? ""), {
            scopes: Array.isArray(body.scopes) ? body.scopes : [],
            expiresAt: body.expiresAt ?? null,
            passphrase: body.passphrase ?? null,
          });
          return send(res, 201, stored);
        }
        if (req.method === "GET") {
          return send(res, 200, { accounts: credentials.list() });
        }
        if (req.method === "DELETE") {
          const body = await readBody(req);
          const id = body.id ?? "github";
          if (!credentials.forget(id)) {
            return send(res, 409, { error: "no hay ninguna cuenta guardada con ese id" });
          }
          return send(res, 200, { forgotten: id });
        }
        return send(res, 405, { error: "method not allowed" });
      }

      /**
       * The person's repositories, read on the host with their token, for the picker.
       * The reply is names, dates and flags — never the token, and never a way to use it.
       */
      if (parts[1] === "repos" && parts.length === 2 && req.method === "POST") {
        const body = await readBody(req);
        const accountId = body.accountId ?? "github";
        const usable = credentials.usable(accountId);
        if (!usable.ok) return send(res, 409, { error: usable.reason });
        const token = await credentials.unlock(accountId, body.passphrase ?? null);
        const account = await whoami(token);
        const repos = await listRepos(token);
        return send(res, 200, { login: account.login, name: account.name, count: repos.length, repos });
      }

      // GET /api/sandboxes  ·  POST /api/sandboxes
      if (parts[1] === "sandboxes" && parts.length === 2) {        if (req.method === "GET") return send(res, 200, { sandboxes: await orch.list() });
        if (req.method === "POST") {
          const body = await readBody(req);
          const created = await orch.create({
            ttlMinutes: body.ttlMinutes ?? 120,
            repo: typeof body.repo === "string" ? body.repo.slice(0, 200) : "",
            branch: typeof body.branch === "string" ? body.branch.slice(0, 200) : "",
          });
          // The token is never returned here: it lives server-side and dies with the sandbox.
          return send(res, 201, { id: created.id, phase: created.state.phase });
        }
        return send(res, 405, { error: "method not allowed" });
      }

      // /api/sandboxes/<id> and its sub-operations
      if (parts[1] === "sandboxes" && parts.length >= 3) {
        const id = parts[2];
        const op = parts[3];
        if (parts.length === 3) {
          if (req.method === "GET") return send(res, 200, await orch.status(id));
          if (req.method === "DELETE") {
            const force = url.searchParams.get("force") === "1";
            return send(res, 200, await orch.destroy(id, { force }));
          }
          if (req.method === "POST") return send(res, 200, await orch.use(id));
          return send(res, 405, { error: "method not allowed" });
        }
        if (op === "snapshot" && req.method === "GET") {
          const { manifest, bytes, digest } = await orch.snapshot(id);
          res.writeHead(200, {
            "content-type": "application/json; charset=utf-8",
            "content-length": bytes.length,
            "cache-control": "no-store",
            "x-movilclaw-digest": digest,
            "content-disposition": `attachment; filename="${id}.movilclaw.json"`,
          });
          return res.end(bytes);
        }
        /** Put a local folder into the sandbox, as a package. No mount. */
        if (op === "folder" && req.method === "POST") {
          const body = await readBody(req);
          if (typeof body.directory !== "string" || !body.directory) {
            return send(res, 400, { error: "falta el directorio" });
          }
          return send(res, 200, await orch.sendFolder(id, body.directory, { subPath: body.subPath }));
        }
        /** What would be sent, and what excluded, before sending anything. */
        if (op === "folder" && req.method === "GET") {
          const directory = url.searchParams.get("directory") ?? "";
          if (!directory) return send(res, 400, { error: "falta el parametro directory" });
          return send(res, 200, await orch.previewFolder(directory));
        }
        /** Take the sandbox's work out as an archive. The user decides where it lands. */
        if (op === "work" && req.method === "GET") {
          const archive = await orch.collectWork(id, { subPath: url.searchParams.get("subPath") ?? "app" });
          res.writeHead(200, {
            "content-type": "application/gzip",
            "content-length": archive.length,
            "cache-control": "no-store",
            "content-disposition": `attachment; filename="${id}-trabajo.tar.gz"`,
          });
          return res.end(archive);
        }
        /**
         * Re-injection: the archive comes back in, raw bytes, and lands as /work/app.
         * If the person's file was sealed, the browser already opened it — this server
         * receives the same archive a plain download produced and never sees a key.
         */
        if (op === "inject" && req.method === "POST") {
          const archive = await readRawBody(req, 64 * 1024 * 1024);
          return send(res, 201, await orch.injectWork(id, archive));
        }
        /** Accounts and credentials. The token travels in the body and is never echoed. */
        if (op === "account" && req.method === "POST") {
          const body = await readBody(req);
          const stored = await credentials.put(body.id ?? "github", String(body.token ?? ""), {
            scopes: Array.isArray(body.scopes) ? body.scopes : [],
            expiresAt: body.expiresAt ?? null,
            passphrase: body.passphrase ?? null,
          });
          return send(res, 201, stored);
        }
        if (op === "account" && req.method === "GET") {
          return send(res, 200, { accounts: credentials.list() });
        }
        if (op === "account" && req.method === "DELETE") {
          return send(res, 200, { forgotten: credentials.forget(id) });
        }
        /** Clone with the host's credential. Private repositories work; the sandbox gets no token. */
        if (op === "repo-private" && req.method === "POST") {
          const body = await readBody(req);
          const usable = credentials.usable(body.accountId ?? "github");
          if (!usable.ok) return send(res, 409, { error: usable.reason });
          const token = await credentials.unlock(body.accountId ?? "github", body.passphrase);
          const result = await orch.cloneWithCredential(id, String(body.url ?? ""), token);
          return send(res, 201, result);
        }
        /** Push the work to movilclaw/<task> and open a PR. Never to main, never merged. */
        if (op === "pr" && req.method === "POST") {
          const body = await readBody(req);
          const usable = credentials.usable(body.accountId ?? "github");
          if (!usable.ok) return send(res, 409, { error: usable.reason });
          const token = await credentials.unlock(body.accountId ?? "github", body.passphrase);
          const result = await orch.pushAndOpenPr(id, {
            task: body.task, title: body.title, body: body.body,
            baseBranch: body.baseBranch ?? "main", token,
          });
          return send(res, 201, result);
        }

        /** What the sandbox may reach right now. */
        if (op === "network" && req.method === "GET") {
          return send(res, 200, await orch.network(id));
        }

        /** Clone a public repository. The network opens for this and closes right after. */
        if (op === "repo" && req.method === "POST") {
          const body = await readBody(req);
          const result = await orch.cloneRepo(id, body.url);
          return send(res, 201, result);
        }

        /** One tool call: read, write, edit, search, list, git, commit or run. */
        if (op === "tool" && req.method === "POST") {
          const body = await readBody(req);
          const name = String(body.name ?? "");
          const result = await orch.tool(id, name, body.args ?? {});
          return send(res, 200, { tool: name, result });
        }

        /**
         * Sealing. The browser sends ciphertext it produced itself; this server only
         * stores it and can never open it. That is the whole point of these routes.
         */
        if (op === "seal" && req.method === "POST") {
          const buf = await readRawBody(req, 64 * 1024 * 1024);
          const manifest = await sealedStore.put(id, buf.toString("utf8"));
          return send(res, 201, { stored: true, ...manifest });
        }
        if (op === "seal" && req.method === "GET") {
          const text = await sealedStore.get(id);
          res.writeHead(200, {
            "content-type": "application/json; charset=utf-8",
            "content-length": Buffer.byteLength(text),
            "cache-control": "no-store",
            "content-disposition": `attachment; filename="${id}.sealed.json"`,
          });
          return res.end(text);
        }
        if (op === "seal" && req.method === "DELETE") {
          await sealedStore.destroy(id);
          return send(res, 200, { destroyed: true, id });
        }

        /**
         * A time-limited signed grant: it says who may unseal and until when.
         * It carries no passphrase and cannot open anything on its own.
         */
        if (op === "grant" && req.method === "POST") {
          const body = await readBody(req);
          const minutes = Number(body.minutes ?? 30);
          if (!Number.isFinite(minutes) || minutes <= 0) {
            return send(res, 400, { error: "minutes must be a positive number" });
          }
          const grant = issueGrant(id, minutes * 60_000);
          return send(res, 201, {
            format: "movilclaw/grant/1",
            sandboxId: id,
            token: grant.token,
            expiresAt: grant.expiresAt,
            note: "el permiso dice quien puede abrir y hasta cuando; no abre nada por si solo",
          });
        }
        if (op === "grant" && req.method === "GET") {
          const verdict = verifyGrant(url.searchParams.get("token") ?? "", id);
          return send(res, verdict.ok ? 200 : 403, verdict);
        }

        if (op === "exec" && req.method === "POST") {
          // Only used for the demo of "it has no network". It is a dev affordance,
          // so it is refused unless the operator enabled it explicitly.
          if (process.env.MOVILCLAW_ALLOW_EXEC !== "1") {
            return send(res, 403, { error: "exec is disabled; set MOVILCLAW_ALLOW_EXEC=1 to enable it in development" });
          }
          const body = await readBody(req);
          const argv = Array.isArray(body.argv) ? body.argv.map(String).slice(0, 8) : [];
          if (!argv.length) return send(res, 400, { error: "argv is required" });
          const out = await orch.exec(id, argv);
          return send(res, 200, { out });
        }
        return send(res, 404, { error: "unknown operation" });
      }

      return send(res, 404, { error: "not found" });
    } catch (error) {
      const known = error instanceof OrchestratorError;
      // A refused operation is a 409: the request was understood and denied on purpose.
      const code = known ? 409 : 500;
      return send(res, code, { error: error.message, kind: known ? "refused" : "internal" });
    }
  });
}

/**
 * Start only when this file is the entry point.
 *
 * Comparing `import.meta.url` against a hand-built `file://` string looks right and is
 * wrong: the URL is percent-encoded, so a project path with a space ("ISyCo Git") never
 * matches and the server silently refuses to listen. `fileURLToPath` decodes it.
 */
const invokedDirectly =
  process.argv[1] !== undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1]);

if (invokedDirectly) {
  const port = Number(process.env.PORT ?? 8788);
  const host = process.env.HOST ?? "127.0.0.1";
  // A local .env is read first, so a client_id does not have to be retyped on every start
  // (and does not end up in a shell history). The real environment always wins over it.
  const envFile = loadEnvFile();
  if (envFile.found && envFile.loaded.length) {
    console.log(`Configuracion de ${envFile.path}: ${envFile.loaded.join(", ")}`);
  }
  const clientId = describeClientId(process.env.MOVILCLAW_GITHUB_CLIENT_ID);
  if (clientId) {
    console.log(`Inicio de sesion con GitHub: listo (client_id ${clientId.preview})`);
  } else {
    console.log("Inicio de sesion con GitHub: falta el client_id (la interfaz te dira como)");
  }

  createApi().listen(port, host, () => {
    // One URL, and it is the app. The API is behind /api on the same origin.
    console.log(`MovilClaw listo: abre http://${host}:${port} en el navegador`);
    console.log(`(la API vive en http://${host}:${port}/api/health)`);
  });
}

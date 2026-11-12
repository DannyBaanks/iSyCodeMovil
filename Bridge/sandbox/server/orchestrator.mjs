/**
 * The orchestrator: it owns sandboxes from birth to destruction.
 *
 * It wires three things that are each simple on their own and dangerous together:
 * the lifecycle state machine (lifecycle.mjs), the Docker isolation (docker.mjs) and
 * the expiry clock. Keeping them apart is what makes the "never destroy undelivered
 * work" rule testable instead of hopeful.
 *
 * `docker` and `now` are injected. The tests drive the whole thing with a fake daemon
 * and a fake clock, so expiry is proven without waiting 30 minutes.
 */
import { createHash, randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { rm } from "node:fs/promises";

const run = promisify(execFile);
import {
  PHASES, advance, canDestroy, describe, markSnapshotDelivered, newLifecycle, remainingMs, touch,
} from "./lifecycle.mjs";
import { DEFAULT_SPEC, realDocker } from "./docker.mjs";
import { PHASES as NET_PHASES, assertHostAllowed, createNetwork, describePhase } from "./network.mjs";
import { branchFor } from "./policy.mjs";
import { packWorkspace, planTransfer, unpackTar } from "./workspace.mjs";
import { cloneOnHost, pushBranchAndOpenPr } from "./github.mjs";

export class OrchestratorError extends Error {}

/** The same 64 MiB ceiling the sealed store uses: a workspace, not a disk image. */
const MAX_INJECT_BYTES = 64 * 1024 * 1024;

/** Refuse a bad id before it reaches Docker: the id becomes part of a volume name. */
function assertSafeId(id) {
  if (typeof id !== "string" || !/^mc-[a-z0-9]{4,32}$/.test(id)) {
    throw new OrchestratorError("sandbox id must look like mc-<hex>");
  }
}

export function createOrchestrator({
  docker = realDocker(),
  now = () => Date.now(),
  idFactory = () => `mc-${randomBytes(6).toString("hex")}`,
  maxSandboxes = 5,
} = {}) {
  /** In memory on purpose: a sandbox that outlives its process is not a sandbox. */
  const sandboxes = new Map();
  /** What the caller handed us: the repo and the branch they want the PR against. */
  const requests = new Map();

  function requireSandbox(id) {
    assertSafeId(id);
    const sandbox = sandboxes.get(id);
    if (!sandbox) throw new OrchestratorError(`no such sandbox: ${id}`);
    return sandbox;
  }

  /** Apply the clock to every sandbox and carry out what the state machine decided. */
  async function sweep() {
    const at = now();
    for (const [id, sandbox] of [...sandboxes]) {
      const before = sandbox.state.phase;
      const next = advance(sandbox.state, at);
      if (next.phase === before) continue;
      // Keep the whole sandbox, not just its state: name and token must survive.
      sandboxes.set(id, { ...sandbox, state: next });
      await applyEffects(sandbox, next);
    }
  }

  async function applyEffects(sandbox, next) {
    if (next.phase === sandbox.state.phase) return;
    if (next.phase === PHASES.SUSPENDED) await docker.pause(sandbox.name);
    if (next.phase === PHASES.DESTROYED) await docker.stop(sandbox.name);
  }

  return {
    /** Create a sandbox. Refuses once the host is full instead of overcommitting it. */
    async create({ ttlMinutes = 120, repo = "", branch = "" } = {}) {
      if (sandboxes.size >= maxSandboxes) {
        throw new OrchestratorError(
          `the host is at its limit of ${maxSandboxes} sandboxes; free one or wait for the clock`,
        );
      }
      const at = now();
      const id = idFactory();
      const name = `${id}-box`;
      const state = newLifecycle(id, ttlMinutes, at);
      await docker.start(name, DEFAULT_SPEC);
      const sandbox = {
        name,
        state,
        // A token is issued per sandbox and dies with it. It is never logged.
        token: issueToken(id, repo, at + state.ttlMs),
        repo,
        branch,
      };
      sandboxes.set(id, sandbox);
      requests.set(id, { repo, branch });
      return { id, name, state };
    },

    /** What the UI shows: phase, countdown and why, in words. */
    async status(id) {
      await sweep();
      const sandbox = requireSandbox(id);
      return {
        id,
        phase: sandbox.state.phase,
        remainingMs: remainingMs(sandbox.state, now()),
        explanation: describe(sandbox.state, now()),
        repo: sandbox.repo,
        snapshotDelivered: sandbox.state.snapshotDelivered,
        canDestroy: canDestroy(sandbox.state),
      };
    },

    async list() {
      await sweep();
      const at = now();
      return [...sandboxes.entries()].map(([id, sandbox]) => ({
        id,
        phase: sandbox.state.phase,
        remainingMs: remainingMs(sandbox.state, at),
        explanation: describe(sandbox.state, at),
      }));
    },

    /**
     * Any real use resets the countdown and wakes a suspended sandbox.
     * This is why a sandbox never dies while somebody is actually working.
     */
    async use(id) {
      await sweep();
      const sandbox = requireSandbox(id);
      if (sandbox.state.phase === PHASES.SUSPENDED) await docker.resume(sandbox.name);
      const next = touch(sandbox.state, now());
      sandboxes.set(id, { ...sandbox, state: next });
      return { id, phase: next.phase, remainingMs: remainingMs(next, now()) };
    },

    /**
     * Hand over the snapshot and only then allow destruction.
     * Returns bytes the client saves; the caller decides where.
     */
    async snapshot(id) {
      await sweep();
      const sandbox = requireSandbox(id);
      if (sandbox.state.phase === PHASES.DESTROYED) {
        throw new OrchestratorError("sandbox is already destroyed");
      }
      const manifest = {
        format: "movilclaw/snapshot/1",
        id,
        repo: sandbox.repo,
        branch: sandbox.branch,
        takenAt: now(),
        // Where the work would be re-injected: a new sandbox mounts this volume name.
        volume: `${sandbox.name}-work`,
      };
      const body = Buffer.from(JSON.stringify(manifest, null, 2), "utf8");
      const next = markSnapshotDelivered(sandbox.state, now());
      sandboxes.set(id, { ...sandbox, state: next });
      return { manifest, bytes: body, digest: sha256(body) };
    },

    /** Destroy now, by hand. Refuses while the work has not been handed over. */
    async destroy(id, { force = false } = {}) {
      await sweep();
      const sandbox = requireSandbox(id);
      if (sandbox.state.phase === PHASES.DESTROYED) return { id, phase: PHASES.DESTROYED };
      if (!force && !canDestroy(sandbox.state)) {
        throw new OrchestratorError(
          "refusing to destroy: the snapshot has not been delivered. Download it first (or pass force)",
        );
      }
      await docker.stop(sandbox.name);
      const next = { ...sandbox.state, phase: PHASES.DESTROYED, phaseChangedAt: now() };
      sandboxes.set(id, { ...sandbox, state: next });
      return { id, phase: PHASES.DESTROYED };
    },

    /**
     * Put a local folder INTO the sandbox as a package.
     *
     * The host packs it, the sandbox unpacks it: no bind mount, so the sandbox never has a
     * path into the machine. Secrets are excluded by `packWorkspace`, and the report says
     * what was left out.
     */
    async sendFolder(id, directory, { subPath = "app" } = {}) {
      const sandbox = requireSandbox(id);
      const plan = await planTransfer(directory);
      const archive = await packWorkspace(directory);
      if (!archive?.length) throw new OrchestratorError("no se pudo empaquetar la carpeta (esta vacia?)");

      // The archive is piped into the container through stdin: no bind mount, and no
      // command line big enough to hit the argv limit (spawn E2BIG).
      const target = `/work/${String(subPath).replace(/[^a-zA-Z0-9._-]/g, "")}`;
      const result = await docker.runCommand(sandbox.name, [
        "sh", "-c",
        `mkdir -p ${target} && tar -xzf - -C ${target}`,
      ], { timeoutMs: 300_000, input: archive });
      if (result.code !== 0) {
        throw new OrchestratorError(`no se pudo meter la carpeta: ${result.err.slice(0, 200)}`);
      }
      const listing = await docker.runCommand(sandbox.name, ["ls", "-1", target]);
      return {
        into: target,
        files: plan.files,
        packedBytes: plan.packedBytes,
        excluded: plan.excludedExamples,
        note: plan.note,
        contents: listing.out.split("\n").filter(Boolean).slice(0, 40),
      };
    },

    /** What would be sent, and what would be excluded, before sending anything. */
    async previewFolder(directory) {
      return planTransfer(directory);
    },

    /**
     * Take the sandbox's work OUT as an archive.
     *
     * The caller saves it; nothing is written into the user's repository automatically.
     */
    async collectWork(id, { subPath = "app" } = {}) {
      const sandbox = requireSandbox(id);
      const target = `/work/${String(subPath).replace(/[^a-zA-Z0-9._-]/g, "")}`;
      const b64 = await docker.runCommand(sandbox.name, ["sh", "-c", `tar -czf - -C ${target} . | base64 -w0`], {
        timeoutMs: 300_000,
      });
      if (b64.code !== 0 || !b64.out.trim()) {
        throw new OrchestratorError("no hay nada que recoger en esa carpeta");
      }
      return Buffer.from(b64.out.trim(), "base64");
    },

    /**
     * Re-injection: put a previously collected work archive INTO a fresh sandbox.
     *
     * This closes the loop the download alone left open: `collectWork` hands the person
     * an archive, and this mounts its contents back as /work/app so the work continues
     * where it stopped. The bytes arrive from the caller (the browser, which opened the
     * seal itself — the server never decrypts anything) and travel in through stdin,
     * the same channel as `sendFolder`: no bind mount, no path into the host machine,
     * and nothing that can overflow the command line.
     */
    async injectWork(id, archive) {
      await sweep();
      const sandbox = requireSandbox(id);
      if (sandbox.state.phase === PHASES.DESTROYED) {
        throw new OrchestratorError("sandbox is already destroyed; create a new one and inject into it");
      }
      if (!Buffer.isBuffer(archive) || !archive.length) {
        throw new OrchestratorError("el archivo esta vacio");
      }
      if (archive.length > MAX_INJECT_BYTES) {
        throw new OrchestratorError(`el archivo supera el limite de ${MAX_INJECT_BYTES / 1024 / 1024} MiB`);
      }
      if (sandbox.state.phase === PHASES.SUSPENDED) await docker.resume(sandbox.name);
      const result = await docker.runCommand(sandbox.name, [
        "sh", "-c",
        `rm -rf /work/app && mkdir -p /work/app && tar -xzf - -C /work/app`,
      ], { timeoutMs: 300_000, input: archive });
      if (result.code !== 0) {
        throw new OrchestratorError(`no se pudo reinyectar el trabajo: ${result.err.slice(0, 200)}`);
      }
      const next = touch(sandbox.state, now());
      sandboxes.set(id, { ...sandbox, state: next });
      const listing = await docker.runCommand(sandbox.name, ["ls", "-1", "/work/app"]);
      return {
        into: "/work/app",
        bytes: archive.length,
        files: listing.out.split("\n").filter(Boolean).slice(0, 40),
      };
    },

    /**
     * Clone a repository using the HOST's credentials, then hand the code to the sandbox.
     *
     * With a token this works for private repositories too. Either way the sandbox receives
     * files with no credentials in them: the host clones, strips the remote, and only then
     * does the archive travel.
     */
    async cloneWithCredential(id, remoteUrl, token) {
      await sweep();
      const sandbox = requireSandbox(id);
      const cloned = await cloneOnHost({ remoteUrl, token });
      try {
        const archive = await packWorkspace(cloned.dir);
        const result = await docker.runCommand(sandbox.name, [
          "sh", "-c",
          `rm -rf /work/app && mkdir -p /work/app && tar -xzf - -C /work/app`,
        ], { timeoutMs: 300_000, input: archive });
        if (result.code !== 0) throw new OrchestratorError(`no se pudo entregar el codigo: ${result.err.slice(0, 200)}`);
        sandbox.repo = `${cloned.owner}/${cloned.repo}`;
        sandbox.repoCommit = cloned.commit;
        // Prove it: the sandbox must not hold the token anywhere.
        const leak = await docker.runCommand(sandbox.name, [
          "sh", "-c",
          `grep -rlE 'ghp_|gho_|github_pat_|x-access-token|Authorization' /work 2>/dev/null | head -5`,
        ]);
        return {
          repo: sandbox.repo,
          commit: cloned.commit,
          branch: cloned.branch,
          credentialsInSandbox: leak.out.trim() ? leak.out.trim().split("\n") : [],
        };
      } finally {
        // The host's temporary clone never outlives the operation.
        await rm(cloned.dir, { recursive: true, force: true }).catch(() => {});
      }
    },

    /**
     * Push the sandbox's work to `movilclaw/<task>` and open a pull request.
     *
     * The host does both with its own credential, and the branch rule is enforced before a
     * single byte leaves the machine: `main` is not a target.
     */
    async pushAndOpenPr(id, { task = "", title = "", body = "", baseBranch = "main", token } = {}) {
      await sweep();
      const sandbox = requireSandbox(id);
      const branch = branchFor(task || sandbox.repo || "cambios");

      // Bring the work out of the sandbox onto the host, into a fresh clone with the remote.
      const work = await cloneOnHost({ remoteUrl: `https://github.com/${sandbox.repo}`, token });
      try {
        const archive = await this.collectWork(id);
        // spawn, not execFile-with-input. The latter hung here forever and stalled every
        // push-and-open-PR: the branch never appeared and no error was ever raised. This
        // was the second place with the same mistake, and it is the one that mattered.
        await unpackTar(work.dir, archive);
        const result = await pushBranchAndOpenPr({
          workDir: work.dir,
          token,
          branch,
          baseBranch,
          title: title || `movilclaw: ${task || "cambios del agente"}`,
          body,
        });
        return { ...result, commit: sandbox.repoCommit ?? null };
      } finally {
        await rm(work.dir, { recursive: true, force: true }).catch(() => {});
      }
    },

    /** Used by the isolation tests to run a command inside a sandbox. */
    async exec(id, argv) {
      const sandbox = requireSandbox(id);
      return docker.exec(sandbox.name, argv);
    },

    /** What the sandbox may reach right now, in words, for the UI and the API. */
    async network(id) {
      const sandbox = requireSandbox(id);
      return describePhase(sandbox.netPhase ?? NET_PHASES.CLOSED);
    },

    /**
     * Clone a public repository into the sandbox.
     *
     * Sequence, and the order matters: open the network for one destination, clone, close it
     * again **even if the clone fails**. A sandbox that stayed open after an error would be
     * the worst kind of bug: silent and permanent.
     */
    async cloneRepo(id, url) {
      await sweep();
      const sandbox = requireSandbox(id);
      const parsed = parseRepoUrl(url);
      const network = createNetwork(docker);

      sandbox.netPhase = NET_PHASES.REPO;
      await network.setPhase(sandbox.name, NET_PHASES.REPO);
      try {
        assertHostAllowed(NET_PHASES.REPO, parsed.host);
        // --depth 1: a sandbox needs a working tree, not the whole history.
        const result = await docker.runCommand(
          sandbox.name,
          ["git", "clone", "--depth", "1", parsed.cloneUrl, "/work/app"],
          { timeoutMs: 300_000 },
        );
        const target = parsed.branch ? ["-C", "/work/app", "checkout", parsed.branch] : null;
        const checkout = target ? await docker.runCommand(sandbox.name, ["git", ...target]) : { code: 0 };
        const head = await docker.runCommand(sandbox.name, ["git", "-C", "/work/app", "log", "-1", "--format=%H %s"]);
        sandbox.repo = `${parsed.owner}/${parsed.repo}`;
        sandbox.repoCommit = head.out.trim();
        if (result.code !== 0) {
          throw new OrchestratorError(`git clone fallo: ${(result.err || result.out).slice(0, 300)}`);
        }
        if (checkout.code !== 0) {
          throw new OrchestratorError(`la rama ${parsed.branch} no existe en ese repositorio`);
        }
        return {
          repo: sandbox.repo,
          url: parsed.canonical,
          branch: parsed.branch ?? null,
          commit: sandbox.repoCommit,
          files: (await docker.runCommand(sandbox.name, ["ls", "/work/app"])).out.split("\n").filter(Boolean).slice(0, 40),
        };
      } finally {
        // Whatever happened above, the door closes here. This is the guarantee.
        sandbox.netPhase = NET_PHASES.CLOSED;
        await network.setPhase(sandbox.name, NET_PHASES.CLOSED);
      }
    },

    /**
     * The tools the agent works with. Every one is a fixed argv: the caller picks which
     * tool and its arguments, and never composes a shell command.
     */
    async tool(id, name, args = {}) {
      await sweep();
      const sandbox = requireSandbox(id);
      const repo = "/work/app";

      switch (name) {
        case "read": {
          const path = safePath(args.path);
          await resolveInsideRepo(docker, sandbox.name, repo, path);
          const result = await docker.runCommand(sandbox.name, ["cat", `${repo}/${path}`], { timeoutMs: 30_000 });
          if (result.code !== 0) throw new OrchestratorError(`no se puede leer ${path}`);
          // Bounded: a 200 MB file must not travel through the API.
          return { path, content: result.out.slice(0, 200_000), truncated: result.out.length > 200_000 };
        }
        case "write": {
          const path = safePath(args.path);
          // Checked before writing, not after: a link pointing outside must not be overwritten.
          await resolveInsideRepo(docker, sandbox.name, repo, path);
          const content = typeof args.content === "string" ? args.content : "";
          if (content.length > 1_000_000) throw new OrchestratorError("el contenido supera 1 MB");
          // Written through a file, not a shell, so the content is never parsed as code.
          // The base64 travels in on stdin, never on the command line.
          const encoded = Buffer.from(content, "utf8").toString("base64");
          const targetFile = `${repo}/${path}`;
          const result = await docker.runCommand(sandbox.name, [
            "sh", "-c",
            'mkdir -p "$(dirname "$1")" && base64 -d > "$1"',
            "write",
            targetFile,
          ], { input: encoded });
          if (result.code !== 0) throw new OrchestratorError(`no se puede escribir ${path}: ${result.err.slice(0, 200)}`);
          return { path, bytes: Buffer.byteLength(content, "utf8") };
        }
        case "list": {
          const path = safePath(args.path ?? ".", true);
          await resolveInsideRepo(docker, sandbox.name, repo, path);
          const result = await docker.runCommand(sandbox.name, ["ls", "-la", `${repo}/${path}`]);
          return { path, listing: result.out };
        }
        case "search": {
          const query = String(args.query ?? "").slice(0, 200);
          if (!query) throw new OrchestratorError("search necesita un texto");
          // ripgrep is in the image for exactly this. Fixed argv, no shell.
          const result = await docker.runCommand(sandbox.name, [
            "rg", "--line-number", "--no-heading", "--max-count", "200", "--", query, repo,
          ]);
          return { query, matches: result.out.slice(0, 100_000), count: result.out.split("\n").filter(Boolean).length };
        }
        case "edit": {
          // A precise replacement: find the old text, put the new one in its place.
          const path = safePath(args.path);
          await resolveInsideRepo(docker, sandbox.name, repo, path);
          const from = typeof args.from === "string" ? args.from : "";
          const to = typeof args.to === "string" ? args.to : "";
          if (!from) throw new OrchestratorError("edit necesita el texto a reemplazar");
          const read = await docker.runCommand(sandbox.name, ["cat", `${repo}/${path}`]);
          if (read.code !== 0) throw new OrchestratorError(`no se puede leer ${path}`);
          const occurrences = read.out.split(from).length - 1;
          if (occurrences === 0) throw new OrchestratorError("el texto a reemplazar no aparece en el archivo");
          if (occurrences > 1) throw new OrchestratorError(`el texto aparece ${occurrences} veces; usa mas contexto`);
          const updated = read.out.replace(from, to);
          const encoded = Buffer.from(updated, "utf8").toString("base64");
          const targetFile = `${repo}/${path}`;
          await docker.runCommand(sandbox.name, [
            "sh", "-c", 'base64 -d > "$1"',
            "edit",
            targetFile,
          ], { input: encoded });
          return { path, replaced: 1 };
        }
        case "git": {
          // A closed list of read-only and staging operations. Commit and push come later.
          const allowed = {
            status: ["status", "--short"],
            diff: ["diff"],
            staged: ["diff", "--cached"],
            log: ["log", "--oneline", "-20"],
            branch: ["branch", "--show-current"],
            stage: ["add", "-A"],
          };
          const argv = allowed[args.op];
          if (!argv) throw new OrchestratorError(`git ${args.op} no esta permitido`);
          const result = await docker.runCommand(sandbox.name, ["git", "-C", repo, ...argv]);
          return { op: args.op, code: result.code, out: (result.out || result.err).slice(0, 100_000) };
        }
        case "commit": {
          const message = String(args.message ?? "").slice(0, 500);
          if (!message) throw new OrchestratorError("commit necesita un mensaje");
          await docker.runCommand(sandbox.name, ["git", "-C", repo, "add", "-A"]);
          const result = await docker.runCommand(sandbox.name, ["git", "-C", repo, "commit", "-m", message]);
          if (result.code !== 0) throw new OrchestratorError(`no se pudo commitear: ${(result.err || result.out).slice(0, 200)}`);
          const head = await docker.runCommand(sandbox.name, ["git", "-C", repo, "log", "-1", "--format=%H %s"]);
          return { commit: head.out.trim() };
        }
        case "run": {
          // Run a program inside the sandbox. The argv is a list; there is no shell.
          const argv = Array.isArray(args.argv) ? args.argv.map(String).slice(0, 40) : [];
          if (!argv.length) throw new OrchestratorError("run necesita argv");
          const result = await docker.runCommand(sandbox.name, ["sh", "-c", `cd ${repo} && exec "$@"`, "run", ...argv], {
            timeoutMs: Math.min(Number(args.timeoutMs) || 120_000, 600_000),
          });
          return { code: result.code, out: result.out.slice(0, 200_000), err: result.err.slice(0, 20_000) };
        }
        default:
          throw new OrchestratorError(`tool desconocida: ${name}`);
      }
    },
  };
}

/**
 * Accept only a public repository URL over HTTPS from a known code host.
 *
 * Refused on purpose, each for a reason: plain http (no integrity), ssh (would need keys),
 * any other host (the sandbox is not a general-purpose fetcher), and anything pointing at
 * a local or private address (a sandbox must not be able to reach into the host's network).
 */
export function parseRepoUrl(input) {
  let url;
  try {
    url = new URL(String(input ?? "").trim());
  } catch {
    throw new OrchestratorError("la direccion del repositorio no es una URL valida");
  }
  if (url.protocol !== "https:") {
    throw new OrchestratorError("solo se aceptan repositorios por https");
  }
  if (url.username || url.password) {
    throw new OrchestratorError("la URL no debe llevar credenciales");
  }
  const host = url.hostname.toLowerCase();
  if (host !== "github.com") {
    throw new OrchestratorError("por ahora solo se aceptan repositorios de github.com");
  }
  const parts = url.pathname.replace(/^\/+|\.git$/g, "").split("/").filter(Boolean);
  if (parts.length < 2) {
    throw new OrchestratorError("la URL debe ser del tipo https://github.com/usuario/repositorio");
  }
  const [owner, repo] = parts;
  const branch = parts[2] === "tree" && parts[3] ? parts.slice(3).join("/") : null;
  return {
    host,
    owner,
    repo,
    branch,
    cloneUrl: `https://github.com/${owner}/${repo}.git`,
    canonical: `https://github.com/${owner}/${repo}`,
  };
}

/** A repository-relative path, with no way out of /work/app. */
/**
 * A repository-relative path, with no way out of `/work/app`.
 *
 * The textual checks below are necessary and **not sufficient**, which a test caught: a
 * symbolic link *inside* the repository that points outside it keeps its textual path
 * inside, so it passes every string check while the real file is somewhere else. Measured,
 * not theorised: `ln -s /work/secreto.txt app/enlace.txt` was readable through the tools.
 *
 * So the caller must also resolve the path inside the sandbox, where the links actually
 * are, with `resolveInsideRepo` below.
 */
function safePath(value, allowRoot = false) {
  const path = String(value ?? "").trim();
  if (!path || path === ".") {
    if (allowRoot) return ".";
    throw new OrchestratorError("falta la ruta");
  }
  if (path.startsWith("/") || path.includes("..") || path.includes("\0") || path.includes("\n") || path.includes("\r")) {
    throw new OrchestratorError("la ruta debe ser relativa y quedarse dentro del repositorio");
  }
  return path.replace(/^\.\//, "");
}

/**
 * Ask the sandbox itself where a path really lands, and refuse anything that leaves the repo.
 *
 * `readlink -f` resolves every link in the path, so a symlink pointing outside shows up as
 * an outside path. The comparison is done on the resolved form, which is the only form that
 * describes the file that would actually be read or written.
 */
async function resolveInsideRepo(docker, container, repo, relative) {
  const probe = await docker.runCommand(container, [
    "sh", "-c",
    // -m so a not-yet-existing file is still resolved as far as it can be (the write case).
    `readlink -m -- ${JSON.stringify(`${repo}/${relative}`)}`,
  ]);
  const resolved = probe.out.trim();
  if (!resolved) {
    throw new OrchestratorError("no se pudo comprobar la ruta dentro del repositorio");
  }
  if (resolved !== repo && !resolved.startsWith(`${repo}/`)) {
    throw new OrchestratorError(
      "esa ruta apunta fuera del repositorio (un enlace), asi que no se toca",
    );
  }
  return relative;
}

/** Exported for the policy tests: the path rule must be testable on its own. */
export const safePathForTests = safePath;

/** A token that only ever unlocks one repo, and expires with the sandbox. */
function issueToken(id, repo, expiresAt) {
  const raw = randomBytes(32).toString("base64url");
  return {
    // Only the digest is kept; the raw value is returned once and never stored in logs.
    digest: createHash("sha256").update(raw).digest("hex"),
    repo,
    expiresAt,
  };
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

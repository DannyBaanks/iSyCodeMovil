/**
 * `link --runtime sandbox`: disposable Docker sandboxes on this computer, driven from the phone.
 *
 * The phone keeps the agent (the model and the conversation). This computer keeps the
 * hands: every tool call runs inside a container with no network, no host mounts and no
 * credentials. Cloning private repositories and opening pull requests are done by the
 * host, with a GitHub token that never enters a sandbox and never travels to the phone.
 *
 * The orchestrator under ../sandbox/ comes from MovilClaw. On its own it has no
 * authentication, because it was written to listen on loopback. This file is what makes
 * it reachable from a phone: one bearer token, checked on every request, and a private
 * (Tailscale) address to listen on.
 */
import { execFile, execFileSync, spawnSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { isTailscaleIPv4 } from "./grok_bridge.mjs";
import { createApi } from "../sandbox/server/api.mjs";
import { createCredentialStore } from "../sandbox/server/credentials.mjs";
import { OrchestratorError, createOrchestrator } from "../sandbox/server/orchestrator.mjs";
import { createSealedStore } from "../sandbox/server/sealed.mjs";
import { open as openSealed, seal as sealBytes } from "../sandbox/web/seal.mjs";

const run = promisify(execFile);

export const SANDBOX_IMAGE = "movilclaw/sandbox:latest";
const IMAGE_CONTEXT = fileURLToPath(new URL("../sandbox/server", import.meta.url));

function isLoopback(host) {
    return host === "127.0.0.1" || host === "localhost";
}

/** The API is plain HTTP, so it only listens on loopback or on the encrypted tailnet. */
export function assertSandboxTransport(resolved) {
    const host = resolved?.host;
    if (isLoopback(host)) return;
    if (!resolved?.tailscale || !isTailscaleIPv4(host)) {
        throw new Error("The sandbox API is plain HTTP and carries a bearer token. Use --host tailscale so it only listens on the encrypted VPN.");
    }
}

export function buildSandboxPairingURL({ host, port, token, directory }) {
    const query = new URLSearchParams({ host, port: String(port), token, directory });
    // Same reason as the other runtimes: iOS keeps `+` literal in custom-scheme queries.
    return `isysandbox://pair?${query.toString().replaceAll("+", "%20")}`;
}

/** `owner/name` of a github.com remote, or null. Accepts https and ssh spellings. */
export function parseGitHubRemote(remoteUrl) {
    const match = /github\.com[/:]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(String(remoteUrl ?? "").trim());
    if (!match) return null;
    return { owner: match[1], repo: match[2], fullName: `${match[1]}/${match[2]}`, url: `https://github.com/${match[1]}/${match[2]}` };
}

/** What the linked folder is, so the phone can offer "clone this project" without typing. */
export async function describeProject(directory, exec = run) {
    const git = async (args) => {
        try {
            const { stdout } = await exec("git", ["-C", directory, ...args], { timeout: 10_000 });
            return String(stdout).trim();
        } catch {
            return "";
        }
    };
    const remote = parseGitHubRemote(await git(["remote", "get-url", "origin"]));
    const head = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]);
    return {
        name: path.basename(directory),
        repo: remote?.fullName ?? null,
        repoUrl: remote?.url ?? null,
        defaultBranch: head.startsWith("origin/") ? head.slice("origin/".length) : null,
    };
}

function tokenDigest(value) {
    return createHash("sha256").update(String(value), "utf8").digest();
}

function bearerOf(req) {
    const header = req.headers.authorization;
    if (typeof header !== "string") return null;
    const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
    return match ? match[1] : null;
}

function sendJSON(res, code, payload) {
    const body = JSON.stringify(payload);
    res.writeHead(code, {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(body),
        "cache-control": "no-store",
    });
    res.end(body);
}

/**
 * The only thing between the network and the orchestrator.
 *
 * - Every request needs the bearer token, compared in constant time. No route is exempt,
 *   so an unauthenticated caller learns nothing, not even that this is a sandbox host.
 * - Nothing outside `/api/` is served.
 * - The `folder` routes are answered here and pinned to the linked project. Upstream they
 *   accept any directory, which is fine on loopback and would be a way to read the whole
 *   disk for whoever holds the token.
 */
export function createSandboxGateway({ token, api, orchestrator, credentials, directory, project }) {
    const expected = tokenDigest(token);
    return http.createServer(async (req, res) => {
        const url = new URL(req.url ?? "/", "http://localhost");
        const presented = bearerOf(req);
        if (!presented || !timingSafeEqual(tokenDigest(presented), expected)) {
            return sendJSON(res, 401, { error: "unauthorized" });
        }
        const parts = url.pathname.split("/").filter(Boolean);
        if (parts[0] !== "api") return sendJSON(res, 404, { error: "not found" });

        try {
            if (parts.length === 2 && parts[1] === "bridge" && req.method === "GET") {
                return sendJSON(res, 200, {
                    service: "isycode-sandbox",
                    version: 1,
                    project: await project(),
                    github: credentials.usable("github").ok,
                });
            }
            if (parts[1] === "sandboxes" && parts[3] === "folder" && parts.length === 4) {
                req.resume(); // any `directory` the caller sent is ignored on purpose
                if (req.method === "GET") return sendJSON(res, 200, await orchestrator.previewFolder(directory));
                if (req.method === "POST") return sendJSON(res, 200, await orchestrator.sendFolder(parts[2], directory));
                return sendJSON(res, 405, { error: "method not allowed" });
            }
        } catch (error) {
            const refused = error instanceof OrchestratorError;
            return sendJSON(res, refused ? 409 : 500, { error: error.message, kind: refused ? "refused" : "internal" });
        }
        api.emit("request", req, res);
    });
}

/**
 * Files that look like secrets never travel into a sandbox. Git inside the sandbox then
 * sees every tracked one as deleted, and the agent's `commit` (which stages everything)
 * would put those deletions into the pull request. Marking them assume-unchanged keeps
 * them out of every later `git add`, in the sandbox and on the host that pushes.
 */
const KEEP_EXCLUDED_FILES = [
    "sh", "-c",
    "cd /work/app && [ -d .git ] && git ls-files -d -z | xargs -0 -r git update-index --assume-unchanged -- || true",
];

/**
 * A linked folder brings its own `.git/config`, and some people keep a token inside the
 * remote URL. The sandbox needs no remote at all (the host pushes), so any `user:pass@`
 * is cut out before the agent can read it.
 */
const STRIP_REMOTE_CREDENTIALS = [
    "sh", "-c",
    "[ -f /work/app/.git/config ] && sed -i -E 's#(https?://)[^/@[:space:]]+@#\\1#' /work/app/.git/config || true",
];

export function keepingExcludedFiles(orchestrator) {
    const settle = async (id) => {
        await orchestrator.exec(id, KEEP_EXCLUDED_FILES).catch(() => {});
    };
    return {
        ...orchestrator,
        async sendFolder(id, ...rest) {
            const result = await orchestrator.sendFolder(id, ...rest);
            await orchestrator.exec(id, STRIP_REMOTE_CREDENTIALS).catch(() => {});
            await settle(id);
            return result;
        },
        async cloneWithCredential(id, ...rest) {
            const result = await orchestrator.cloneWithCredential(id, ...rest);
            await settle(id);
            return result;
        },
    };
}

/** A GitHub token already on this computer, if there is one. It is never printed. */
export function discoverGitHubToken(env = process.env, exec = execFileSync) {
    if (env.ISYCODE_SANDBOX_NO_GITHUB === "1") return null;
    for (const name of ["GITHUB_TOKEN", "GH_TOKEN"]) {
        if (env[name]?.trim()) return { token: env[name].trim(), source: name };
    }
    try {
        const token = String(exec("gh", ["auth", "token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })).trim();
        if (token) return { token, source: "gh auth token" };
    } catch { /* gh is optional */ }
    return null;
}

function ensureDocker() {
    const version = spawnSync("docker", ["version", "--format", "{{.Server.Version}}"], { encoding: "utf8" });
    if (version.error || version.status !== 0 || !version.stdout.trim()) {
        throw new Error("Docker is not running. Start Docker and run the link again.");
    }
    const image = spawnSync("docker", ["image", "inspect", SANDBOX_IMAGE], { stdio: "ignore" });
    if (image.status === 0) return;
    console.log(`building ${SANDBOX_IMAGE} (first run only)…`);
    const build = spawnSync("docker", ["build", "-t", SANDBOX_IMAGE, IMAGE_CONTEXT], { stdio: "inherit" });
    if (build.status !== 0) throw new Error("Could not build the sandbox image.");
}

export async function startSandboxLink({ host, port, directory, env = process.env }) {
    ensureDocker();

    const token = randomBytes(32).toString("base64url");
    const orchestrator = keepingExcludedFiles(createOrchestrator());
    const credentials = createCredentialStore({ seal: sealBytes, open: openSealed });
    const sealedStore = createSealedStore(env.ISYCODE_SANDBOX_STATE ?? path.join(os.homedir(), ".isycode-movil", "sandbox"));
    const api = createApi(orchestrator, sealedStore, credentials);

    let github = discoverGitHubToken(env);
    let githubProblem = null;
    if (github) {
        try {
            await credentials.put("github", github.token);
        } catch (error) {
            // A token this computer cannot use must not stop the sandboxes from working.
            githubProblem = `the token from ${github.source} was not usable (${error.message})`;
            github = null;
        }
    }

    const gateway = createSandboxGateway({
        token,
        api,
        orchestrator,
        credentials,
        directory,
        project: () => describeProject(directory),
    });
    await new Promise((resolve, reject) => {
        gateway.once("error", reject);
        gateway.listen(port, host, resolve);
    });

    const project = await describeProject(directory);
    console.log("");
    console.log("iyscode native / sandbox link");
    console.log("────────────────────────────────────────");
    console.log("runtime   Sandbox (Docker, on this computer)");
    console.log(`project   ${directory}${project.repo ? `  (${project.repo})` : ""}`);
    console.log(`server    http://${host}:${port}${isLoopback(host) ? "  (loopback only)" : "  (via Tailscale)"}`);
    console.log(github
        ? `github    using the token from ${github.source}; it stays on this computer`
        : `github    ${githubProblem ?? "no token found"}: public repositories only, and no pull requests`);
    console.log("Sandboxes have no network, no access to this disk and no credentials.");
    console.log("Pull requests go to a movilclaw/<task> branch and are never merged for you.");
    console.log("");
    console.log("paste this into the iPhone app:");
    console.log("");
    console.log(buildSandboxPairingURL({ host, port, token, directory }));
    console.log("");
    console.log("Do not forward this link. Keep this terminal open; Ctrl+C stops the link and destroys its sandboxes.");
    console.log("────────────────────────────────────────");
    console.log("");

    let stopping = false;
    const stop = async () => {
        if (stopping) return;
        stopping = true;
        gateway.close();
        // A sandbox must not outlive the process that owns it.
        for (const sandbox of await orchestrator.list().catch(() => [])) {
            await orchestrator.destroy(sandbox.id, { force: true }).catch((error) => {
                console.error(`could not destroy ${sandbox.id}: ${error.message}`);
            });
        }
        process.exit(0);
    };
    for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, stop);
    return gateway;
}

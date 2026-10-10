#!/usr/bin/env node
import { execFileSync, execSync, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { assertGrokTransport, startGrokLink } from "./grok_bridge.mjs";

const RUNTIMES = {
    opencode: {
        label: "OpenCode",
        check: () => true,
        args: (port, dir) => ["serve", "--hostname", "0.0.0.0", "--port", String(port), "--mdns"],
        executable: "opencode",
        shell: process.platform === "win32",
        cwd: (dir) => dir,
        env: (env, username, password) => ({ ...env, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }),
    },
    openisy: {
        label: "OpenISy",
        check: (root) => Boolean(root) && existsSync(path.join(root, "packages", "opencode", "src", "index.ts")),
        args: (port, dir, root) => ["--cwd", path.join(root, "packages", "opencode"), "src/index.ts", "serve", "--hostname", "0.0.0.0", "--port", String(port), "--mdns"],
        executable: "bun",
        shell: false,
        cwd: (dir) => dir,
        env: (env, username, password) => ({ ...env, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }),
    },
    crush: { label: "Crush", check: () => false, args: () => [], executable: "crush", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Crush server mode not yet available." },
    codex: {
        label: "Codex",
        check: () => true,
        args: (port, dir, _root, host, tokenSHA256) => ["app-server", "--listen", `ws://${host}:${port}`, "--ws-auth", "capability-token", "--ws-token-sha256", tokenSHA256],
        executable: "codex",
        shell: false,
        cwd: (dir) => dir,
        env: (env) => env,
    },
    "claude-code": { label: "Claude Code", check: () => false, args: () => [], executable: "claude-code", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Claude Code server mode not yet available." },
    gemini: { label: "Gemini", check: () => false, args: () => [], executable: "gemini", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Gemini CLI server mode not yet available." },
    grok: {
        label: "Grok",
        check: () => true,
        args: () => [],
        executable: "grok",
        shell: false,
        cwd: (dir) => dir,
        env: (env) => env,
    },
};

function readDeclaredMethods(schemaPath) {
    const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
    const methods = new Set();
    const visit = (node) => {
        if (Array.isArray(node)) {
            for (const value of node) visit(value);
            return;
        }
        if (!node || typeof node !== "object") return;
        const method = node.properties?.method;
        for (const value of method?.enum ?? []) methods.add(value);
        for (const value of Object.values(node)) visit(value);
    };
    visit(schema);
    return methods;
}

export function inspectCodex(executable = "codex", tempRoot = os.tmpdir()) {
    const run = (args) => execFileSync(executable, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    const version = run(["--version"]);
    const help = run(["app-server", "--help"]);
    if (!help.includes("--listen") || !help.includes("--ws-auth") || !help.includes("--ws-token-sha256")) {
        throw new Error("Installed Codex App Server does not demonstrate authenticated WebSocket listener support.");
    }

    const schemaDir = mkdtempSync(path.join(tempRoot, "iyscodemovil-codex-schema-"));
    try {
        run(["app-server", "generate-json-schema", "--experimental", "--out", schemaDir]);
        const clientRequests = readDeclaredMethods(path.join(schemaDir, "ClientRequest.json"));
        const serverRequests = readDeclaredMethods(path.join(schemaDir, "ServerRequest.json"));
        const serverNotifications = readDeclaredMethods(path.join(schemaDir, "ServerNotification.json"));
        const protocolSchema = readFileSync(path.join(schemaDir, "codex_app_server_protocol.schemas.json"));
        const declared = (set, ...names) => names.every((name) => set.has(name));
        const profile = {
            profileVersion: 1,
            initialize: declared(clientRequests, "initialize"),
            threadList: declared(clientRequests, "thread/list"),
            threadStart: declared(clientRequests, "thread/start"),
            threadResume: declared(clientRequests, "thread/resume"),
            threadRead: declared(clientRequests, "thread/read"),
            turnStart: declared(clientRequests, "turn/start"),
            turnInterrupt: declared(clientRequests, "turn/interrupt"),
            textStreaming: declared(serverNotifications, "item/agentMessage/delta", "turn/completed"),
            commandApproval: declared(serverRequests, "item/commandExecution/requestApproval")
                && existsSync(path.join(schemaDir, "CommandExecutionRequestApprovalResponse.json")),
            fileApproval: declared(serverRequests, "item/fileChange/requestApproval")
                && existsSync(path.join(schemaDir, "FileChangeRequestApprovalResponse.json")),
            modelList: declared(clientRequests, "model/list"),
            schemaSHA256: createHash("sha256").update(protocolSchema).digest("hex"),
        };
        const required = ["initialize", "threadList", "threadStart", "threadResume", "threadRead", "turnStart", "turnInterrupt", "textStreaming"];
        const missing = required.filter((key) => !profile[key]);
        if (missing.length) throw new Error(`Installed Codex protocol is missing required methods: ${missing.join(", ")}`);

        const token = randomBytes(32).toString("base64url");
        const tokenSHA256 = createHash("sha256").update(token).digest("hex");
        return {
            version,
            profile,
            token,
            tokenSHA256,
            cleanup() {
                rmSync(schemaDir, { recursive: true, force: true });
            },
        };
    } catch (error) {
        rmSync(schemaDir, { recursive: true, force: true });
        throw error;
    }
}

export function isPrivateRoutableIPv4(ip) { const parts = ip.split(".").map(Number); if (parts.length !== 4 || parts.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return false; if (parts[0] === 192 && parts[1] === 168) return true; if (parts[0] === 10) return true; if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true; return false; }

export function bestLanIPv4(addresses) { const nonLocal = addresses.filter((ip) => !ip.startsWith("169.254.")); return nonLocal.find(isPrivateRoutableIPv4) ?? nonLocal[0] ?? "127.0.0.1"; }

function lanIPv4() { const addresses = []; for (const entries of Object.values(os.networkInterfaces())) { for (const entry of entries ?? []) { if (entry.family === "IPv4" && !entry.internal) addresses.push(entry.address); } } return bestLanIPv4(addresses); }

export function resolvePairingHost(explicitHost, exec = execSync) {
    let tailscaleIP;
    try {
        tailscaleIP = String(exec("tailscale ip -4", { encoding: "utf8" })).split(/\s+/).find((value) => /^\d+\.\d+\.\d+\.\d+$/.test(value));
    } catch { /* Tailscale is optional for non-Codex runtimes. */ }
    if (explicitHost === "tailscale") {
        if (!tailscaleIP) throw new Error("could not resolve Tailscale IPv4");
        return { host: tailscaleIP, tailscale: true };
    }
    if (explicitHost) return { host: explicitHost, tailscale: explicitHost === tailscaleIP };
    return { host: lanIPv4(), tailscale: false };
}

export function parseLinkOptions(args, env = process.env) {
    const command = args[0] ?? "link";
    if (command !== "link") {
        throw new Error("usage: iyscodemovil link [--runtime opencode|openisy|crush|codex|claude-code|gemini|grok] [--port 4096] [--directory PATH] [--host LAN|tailscale|IP] [--openisy-root PATH]");
    }

    const values = new Map();
    const valid = new Set(["--runtime", "--port", "--directory", "--host", "--openisy-root"]);
    for (let i = 1; i < args.length; i += 2) {
        const name = args[i];
        const value = args[i + 1];
        if (!valid.has(name)) throw new Error(`unknown option: ${name}`);
        if (!value || value.startsWith("--")) throw new Error(`missing value for ${name}`);
        values.set(name, value);
    }

    const runtime = values.get("--runtime") ?? "opencode";
    if (!RUNTIMES[runtime]) throw new Error(`unsupported runtime: ${runtime}. Available: ${Object.keys(RUNTIMES).join(", ")}`);
    const rt = RUNTIMES[runtime];
    if (rt.notImplemented) throw new Error(rt.notImplemented);

    const openisyRootValue = values.get("--openisy-root") ?? env.OPENISY_ROOT;
    const openisyRoot = openisyRootValue ? path.resolve(openisyRootValue) : undefined;
    if (runtime === "openisy" && !openisyRoot) {
        throw new Error("OpenISy requires --openisy-root PATH or OPENISY_ROOT");
    }
    if (runtime !== "openisy" && !rt.check(openisyRoot)) {
        throw new Error(`${rt.label} not available. Make sure it's installed and in PATH.`);
    }

    const port = Number(values.get("--port") ?? "4096");
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`invalid port: ${port}`);
    return {
        runtime,
        rt,
        port,
        directory: path.resolve(values.get("--directory") ?? process.cwd()),
        host: values.get("--host"),
        openisyRoot,
    };
}

export function runtimeCommand(options, platform = process.platform, env = process.env, host, codexInfo) {
    const rt = RUNTIMES[options.runtime];
    if (!rt.check(options.openisyRoot)) {
        if (options.runtime === "openisy") throw new Error(`OpenISy entrypoint not found under ${options.openisyRoot}`);
        throw new Error(`${rt.label} not available. Make sure it's installed and in PATH.`);
    }
    if (options.runtime === "grok") {
        throw new Error("Grok is started by the Tailscale proxy, not as a direct serve command.");
    }
    if (options.runtime === "codex" && (!host || !codexInfo?.tokenSHA256)) {
        throw new Error("Codex runtime requires a resolved Tailscale host and discovered protocol/auth settings.");
    }
    return {
        executable: rt.executable,
        args: rt.args(options.port, options.directory, options.openisyRoot, host, codexInfo?.tokenSHA256),
        cwd: rt.cwd(options.directory),
        shell: options.runtime === "opencode" && platform === "win32",
        env: rt.env(env, "iyscode", ""),
    };
}

export function childEnvironment(env, username, password, runtimeEnv = {}) { return { ...env, ...runtimeEnv, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }; }

export async function main(args = process.argv.slice(2), env = process.env) {
    let options;
    let runtime;
    let codexInfo;
    let resolvedHost;
    try {
        options = parseLinkOptions(args, env);
        resolvedHost = resolvePairingHost(options.host);
        if (options.runtime === "codex") {
            if (!resolvedHost.tailscale) {
                throw new Error("Codex App Server uses unencrypted ws:// transport. For remote use, select the encrypted Tailscale VPN with --host tailscale.");
            }
            codexInfo = inspectCodex();
        }
        if (options.runtime === "grok") {
            assertGrokTransport(resolvedHost);
            return await startGrokLink({
                host: resolvedHost.host,
                port: options.port,
                directory: options.directory,
            });
        }
        runtime = runtimeCommand(options, process.platform, env, resolvedHost.host, codexInfo);
    } catch (error) {
        codexInfo?.cleanup();
        console.error(error.message);
        return 2;
    }

    const { host, tailscale } = resolvedHost;
    const lanReachable = tailscale || isPrivateRoutableIPv4(host);
    let pairing;
    if (options.runtime === "codex") {
        const query = new URLSearchParams({
            host,
            port: String(options.port),
            directory: options.directory,
            token: codexInfo.token,
            codexVersion: codexInfo.version,
            profile: JSON.stringify(codexInfo.profile),
        });
        // URLSearchParams uses `+` for spaces, but URI custom-scheme query
        // parsing on iOS preserves `+` literally. Encode spaces as `%20` so
        // version labels and paths round-trip through URLComponents.
        pairing = `codex://pair?${query.toString().replaceAll("+", "%20")}`;
        runtime.env = env;
    } else {
        const username = "iyscode";
        const password = randomBytes(24).toString("base64url");
        runtime.env = childEnvironment(env, username, password, RUNTIMES[options.runtime].env(env, username, password));
        const query = new URLSearchParams({ host, port: String(options.port), username, password, directory: options.directory });
        pairing = `iyscodemovil://pair?${query.toString().replaceAll("+", "%20")}`;
    }

    console.log("");
    console.log("iyscode native / desktop link");
    console.log("────────────────────────────────────────");
    console.log(`runtime   ${RUNTIMES[options.runtime].label}`);
    console.log(`project   ${options.directory}`);
    console.log(`server    ${options.runtime === "codex" ? "ws" : "http"}://${host}:${options.port}${tailscale ? "  (via Tailscale)" : ""}`);
    console.log(options.runtime === "codex"
        ? `Codex CLI ${codexInfo.version}; App Server is experimental. Traffic requires the encrypted Tailscale VPN; never expose this port directly to the internet.`
        : "WARNING: HTTP does not encrypt credentials or project traffic. Use only on a trusted LAN or through an encrypted VPN/tunnel; never expose this port directly to the internet.");
    if (!lanReachable) {
        console.log("");
        console.log("WARNING: no private-routable IPv4 (RFC1918) was found.");
        console.log("Connect both devices to the same Wi-Fi/LAN and retry.");
    }
    console.log("");
    console.log("paste this into the iPhone app:");
    console.log("");
    console.log(pairing);
    console.log("");
    console.log("Keep this terminal open. Ctrl+C stops the link.");
    console.log("────────────────────────────────────────");
    console.log("");

    const child = spawn(runtime.executable, runtime.args, {
        cwd: runtime.cwd,
        env: runtime.env,
        stdio: "inherit",
        shell: runtime.shell,
    });
    const cleanup = () => codexInfo?.cleanup();
    child.on("error", (error) => {
        console.error(`failed to start ${RUNTIMES[options.runtime].label}: ${error.message}`);
        cleanup();
        process.exitCode = 1;
    });
    child.on("exit", (code, signal) => {
        cleanup();
        if (signal && process.platform !== "win32") process.kill(process.pid, signal);
        else process.exitCode = code ?? 0;
    });
    for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
    return child;
}

const invokedDirectly = process.argv[1] && pathToFileURL(realpathSync(process.argv[1])).href === import.meta.url;
if (invokedDirectly) {
    Promise.resolve(main()).then((result) => {
        if (typeof result === "number") process.exitCode = result;
    }).catch((error) => {
        console.error(error?.message ?? error);
        process.exitCode = 1;
    });
}

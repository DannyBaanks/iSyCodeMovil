import { spawn } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { mkdtempSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export function isTailscaleIPv4(host) {
    const parts = String(host).split(".");
    if (parts.length !== 4) return false;
    const octets = parts.map((part) => Number(part));
    if (octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
    return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

export function assertGrokTransport(resolved) {
    if (!resolved?.tailscale || !isTailscaleIPv4(resolved.host)) {
        throw new Error("Grok agent serve refuses plaintext WebSocket off loopback. Use --host tailscale. The bridge proxies that VPN address to 127.0.0.1.");
    }
}

export function assertGrokServeHelp(help) {
    const text = String(help);
    if (!text.includes("--bind") || !text.includes("--secret")) {
        throw new Error("Installed Grok CLI does not demonstrate `grok agent serve --bind` and `--secret`.");
    }
}

export function buildGrokPairingURL({ host, port, directory, token, grokVersion, profile }) {
    const query = new URLSearchParams({
        host,
        port: String(port),
        directory,
        token,
        grokVersion,
        profile: JSON.stringify(profile),
    });
    return `grok://pair?${query.toString().replaceAll("+", "%20")}`;
}

export function redactGrokOutput(text, secret) {
    let out = String(text);
    if (secret) out = out.split(secret).join("[redacted]");
    return out.replace(/server-key=[^&\s]+/g, "server-key=[redacted]");
}

function freePort() {
    return new Promise((resolve, reject) => {
        const server = net.createServer();
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
            const address = server.address();
            server.close(() => resolve(address.port));
        });
    });
}

function waitForPort(port, timeoutMs) {
    const started = Date.now();
    return new Promise((resolve, reject) => {
        const attempt = () => {
            const socket = net.connect({ host: "127.0.0.1", port });
            const fail = () => {
                socket.destroy();
                if (Date.now() - started > timeoutMs) reject(new Error("Grok agent serve did not listen on loopback."));
                else setTimeout(attempt, 150);
            };
            socket.once("error", fail);
            socket.once("connect", () => {
                socket.end();
                resolve();
            });
        };
        attempt();
    });
}

function takeFrame(buffer) {
    if (buffer.length < 2) return null;
    const first = buffer[0];
    const second = buffer[1];
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let offset = 2;
    if (length === 126) {
        if (buffer.length < 4) return null;
        length = buffer.readUInt16BE(2);
        offset = 4;
    } else if (length === 127) {
        if (buffer.length < 10) return null;
        const wide = buffer.readBigUInt64BE(2);
        if (wide > BigInt(8 * 1024 * 1024)) throw new Error("WebSocket frame is too large.");
        length = Number(wide);
        offset = 10;
    }
    const maskLength = masked ? 4 : 0;
    if (buffer.length < offset + maskLength + length) return null;
    const payload = Buffer.from(buffer.subarray(offset + maskLength, offset + maskLength + length));
    if (masked) {
        const mask = buffer.subarray(offset, offset + 4);
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    return { fin, opcode, data: payload, consumed: offset + maskLength + length };
}

function encodeFrame(opcode, data) {
    const payload = Buffer.isBuffer(data) ? data : Buffer.from(data);
    let header;
    if (payload.length < 126) header = Buffer.from([0x80 | opcode, payload.length]);
    else if (payload.length < 65536) {
        header = Buffer.alloc(4);
        header[0] = 0x80 | opcode;
        header[1] = 126;
        header.writeUInt16BE(payload.length, 2);
    } else {
        header = Buffer.alloc(10);
        header[0] = 0x80 | opcode;
        header[1] = 127;
        header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    return Buffer.concat([header, payload]);
}

function bearerToken(header) {
    const match = /^Bearer ([A-Za-z0-9_-]{32,})$/.exec(header ?? "");
    return match?.[1] ?? "";
}

function sameToken(left, right) {
    const a = Buffer.from(left);
    const b = Buffer.from(right);
    return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}

function pumpFrames(socket, onFrame) {
    let pending = Buffer.alloc(0);
    let fragments = [];
    let fragmentOpcode = 0;
    socket.on("data", (chunk) => {
        pending = Buffer.concat([pending, chunk]);
        try {
            while (true) {
                const frame = takeFrame(pending);
                if (!frame) break;
                pending = pending.subarray(frame.consumed);
                if (frame.opcode === 0x9) {
                    onFrame({ type: "ping", data: frame.data });
                    continue;
                }
                if (frame.opcode === 0xA) continue;
                if (frame.opcode === 0x8) {
                    onFrame({ type: "close" });
                    continue;
                }
                if (frame.opcode === 0x1 || frame.opcode === 0x2) {
                    if (!frame.fin) {
                        fragmentOpcode = frame.opcode;
                        fragments = [frame.data];
                        continue;
                    }
                    onFrame({ type: frame.opcode === 1 ? "text" : "binary", data: frame.data });
                    continue;
                }
                if (frame.opcode === 0x0) {
                    fragments.push(frame.data);
                    if (frame.fin) {
                        const data = Buffer.concat(fragments);
                        fragments = [];
                        onFrame({ type: fragmentOpcode === 1 ? "text" : "binary", data });
                    }
                }
            }
        } catch (error) {
            onFrame({ type: "error", error });
        }
    });
}

export function startGrokProxy({ host, port, token, upstreamURL, allowLoopback = false }) {
    const loopbackOk = allowLoopback && host === "127.0.0.1";
    if (!loopbackOk && !isTailscaleIPv4(host)) {
        return Promise.reject(new Error("Grok proxy only binds a Tailscale IPv4 address."));
    }
    if (!upstreamURL.startsWith("ws://127.0.0.1:")) {
        return Promise.reject(new Error("Grok upstream must be a loopback ws://127.0.0.1 URL."));
    }
    const WebSocketImpl = globalThis.WebSocket;
    if (!WebSocketImpl) return Promise.reject(new Error("This Node does not provide a WebSocket client."));

    const server = http.createServer((_req, res) => {
        res.writeHead(404);
        res.end();
    });
    const sockets = new Set();
    const upstreams = new Set();
    server.on("connection", (socket) => {
        sockets.add(socket);
        socket.on("close", () => sockets.delete(socket));
    });
    server.on("upgrade", (request, socket, head) => {
        if (!sameToken(bearerToken(request.headers.authorization), token)) {
            socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
            return;
        }
        const key = request.headers["sec-websocket-key"];
        if (!key) {
            socket.destroy();
            return;
        }
        const accept = createHash("sha1").update(String(key) + WS_GUID).digest("base64");
        socket.write(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
        );
        if (head?.length) socket.unshift(head);

        const upstream = new WebSocketImpl(upstreamURL);
        upstreams.add(upstream);
        upstream.addEventListener("close", () => upstreams.delete(upstream));
        const queue = [];
        let upstreamOpen = false;
        let closed = false;
        const closeBoth = () => {
            if (closed) return;
            closed = true;
            try { socket.destroy(); } catch { /* already closed */ }
            try { upstream.close(); } catch { /* already closed */ }
        };
        const sendUpstream = (data) => {
            if (!upstreamOpen) queue.push(data);
            else upstream.send(data);
        };
        upstream.addEventListener("open", () => {
            upstreamOpen = true;
            for (const item of queue) upstream.send(item);
            queue.length = 0;
        });
        upstream.addEventListener("message", (event) => {
            const data = typeof event.data === "string" ? event.data : Buffer.from(event.data);
            const opcode = typeof data === "string" ? 0x1 : 0x2;
            if (!socket.destroyed) socket.write(encodeFrame(opcode, data));
        });
        upstream.addEventListener("close", closeBoth);
        upstream.addEventListener("error", closeBoth);
        pumpFrames(socket, (frame) => {
            if (frame.type === "ping") {
                if (!socket.destroyed) socket.write(encodeFrame(0xA, frame.data));
                return;
            }
            if (frame.type === "text") sendUpstream(frame.data.toString("utf8"));
            else if (frame.type === "binary") sendUpstream(frame.data);
            else if (frame.type === "close" || frame.type === "error") closeBoth();
        });
        socket.on("close", closeBoth);
        socket.on("error", closeBoth);
    });

    return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
            const bound = server.address().port;
            resolve({
                host,
                port: bound,
                close() {
                    for (const item of upstreams) {
                        try { item.close(); } catch { /* already closed */ }
                    }
                    for (const socket of sockets) socket.destroy();
                    server.close();
                    server.unref();
                    return Promise.resolve();
                },
            });
        });
    });
}

function rpcCall(ws, method, params, id, timeoutMs) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            ws.removeEventListener("message", onMessage);
            reject(new Error(`Grok ${method} timed out.`));
        }, timeoutMs);
        const onMessage = (event) => {
            let message;
            try { message = JSON.parse(String(event.data)); } catch { return; }
            if (message.id !== id) return;
            clearTimeout(timer);
            ws.removeEventListener("message", onMessage);
            if (message.error) reject(new Error(message.error.message || `Grok ${method} failed.`));
            else resolve(message.result);
        };
        ws.addEventListener("message", onMessage);
        ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
}

export async function inspectGrok(executable = "grok", tempRoot = os.tmpdir()) {
    const { execFileSync } = await import("node:child_process");
    const version = execFileSync(executable, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    const help = execFileSync(executable, ["agent", "serve", "--help"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    assertGrokServeHelp(help);

    const WebSocketImpl = globalThis.WebSocket;
    if (!WebSocketImpl) throw new Error("This Node does not provide a WebSocket client.");
    const secret = randomBytes(18).toString("base64url");
    const port = await freePort();
    const directory = mkdtempSync(path.join(tempRoot, "iyscodemovil-grok-"));
    const child = spawn(executable, ["agent", "serve", "--bind", `127.0.0.1:${port}`, "--secret", secret], {
        cwd: directory,
        stdio: "ignore",
    });
    try {
        await waitForPort(port, 15000);
        const ws = new WebSocketImpl(`ws://127.0.0.1:${port}/ws?server-key=${encodeURIComponent(secret)}`);
        await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error("Grok WebSocket handshake timed out.")), 8000);
            ws.addEventListener("open", () => { clearTimeout(timer); resolve(); });
            ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("Grok WebSocket handshake failed.")); });
        });
        const initialized = await rpcCall(ws, "initialize", {
            protocolVersion: 1,
            clientCapabilities: {},
            clientInfo: { name: "ISyCodeMovil", version: "0.1.0" },
        }, 1, 8000);
        if (initialized?.protocolVersion !== 1) {
            throw new Error("Installed Grok agent server did not accept ACP protocolVersion 1.");
        }
        const created = await rpcCall(ws, "session/new", { cwd: directory, mcpServers: [] }, 2, 30000);
        if (typeof created?.sessionId !== "string" || !created.sessionId) {
            throw new Error("Installed Grok agent server did not return a sessionId from session/new.");
        }
        let sessionList = false;
        try {
            const listed = await rpcCall(ws, "session/list", {}, 3, 8000);
            sessionList = Array.isArray(listed?.sessions);
        } catch {
            sessionList = false;
        }
        ws.close();
        return {
            version,
            token: randomBytes(32).toString("base64url"),
            profile: {
                profileVersion: 1,
                protocolVersion: 1,
                sessionNew: true,
                sessionList,
                sessionPrompt: true,
                sessionCancel: true,
                textStreaming: true,
                permission: true,
                sessionLoad: false,
            },
        };
    } finally {
        child.kill("SIGTERM");
    }
}

export async function startGrokLink({ host, port, directory, executable = "grok" }) {
    assertGrokTransport({ host, tailscale: true });
    const info = await inspectGrok(executable);
    const serverSecret = randomBytes(32).toString("base64url");
    const internalPort = await freePort();
    const child = spawn(executable, ["agent", "serve", "--bind", `127.0.0.1:${internalPort}`, "--secret", serverSecret], {
        cwd: directory,
        stdio: ["ignore", "pipe", "pipe"],
    });
    const writeRedacted = (chunk) => {
        const text = redactGrokOutput(chunk.toString("utf8"), serverSecret);
        if (text.trim()) process.stderr.write(text);
    };
    child.stdout.on("data", writeRedacted);
    child.stderr.on("data", writeRedacted);
    let proxy;
    try {
        await waitForPort(internalPort, 15000);
        proxy = await startGrokProxy({
            host,
            port,
            token: info.token,
            upstreamURL: `ws://127.0.0.1:${internalPort}/ws?server-key=${encodeURIComponent(serverSecret)}`,
        });
    } catch (error) {
        child.kill("SIGTERM");
        throw error;
    }
    const pairing = buildGrokPairingURL({
        host,
        port: proxy.port,
        directory,
        token: info.token,
        grokVersion: info.version,
        profile: info.profile,
    });
    console.log("");
    console.log("iyscode native / desktop link");
    console.log("────────────────────────────────────────");
    console.log("runtime   Grok");
    console.log(`project   ${directory}`);
    console.log(`server    ws://${host}:${proxy.port}  (via Tailscale)`);
    console.log(`Grok CLI ${info.version}; agent serve stays on 127.0.0.1. This bridge proxies Tailscale to that loopback socket.`);
    console.log("The link carries a capability token. The Grok server secret stays on this computer.");
    console.log("ws:// has no TLS. Use only the encrypted Tailscale VPN. Never expose this port to LAN or the internet.");
    console.log("");
    console.log("paste this into the iPhone app:");
    console.log("");
    console.log(pairing);
    console.log("");
    console.log("Keep this terminal open. Ctrl+C stops the link.");
    console.log("────────────────────────────────────────");
    console.log("");

    let stopped = false;
    const stop = () => {
        if (stopped) return;
        stopped = true;
        proxy.close();
        child.kill("SIGTERM");
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    child.once("exit", (code, signal) => {
        proxy.close();
        if (!stopped) process.exitCode = signal ? 1 : (code ?? 0);
    });
    return { pairing, profile: info.profile, version: info.version };
}

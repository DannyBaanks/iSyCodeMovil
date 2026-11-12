import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { assertGrokServeHelp, assertGrokTransport, buildGrokPairingURL, startGrokProxy } from "../bin/grok_bridge.mjs";
import { bestLanIPv4, childEnvironment, isPrivateRoutableIPv4, parseLinkOptions, resolvePairingHost, runtimeCommand } from "../bin/iyscodemovil.mjs";

test("default runtime remains official opencode", () => {
  const options = parseLinkOptions(["link"], {});
  const command = runtimeCommand(options, "win32");
  assert.equal(options.runtime, "opencode");
  assert.equal(command.executable, "opencode");
  assert.deepEqual(command.args, ["serve", "--hostname", "0.0.0.0", "--port", "4096", "--mdns"]);
  assert.equal(command.shell, true);
});

test("OpenISy runtime uses Bun and preserves paths with spaces", async () => {
  const root = path.join(os.tmpdir(), `OpenISy Root ${process.pid}`);
  const entry = path.join(root, "packages", "opencode", "src", "index.ts");
  await mkdir(path.dirname(entry), { recursive: true });
  await writeFile(entry, "");
  try {
    const options = parseLinkOptions([
      "link",
      "--runtime", "openisy",
      "--openisy-root", root,
      "--directory", path.join(root, "Project With Spaces"),
      "--port", "5096",
    ], {});
    const command = runtimeCommand(options, "win32");
    assert.equal(command.executable, "bun");
    assert.equal(command.shell, false);
    assert.equal(command.cwd, path.resolve(root, "Project With Spaces"));
    assert.deepEqual(command.args, [
      "--cwd", path.join(root, "packages", "opencode"), "src/index.ts",
      "serve", "--hostname", "0.0.0.0", "--port", "5096", "--mdns",
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("OPENISY_ROOT supplies the private OpenISy repository", () => {
  const options = parseLinkOptions(["link", "--runtime", "openisy"], { OPENISY_ROOT: "relative-openisy" });
  assert.equal(options.openisyRoot, path.resolve("relative-openisy"));
});

test("child environment includes ephemeral server credentials", () => {
  const env = childEnvironment({ EXISTING: "kept" }, "opencode", "secret");
  assert.equal(env.EXISTING, "kept");
  assert.equal(env.OPENCODE_SERVER_USERNAME, "opencode");
  assert.equal(env.OPENCODE_SERVER_PASSWORD, "secret");
});

test("invalid command, runtime, port, and incomplete OpenISy config fail explicitly", () => {
  assert.throws(() => parseLinkOptions(["connect"], {}), /usage:/);
  assert.throws(() => parseLinkOptions(["link", "--runtime", "other"], {}), /unsupported runtime/);
  assert.throws(() => parseLinkOptions(["link", "--port", "0"], {}), /invalid port/);
  assert.throws(() => parseLinkOptions(["link", "--runtime", "openisy"], {}), /OpenISy requires/);
  assert.throws(() => parseLinkOptions(["link", "--unknown", "value"], {}), /unknown option/);
});

test("missing OpenISy entrypoint fails before spawning", () => {
  const options = parseLinkOptions(["link", "--runtime", "openisy", "--openisy-root", os.tmpdir()], {});
  assert.throws(() => runtimeCommand(options), /OpenISy entrypoint not found/);
});

test("bestLanIPv4 prefers a private routable address over link-local adapters", () => {
  // Esta maquina: Bluetooth/Wi-Fi extra/Ethernet en 169.254.* antes que el
  // Wi-Fi real 192.168.* — el pairing apuntaria a una IP inalcanzable.
  assert.equal(bestLanIPv4(["169.254.85.244", "192.168.1.102"]), "192.168.1.102");
  assert.equal(bestLanIPv4(["169.254.1.2", "10.0.0.5"]), "10.0.0.5");
  assert.equal(bestLanIPv4(["172.20.1.9", "192.168.0.7"]), "172.20.1.9");
  // Solo link-local: ninguna es alcanzable desde el iPhone; localhost es el
  // fallback honesto y el CLI imprime el WARNING correspondiente.
  assert.equal(bestLanIPv4(["169.254.1.2"]), "127.0.0.1");
  assert.equal(bestLanIPv4([]), "127.0.0.1");
});

test("isPrivateRoutableIPv4 covers RFC1918 and rejects junk", () => {
  assert.equal(isPrivateRoutableIPv4("192.168.1.102"), true);
  assert.equal(isPrivateRoutableIPv4("10.1.2.3"), true);
  assert.equal(isPrivateRoutableIPv4("172.31.255.1"), true);
  assert.equal(isPrivateRoutableIPv4("172.15.0.1"), false);
  assert.equal(isPrivateRoutableIPv4("169.254.1.2"), false);
  assert.equal(isPrivateRoutableIPv4("8.8.8.8"), false);
  assert.equal(isPrivateRoutableIPv4("nope"), false);
});

test("--host defaults to LAN resolution", () => {
  const options = parseLinkOptions(["link"], {});
  assert.equal(options.host, undefined);
  const resolved = resolvePairingHost(options.host);
  assert.equal(resolved.tailscale, false);
  assert.match(resolved.host, /^\d+\.\d+\.\d+\.\d+$/);
});

test("--host tailscale resolves via `tailscale ip -4`", () => {
  const options = parseLinkOptions(["link", "--host", "tailscale"], {});
  assert.equal(options.host, "tailscale");
  const stub = () => "100.115.163.4\n";
  assert.deepEqual(resolvePairingHost(options.host, stub), { host: "100.115.163.4", tailscale: true });
});

test("--host tailscale fails explicitly when tailscale is down", () => {
  assert.throws(() => resolvePairingHost("tailscale", () => { throw new Error("exit 1"); }), /could not resolve Tailscale IPv4/);
  assert.throws(() => resolvePairingHost("tailscale", () => "nope\n"), /could not resolve Tailscale IPv4/);
});

test("--host literal passes through (IP o MagicDNS)", () => {
  const stub = () => "100.64.0.2\n";
  const ip = parseLinkOptions(["link", "--host", "100.115.163.4"], {});
  assert.deepEqual(resolvePairingHost(ip.host, stub), { host: "100.115.163.4", tailscale: false });
  const dns = parseLinkOptions(["link", "--host", "dannyisyco.tail379054.ts.net"], {});
  assert.deepEqual(resolvePairingHost(dns.host, stub), { host: "dannyisyco.tail379054.ts.net", tailscale: false });
});

test("Tailscale CGNAT no es RFC1918: el WARNING LAN no aplica en ese modo", () => {
  // 100.64/10 es la razon por la que el link Tailscale necesita modo propio
  // (y la excepcion ATS en Info.plist): no es "local" para iOS ni RFC1918.
  assert.equal(isPrivateRoutableIPv4("100.115.163.4"), false);
});

test("grok is a bridge runtime and is not spawned as a direct serve command", () => {
  const options = parseLinkOptions(["link", "--runtime", "grok", "--host", "tailscale"], {});
  assert.equal(options.runtime, "grok");
  assert.throws(() => runtimeCommand(options), /Tailscale proxy/);
  assert.throws(() => parseLinkOptions(["link", "--runtime", "crush"], {}), /not yet available/);
});

test("grok serve help and non-tailscale hosts fail closed", () => {
  assert.throws(() => assertGrokServeHelp("usage: grok agent serve"), /--bind/);
  assert.doesNotThrow(() => assertGrokServeHelp("usage: --bind 127.0.0.1:2419 --secret"));
  assert.throws(() => assertGrokTransport({ host: "192.168.1.20", tailscale: false }), /tailscale/);
  assert.throws(() => assertGrokTransport({ host: "10.0.0.8", tailscale: true }), /tailscale/);
  assert.doesNotThrow(() => assertGrokTransport({ host: "100.115.163.4", tailscale: true }));
});

test("grok pairing URL hides the server key and encodes spaces as %20", () => {
  const url = buildGrokPairingURL({
    host: "100.115.163.4",
    port: 2419,
    directory: "/tmp/my project",
    token: "a".repeat(32),
    grokVersion: "grok 1.0.50 (c58f321264ba)",
    profile: {
      profileVersion: 1,
      protocolVersion: 1,
      sessionNew: true,
      sessionList: true,
      sessionPrompt: true,
      sessionCancel: true,
      textStreaming: true,
      permission: true,
      sessionLoad: false,
    },
  });
  assert.equal(url.startsWith("grok://pair?"), true);
  assert.equal(url.includes("server-key"), false);
  assert.equal(url.includes(" "), false);
  assert.equal(url.includes("+"), false);
  assert.match(url, /directory=%2Ftmp%2Fmy%20project/);
});

test("grok proxy on loopback rejects a missing bearer and forwards one text frame", { timeout: 8000 }, async () => {
  const token = "a".repeat(32);
  const upstream = await fakeGrokUpstream();
  const proxy = await startGrokProxy({
    host: "127.0.0.1",
    port: 0,
    token,
    upstreamURL: `ws://127.0.0.1:${upstream.port}/ws`,
    allowLoopback: true,
  });
  try {
    await assert.rejects(
      () => startGrokProxy({ host: "192.168.1.8", port: 0, token, upstreamURL: "ws://127.0.0.1:9/ws" }),
      /Tailscale/,
    );
    const rejected = await rawUpgrade(proxy.port, null);
    assert.match(rejected.head, /^HTTP\/1\.1 401/);
    rejected.socket.destroy();

    const accepted = await rawUpgrade(proxy.port, token);
    assert.match(accepted.head, /^HTTP\/1\.1 101/);
    const frame = await readTextFrame(accepted.socket, accepted.rest);
    assert.equal(frame, "desde-grok");
    accepted.socket.write(maskedTextFrame("desde-el-telefono"));
    const seen = await waitFor(() => upstream.received.includes("desde-el-telefono"));
    assert.equal(seen, true);
    accepted.socket.destroy();
  } finally {
    await proxy.close();
    await upstream.close();
  }
});

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function fakeGrokUpstream() {
  const received = [];
  const sockets = new Set();
  const server = http.createServer();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  server.on("upgrade", (request, socket) => {
    const key = request.headers["sec-websocket-key"];
    const accept = createHash("sha1").update(String(key) + WS_GUID).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.write(unmaskedTextFrame("desde-grok"));
    let pending = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 2) {
        const parsed = takeFrame(pending);
        if (!parsed) return;
        pending = pending.subarray(parsed.consumed);
        if (parsed.opcode === 0x1) received.push(parsed.data.toString("utf8"));
        if (parsed.opcode === 0x9) socket.write(unmaskedFrame(0xA, parsed.data));
      }
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({
        port: server.address().port,
        received,
        close() {
          for (const socket of sockets) socket.destroy();
          server.close();
          server.unref();
          return Promise.resolve();
        },
      });
    });
  });
}

function rawUpgrade(port, token) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    const key = randomBytes(16).toString("base64");
    const lines = [
      "GET / HTTP/1.1",
      `Host: 127.0.0.1:${port}`,
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Key: ${key}`,
      "Sec-WebSocket-Version: 13",
    ];
    if (token) lines.push(`Authorization: Bearer ${token}`);
    socket.write(`${lines.join("\r\n")}\r\n\r\n`);
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("upgrade timed out"));
    }, 3000);
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const split = buf.indexOf("\r\n\r\n");
      if (split < 0) return;
      clearTimeout(timer);
      socket.off("data", onData);
      resolve({ socket, head: buf.subarray(0, split).toString("utf8"), rest: buf.subarray(split + 4) });
    };
    socket.on("data", onData);
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function readTextFrame(socket, initial) {
  return new Promise((resolve, reject) => {
    let buf = initial;
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("frame timed out"));
    }, 3000);
    const tryParse = () => {
      const parsed = takeFrame(buf);
      if (!parsed || parsed.opcode !== 0x1) return false;
      clearTimeout(timer);
      socket.off("data", onData);
      resolve(parsed.data.toString("utf8"));
      return true;
    };
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      tryParse();
    };
    if (!tryParse()) socket.on("data", onData);
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function waitFor(predicate) {
  const started = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      if (predicate()) resolve(true);
      else if (Date.now() - started > 3000) resolve(false);
      else setTimeout(tick, 25);
    };
    tick();
  });
}

function unmaskedTextFrame(text) {
  return unmaskedFrame(0x1, Buffer.from(text));
}

function unmaskedFrame(opcode, data) {
  const payload = Buffer.isBuffer(data) ? data : Buffer.from(data);
  return Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]);
}

function maskedTextFrame(text) {
  const payload = Buffer.from(text);
  const mask = randomBytes(4);
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4];
  return Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask, masked]);
}

function takeFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  }
  const maskLength = masked ? 4 : 0;
  if (buffer.length < offset + maskLength + length) return null;
  const data = Buffer.from(buffer.subarray(offset + maskLength, offset + maskLength + length));
  if (masked) {
    const mask = buffer.subarray(offset, offset + 4);
    for (let i = 0; i < data.length; i += 1) data[i] ^= mask[i % 4];
  }
  return { opcode, data, consumed: offset + maskLength + length };
}

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import {
  ADMIN_TOOLS, INTERACT_TOOLS, READONLY_TOOLS,
  createIphoneGate, isCallAllowed, isToolAllowed,
} from "../bin/iphone_gate.mjs";
import { createSandboxGateway } from "../bin/sandbox_bridge.mjs";

const TOKEN = "t".repeat(43);
const ALL = [...READONLY_TOOLS, ...INTERACT_TOOLS, ...ADMIN_TOOLS];

function fakeMcp(log = []) {
  return {
    async request(method, params) {
      log.push([method, params]);
      if (method === "tools/list") return { tools: ALL.map((name) => ({ name })) };
      if (method === "tools/call") return { content: [{ type: "text", text: `ran ${params.name}` }] };
      return {};
    },
    notify() {},
    close() {},
  };
}

test("readonly allows only observing tools", () => {
  for (const name of READONLY_TOOLS) assert.equal(isToolAllowed("readonly", name), true, name);
  for (const name of [...INTERACT_TOOLS, ...ADMIN_TOOLS]) assert.equal(isToolAllowed("readonly", name), false, name);
});

test("control allows interaction but never admin tools", () => {
  for (const name of [...READONLY_TOOLS, ...INTERACT_TOOLS]) assert.equal(isToolAllowed("control", name), true, name);
  for (const name of ADMIN_TOOLS) assert.equal(isToolAllowed("control", name), false, name);
});

test("unknown tools, unknown modes and non-strings are refused", () => {
  assert.equal(isToolAllowed("control", "iphone_nonexistent"), false);
  assert.equal(isToolAllowed("root", "iphone_status"), false);
  assert.equal(isToolAllowed("control", undefined), false);
  assert.equal(isToolAllowed("control", { toString: () => "iphone_status" }), false);
});

test("iphone_batch is checked step by step", () => {
  const batch = (steps) => ({ steps });
  assert.equal(isCallAllowed("control", "iphone_batch", batch([{ tool: "iphone_tap", x: 1, y: 2 }])), true);
  assert.equal(isCallAllowed("control", "iphone_batch", batch([{ tool: "iphone_select_device" }])), false);
  assert.equal(isCallAllowed("control", "iphone_batch", batch([{ tool: "iphone_tap" }, { tool: "iphone_select_device" }])), false);
  assert.equal(isCallAllowed("control", "iphone_batch", batch([{ tool: "iphone_batch", steps: [] }])), false);
  assert.equal(isCallAllowed("control", "iphone_batch", batch([])), false);
  assert.equal(isCallAllowed("control", "iphone_batch", {}), false);
  assert.equal(isCallAllowed("control", "iphone_batch", batch(["iphone_tap"])), false);
  assert.equal(isCallAllowed("readonly", "iphone_batch", batch([{ tool: "iphone_status" }])), false);
});

test("gate lists only what its mode allows and refuses before touching the device", async () => {
  const log = [];
  const gate = createIphoneGate({ mode: "readonly", connect: () => fakeMcp(log) });
  assert.deepEqual((await gate.tools()).map((t) => t.name).sort(), [...READONLY_TOOLS].sort());
  await assert.rejects(gate.call("iphone_tap", { x: 1, y: 1 }), (e) => e.kind === "refused");
  assert.equal(log.some(([m, p]) => m === "tools/call" && p.name === "iphone_tap"), false);
  assert.equal((await gate.call("iphone_status", {})).content[0].text, "ran iphone_status");
  assert.throws(() => createIphoneGate({ mode: "root", connect: fakeMcp }));
});

async function withGateway(iphone, run) {
  const api = new EventEmitter();
  api.on("request", (req, res) => { res.writeHead(200); res.end("{}"); });
  const server = createSandboxGateway({
    token: TOKEN, api, orchestrator: {}, credentials: { usable: () => ({ ok: false }) },
    directory: "/tmp", project: async () => ({}), iphone,
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const fetchAs = (path, init = {}, token = TOKEN) =>
    fetch(base + path, { ...init, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" } });
  try { await run(fetchAs); } finally { await new Promise((r) => server.close(r)); }
}

test("the iphone routes do not exist unless the link was started with --iphone", async () => {
  await withGateway(null, async (f) => {
    assert.equal((await f("/api/iphone")).status, 404);
    assert.equal((await f("/api/iphone/call", { method: "POST", body: "{}" })).status, 404);
  });
});

test("the iphone routes need the bearer token", async () => {
  const gate = createIphoneGate({ mode: "control", connect: () => fakeMcp() });
  await withGateway(gate, async (f) => {
    assert.equal((await f("/api/iphone", {}, null)).status, 401);
    assert.equal((await f("/api/iphone", {}, "x".repeat(43))).status, 401);
  });
});

test("gateway: lists, calls, refuses admin and oversized or malformed bodies", async () => {
  const gate = createIphoneGate({ mode: "control", connect: () => fakeMcp() });
  await withGateway(gate, async (f) => {
    const listed = await (await f("/api/iphone")).json();
    assert.equal(listed.mode, "control");
    assert.equal(listed.tools.includes("iphone_select_device"), false);
    assert.equal(listed.tools.includes("iphone_tap"), true);

    const ok = await f("/api/iphone/call", { method: "POST", body: JSON.stringify({ tool: "iphone_status", arguments: {} }) });
    assert.equal(ok.status, 200);

    const admin = await f("/api/iphone/call", { method: "POST", body: JSON.stringify({ tool: "iphone_select_device", arguments: { device: "auto" } }) });
    assert.equal(admin.status, 403);

    const big = await f("/api/iphone/call", { method: "POST", body: JSON.stringify({ tool: "iphone_status", arguments: { pad: "x".repeat(70_000) } }) });
    assert.equal(big.status, 403);

    const bad = await f("/api/iphone/call", { method: "POST", body: "{nope" });
    assert.equal(bad.status, 403);

    const noTool = await f("/api/iphone/call", { method: "POST", body: "{}" });
    assert.equal(noTool.status, 400);
  });
});

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { parseLinkOptions, runtimeCommand } from "../bin/iyscodemovil.mjs";
import {
  assertSandboxTransport,
  buildSandboxPairingURL,
  createSandboxGateway,
  discoverGitHubToken,
  keepingExcludedFiles,
  parseGitHubRemote,
} from "../bin/sandbox_bridge.mjs";
import { OrchestratorError } from "../sandbox/server/orchestrator.mjs";

const TOKEN = "t".repeat(43);

/** A gateway over fakes, listening on an ephemeral loopback port. */
async function withGateway(overrides, run) {
  const calls = [];
  const api = new EventEmitter();
  api.on("request", (req, res) => {
    calls.push(["api", req.method, req.url]);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ from: "api" }));
  });
  const orchestrator = {
    async previewFolder(directory) { calls.push(["preview", directory]); return { files: 3 }; },
    async sendFolder(id, directory) { calls.push(["send", id, directory]); return { into: "/work/app" }; },
    ...overrides?.orchestrator,
  };
  const gateway = createSandboxGateway({
    token: TOKEN,
    api,
    orchestrator,
    credentials: { usable: () => ({ ok: overrides?.github ?? false }) },
    directory: "/home/me/project",
    project: async () => ({ name: "project", repo: "me/project", repoUrl: "https://github.com/me/project", defaultBranch: "main" }),
  });
  await new Promise((resolve) => gateway.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${gateway.address().port}`;
  const request = (path, { method = "GET", token = TOKEN, body } = {}) => fetch(base + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    body,
  });
  try {
    await run({ request, calls });
  } finally {
    await new Promise((resolve) => gateway.close(resolve));
  }
}

test("sandbox runtime is selectable and defaults to its own port", () => {
  const options = parseLinkOptions(["link", "--runtime", "sandbox"], {});
  assert.equal(options.runtime, "sandbox");
  assert.equal(options.port, 8788);
  assert.throws(() => runtimeCommand(options), /runs inside the bridge/);
});

test("sandbox API only listens on loopback or the tailnet", () => {
  assert.doesNotThrow(() => assertSandboxTransport({ host: "127.0.0.1", tailscale: false }));
  assert.doesNotThrow(() => assertSandboxTransport({ host: "100.101.102.103", tailscale: true }));
  assert.throws(() => assertSandboxTransport({ host: "192.168.1.20", tailscale: false }), /--host tailscale/);
  assert.throws(() => assertSandboxTransport({ host: "0.0.0.0", tailscale: false }), /--host tailscale/);
  // A LAN address does not become private because someone claimed it is the tailnet.
  assert.throws(() => assertSandboxTransport({ host: "192.168.1.20", tailscale: true }), /--host tailscale/);
});

test("pairing link round-trips paths with spaces", () => {
  const link = buildSandboxPairingURL({ host: "100.101.102.103", port: 8788, token: TOKEN, directory: "/home/me/ISyCo Git/app" });
  assert.ok(link.startsWith("isysandbox://pair?"));
  assert.ok(!link.includes("+"));
  const parsed = new URL(link);
  assert.equal(parsed.searchParams.get("directory"), "/home/me/ISyCo Git/app");
  assert.equal(parsed.searchParams.get("token"), TOKEN);
  assert.equal(parsed.searchParams.get("port"), "8788");
});

test("github remotes are recognised in https and ssh form", () => {
  assert.equal(parseGitHubRemote("https://github.com/DannyBaanks/iSyCodeMovil.git").fullName, "DannyBaanks/iSyCodeMovil");
  assert.equal(parseGitHubRemote("git@github.com:DannyBaanks/iSyCodeMovil.git").url, "https://github.com/DannyBaanks/iSyCodeMovil");
  assert.equal(parseGitHubRemote("https://github.com/a/b/").fullName, "a/b");
  assert.equal(parseGitHubRemote("https://gitlab.com/a/b.git"), null);
  assert.equal(parseGitHubRemote(""), null);
});

test("every route needs the bearer token", async () => {
  await withGateway({}, async ({ request, calls }) => {
    for (const token of [null, "wrong", TOKEN.slice(0, -1), `${TOKEN}x`]) {
      const response = await request("/api/health", { token });
      assert.equal(response.status, 401);
    }
    assert.equal((await request("/api/sandboxes", { token: null, method: "POST" })).status, 401);
    assert.deepEqual(calls, [], "nothing reaches the orchestrator without the token");
  });
});

test("only /api is served, and it is forwarded to the orchestrator API", async () => {
  await withGateway({}, async ({ request, calls }) => {
    assert.equal((await request("/")).status, 404);
    assert.equal((await request("/index.html")).status, 404);
    const response = await request("/api/sandboxes");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { from: "api" });
    assert.deepEqual(calls, [["api", "GET", "/api/sandboxes"]]);
  });
});

test("bridge info describes the linked project and never a token", async () => {
  await withGateway({ github: true }, async ({ request }) => {
    const info = await (await request("/api/bridge")).json();
    assert.equal(info.service, "isycode-sandbox");
    assert.equal(info.project.repo, "me/project");
    assert.equal(info.github, true);
    assert.ok(!JSON.stringify(info).includes(TOKEN));
  });
});

test("folder routes are pinned to the linked project", async () => {
  await withGateway({}, async ({ request, calls }) => {
    const sent = await request("/api/sandboxes/mc-abcdef/folder", { method: "POST", body: JSON.stringify({ directory: "/etc" }) });
    assert.equal(sent.status, 200);
    const preview = await request("/api/sandboxes/mc-abcdef/folder?directory=/root/.ssh");
    assert.equal(preview.status, 200);
    assert.deepEqual(calls, [["send", "mc-abcdef", "/home/me/project"], ["preview", "/home/me/project"]]);
  });
});

test("a refused folder transfer is a 409 with the reason", async () => {
  const orchestrator = { async sendFolder() { throw new OrchestratorError("no such sandbox: mc-abcdef"); } };
  await withGateway({ orchestrator }, async ({ request }) => {
    const response = await request("/api/sandboxes/mc-abcdef/folder", { method: "POST", body: "{}" });
    assert.equal(response.status, 409);
    assert.deepEqual(await response.json(), { error: "no such sandbox: mc-abcdef", kind: "refused" });
  });
});

test("github token discovery prefers the environment and can be switched off", () => {
  const gh = () => "gho_from_gh_cli_0000000000\n";
  assert.deepEqual(discoverGitHubToken({ GITHUB_TOKEN: " ghp_env " }, gh), { token: "ghp_env", source: "GITHUB_TOKEN" });
  assert.deepEqual(discoverGitHubToken({ GH_TOKEN: "ghp_gh" }, gh), { token: "ghp_gh", source: "GH_TOKEN" });
  assert.deepEqual(discoverGitHubToken({}, gh), { token: "gho_from_gh_cli_0000000000", source: "gh auth token" });
  assert.equal(discoverGitHubToken({}, () => { throw new Error("gh: not found"); }), null);
  assert.equal(discoverGitHubToken({ ISYCODE_SANDBOX_NO_GITHUB: "1", GITHUB_TOKEN: "ghp_env" }, gh), null);
});

test("excluded files are settled after code enters a sandbox", async () => {
  const seen = [];
  const base = {
    async sendFolder(id) { seen.push(["sendFolder", id]); return { into: "/work/app" }; },
    async cloneWithCredential(id) { seen.push(["clone", id]); return { repo: "a/b" }; },
    async exec(id, argv) { seen.push(["exec", id, argv.at(-1)]); return ""; },
    async collectWork() { return Buffer.from("x"); },
  };
  const wrapped = keepingExcludedFiles(base);
  assert.deepEqual(await wrapped.sendFolder("mc-abcdef", "/p"), { into: "/work/app" });
  assert.deepEqual(await wrapped.cloneWithCredential("mc-abcdef", "u", "t"), { repo: "a/b" });
  assert.equal(seen[0][0], "sendFolder");
  assert.match(seen[1][2], /sed -i/, "remote credentials are stripped for a linked folder");
  assert.match(seen[2][2], /assume-unchanged/);
  assert.equal(seen[3][0], "clone");
  assert.match(seen[4][2], /assume-unchanged/);
  assert.equal(seen.length, 5);
  // Methods that are not wrapped are still there for the upstream API.
  assert.equal(typeof wrapped.collectWork, "function");
});

test("a failing settle step does not fail the transfer", async () => {
  const wrapped = keepingExcludedFiles({
    async sendFolder() { return { into: "/work/app" }; },
    async exec() { throw new Error("container is paused"); },
  });
  assert.deepEqual(await wrapped.sendFolder("mc-abcdef", "/p"), { into: "/work/app" });
});

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
    MAX_TASKS, addTask, createTasksServer, makeTask, readManifest, runNotifyCommand, sendNtfy, writeManifest,
} from "../bin/notify_cli.mjs";

const tempFile = () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "iyscode-tasks-"));
    return { dir, file: path.join(dir, "nested", "tasks.json") };
};

test("makeTask bounds fields and requires a title", () => {
    const now = new Date("2026-11-13T07:00:00Z");
    const task = makeTask({ title: "  Build\n listo  ", body: "ok", source: "pc.tui" }, now);
    assert.equal(task.title, "Build listo");
    assert.equal(task.createdAt, "2026-11-13T07:00:00.000Z");
    assert.match(task.id, /^[a-z0-9]+-[0-9a-f]{6}$/);
    assert.equal(makeTask({ title: "x".repeat(500) }).title.length, 200);
    assert.throws(() => makeTask({ title: "   " }), /título/);
});

test("addTask keeps newest first, one per id, at most MAX_TASKS", () => {
    let tasks = [];
    for (let i = 0; i < MAX_TASKS + 5; i += 1) tasks = addTask(tasks, makeTask({ id: `t${i}`, title: `T${i}` }));
    assert.equal(tasks.length, MAX_TASKS);
    assert.equal(tasks[0].id, `t${MAX_TASKS + 4}`);
    tasks = addTask(tasks, makeTask({ id: "t10", title: "again" }));
    assert.equal(tasks.filter((t) => t.id === "t10").length, 1);
    assert.equal(tasks[0].title, "again");
});

test("manifest round-trips and ignores broken files", () => {
    const { dir, file } = tempFile();
    try {
        assert.deepEqual(readManifest(file), []);
        writeManifest(file, [makeTask({ id: "a", title: "A" })]);
        assert.equal(readManifest(file)[0].id, "a");
        assert.ok(JSON.parse(readFileSync(file, "utf8")).tasks);
        writeManifest(file, []);
        assert.deepEqual(readManifest(file), []);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("notify saves the task and sends ntfy with an encoded title", async () => {
    const { dir, file } = tempFile();
    const calls = [];
    const fetchImpl = async (url, init) => { calls.push({ url, init }); return { ok: true, status: 200 }; };
    try {
        const code = await runNotifyCommand(["Build", "listo", "--body", "iOS ok", "--id", "b1", "--file", file, "--ntfy", "mi-tema"],
            {}, { fetchImpl, log: () => {} });
        assert.equal(code, 0);
        assert.equal(readManifest(file)[0].id, "b1");
        assert.equal(calls.length, 1);
        assert.equal(calls[0].url, "https://ntfy.sh/mi-tema");
        assert.equal(calls[0].init.body, "iOS ok");
        assert.match(calls[0].init.headers.Title, /^=\?UTF-8\?B\?/);
        assert.equal(await runNotifyCommand([], {}, { log: () => {} }), 2);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("ntfy topic is validated and failures are reported", async () => {
    const task = makeTask({ title: "x" });
    await assert.rejects(sendNtfy({ topic: "../bad", task }), /tema/);
    await assert.rejects(sendNtfy({ topic: "ok", task, fetchImpl: async () => ({ ok: false, status: 403 }) }), /403/);
});

test("tasks server serves the manifest with ETag and 304", async () => {
    const { dir, file } = tempFile();
    writeManifest(file, [makeTask({ id: "s1", title: "Hola" })]);
    const server = createTasksServer(file);
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
        const first = await fetch(`${base}/tasks.json`);
        assert.equal(first.status, 200);
        const etag = first.headers.get("etag");
        assert.ok(etag);
        assert.equal((await first.json()).tasks[0].id, "s1");
        const again = await fetch(`${base}/tasks.json`, { headers: { "If-None-Match": etag } });
        assert.equal(again.status, 304);
        writeManifest(file, addTask(readManifest(file), makeTask({ id: "s2", title: "Nueva" })));
        const changed = await fetch(`${base}/tasks.json`, { headers: { "If-None-Match": etag } });
        assert.equal(changed.status, 200);
        assert.equal((await fetch(`${base}/other`)).status, 404);
        assert.equal((await fetch(`${base}/tasks.json`, { method: "POST" })).status, 405);
    } finally {
        server.close();
        rmSync(dir, { recursive: true, force: true });
    }
});

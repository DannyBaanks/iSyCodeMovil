/**
 * Gate between the iSyCode agent and the computer's `iphone-control` MCP server.
 *
 * The iPhone app reaches this through the sandbox gateway (Tailscale only, bearer token).
 * The gate decides which iPhone tools may be called at all, fail closed:
 *
 *   readonly  observe only: status, screenshot, list apps, list devices.
 *   control   readonly plus interaction (tap, swipe, type, launch/terminate app, open URL,
 *             wait, list elements, batch). `iphone_batch` steps are checked one by one.
 *
 * Admin tools (`iphone_select_device`) are never callable from here, in any mode: which
 * device is controlled is decided on the computer, not by the agent.
 *
 * The mode is chosen when the link is started, never by the caller. Off by default.
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

export const READONLY_TOOLS = Object.freeze([
    "iphone_status", "iphone_list_devices", "iphone_list_apps", "iphone_screenshot",
]);
export const INTERACT_TOOLS = Object.freeze([
    "iphone_list_elements", "iphone_tap", "iphone_tap_element", "iphone_long_press", "iphone_swipe",
    "iphone_type_text", "iphone_press_button", "iphone_launch_app", "iphone_terminate_app",
    "iphone_open_url", "iphone_wait_for", "iphone_batch",
]);
export const ADMIN_TOOLS = Object.freeze(["iphone_select_device"]);
export const MODES = Object.freeze(["readonly", "control"]);

export function isToolAllowed(mode, name) {
    if (typeof name !== "string" || ADMIN_TOOLS.includes(name)) return false;
    if (READONLY_TOOLS.includes(name)) return mode === "readonly" || mode === "control";
    if (INTERACT_TOOLS.includes(name)) return mode === "control";
    return false;
}

/** Whether one `tools/call` may go through. A batch is allowed only if every step is. */
export function isCallAllowed(mode, name, args) {
    if (!isToolAllowed(mode, name)) return false;
    if (name !== "iphone_batch") return true;
    const steps = args?.steps;
    if (!Array.isArray(steps) || steps.length === 0) return false;
    return steps.every((step) =>
        step && typeof step === "object" && !Array.isArray(step)
        && step.tool !== "iphone_batch" && isToolAllowed(mode, step.tool));
}

export class IphoneGateError extends Error {
    constructor(message, kind = "refused") {
        super(message);
        this.kind = kind;
    }
}

/** Minimal MCP client over a child process' stdio (newline-delimited JSON-RPC). */
export function spawnMcp({ command, args = [], env = process.env, timeoutMs = 60_000 }) {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "ignore"], env });
    const pending = new Map();
    let nextId = 1;
    let closed = false;
    const fail = (error) => {
        closed = true;
        for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(error); }
        pending.clear();
    };
    child.once("error", (e) => fail(new IphoneGateError(`iphone-control did not start: ${e.message}`, "unavailable")));
    child.once("exit", () => fail(new IphoneGateError("iphone-control stopped", "unavailable")));
    createInterface({ input: child.stdout }).on("line", (line) => {
        let message;
        try { message = JSON.parse(line); } catch { return; }
        const entry = pending.get(message.id);
        if (!entry) return;
        pending.delete(message.id);
        clearTimeout(entry.timer);
        if (message.error) entry.reject(new IphoneGateError(message.error.message ?? "MCP error", "internal"));
        else entry.resolve(message.result);
    });
    const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
    return {
        request(method, params) {
            if (closed) return Promise.reject(new IphoneGateError("iphone-control is not running", "unavailable"));
            const id = nextId++;
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    pending.delete(id);
                    reject(new IphoneGateError(`${method} timed out`, "unavailable"));
                }, timeoutMs);
                pending.set(id, { resolve, reject, timer });
                send({ jsonrpc: "2.0", id, method, params });
            });
        },
        notify(method, params) { if (!closed) send({ jsonrpc: "2.0", method, params }); },
        close() { closed = true; child.kill(); },
    };
}

/**
 * @param {{mode: "readonly"|"control", connect: () => {request: Function, notify: Function, close: Function}}} options
 */
export function createIphoneGate({ mode, connect }) {
    if (!MODES.includes(mode)) throw new Error(`iphone mode must be one of ${MODES.join(", ")}`);
    let session = null;
    const open = () => {
        session ??= (async () => {
            const mcp = connect();
            await mcp.request("initialize", {
                protocolVersion: "2025-03-26",
                capabilities: {},
                clientInfo: { name: "isycode-sandbox-gate", version: "1" },
            });
            mcp.notify("notifications/initialized");
            return mcp;
        })().catch((error) => { session = null; throw error; });
        return session;
    };
    return {
        mode,
        /** The tools the agent may see: the device's own list, narrowed to what the mode allows. */
        async tools() {
            const { tools = [] } = await (await open()).request("tools/list", {});
            return tools.filter((tool) => isToolAllowed(mode, tool.name));
        },
        async call(name, args) {
            if (!isCallAllowed(mode, name, args)) {
                throw new IphoneGateError(`tool not allowed in ${mode} mode`);
            }
            return (await open()).request("tools/call", { name, arguments: args ?? {} });
        },
        async close() { if (session) { (await session.catch(() => null))?.close(); session = null; } },
    };
}

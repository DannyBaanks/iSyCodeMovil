/**
 * The only place in MovilClaw that talks to Docker.
 *
 * Everything the isolation policy promises is decided here, in one array of arguments,
 * so it can be read, tested and audited in a single place instead of being scattered.
 *
 * `spawn` is injected, so the tests can exercise the exact command line without a Docker
 * daemon, and the real runs use the same code path.
 */
import { spawn, spawn as nodeSpawn } from "node:child_process";

/** The isolation flags, named so a reviewer can check them one by one. */
export const ISOLATION = Object.freeze({
  /** No network namespace: nothing can leave the sandbox. */
  network: ["--network", "none"],
  /** Its own writable volume and nothing else from the host. */
  mounts: [], // deliberately empty: the sandbox never sees the host filesystem
  /** No extra powers. */
  privileges: ["--security-opt", "no-new-privileges"],
  /** A user that is not root inside the container. */
  user: ["--user", "1000:1000"],
  /** Ceilings so one sandbox cannot starve the others. */
  limits: (spec) => [
    "--memory", spec.memory,
    "--cpus", String(spec.cpus),
    "--pids-limit", String(spec.pids),
  ],
});

export const DEFAULT_SPEC = Object.freeze({ memory: "1g", cpus: 1, pids: 256 });

export class DockerError extends Error {}

/**
 * Build the full `docker run` argument vector.
 *
 * Exported and pure on purpose: the isolation is exactly this list, so a test can assert
 * every flag instead of trusting the description.
 */
export function runArgs(name, spec = DEFAULT_SPEC) {
  return [
    "run", "--detach",
    "--name", name,
    ...ISOLATION.network,
    ...ISOLATION.privileges,
    ...ISOLATION.user,
    ...ISOLATION.limits(spec),
    // the workspace volume is created by the orchestrator and named after the sandbox
    "--volume", `${name}-work:/work`,
    "--workdir", "/work",
    // no shell: the entrypoint is explicit and there is no unsandboxed fallback
    "--entrypoint", "/bin/sh",
    "movilclaw/sandbox:latest",
    "-c", "sleep infinity",
  ];
}

/**
 * Run one docker command and collect its output. Never builds a shell string.
 *
 * `input` (a Buffer or string) is written to the child's stdin, which lets a whole
 * archive travel through a pipe instead of the command line: argv has a hard size
 * limit (`spawn E2BIG`, a few megabytes), stdin does not.
 */
export function dockerSpawn(spawn = nodeSpawn) {
  return (args, { timeoutMs = 60_000, input = null } = {}) =>
    new Promise((resolve, reject) => {
      const child = spawn("docker", args, {
        stdio: [input === null ? "ignore" : "pipe", "pipe", "pipe"],
      });
      let out = "";
      let err = "";
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new DockerError(`docker ${args[0]} timed out`));
      }, timeoutMs);
      child.stdout?.on("data", (d) => { out += d; });
      child.stderr?.on("data", (d) => { err += d; });
      child.on("error", (e) => { clearTimeout(timer); reject(new DockerError(e.message)); });
      if (input !== null) {
        // Docker may exit before reading everything; the close handler reports that.
        child.stdin.on("error", () => {});
        child.stdin.end(input);
      }
      child.on("close", (code) => {
        clearTimeout(timer);
        if (code === 0) resolve({ out: out.trim(), err: err.trim() });
        else reject(new DockerError(`docker ${args[0]} failed (${code}): ${err.trim() || out.trim()}`));
      });
    });
}

/**
 * A tiny adapter over the two Docker calls the orchestrator needs.
 * Kept separate so tests can pass a fake with the same shape.
 */
export function realDocker(run = dockerSpawn()) {
  return {
    async start(name, spec) {
      await run(runArgs(name, spec));
    },
    /**
     * Destroy the container AND its data.
     *
     * `docker rm --volumes` only removes *anonymous* volumes. A named volume —which is
     * what the orchestrator creates— survives it, data included, and can be mounted
     * again. That was measured, not assumed: see tests/isolation.test.mjs. So the volume
     * is removed explicitly, and if that fails the caller is told instead of being left
     * with data that should be gone.
     */
    async stop(name) {
      await run(["rm", "--force", name]);
      try {
        await run(["volume", "rm", "--force", `${name}-work`]);
      } catch (error) {
        throw new DockerError(
          `container removed but its volume could not be deleted; data may remain: ${error.message}`,
        );
      }
    },
    async pause(name) {
      await run(["pause", name]);
    },
    async resume(name) {
      await run(["unpause", name]);
    },
    /** Used by the isolation tests: run one command inside and return its output. */
    async exec(name, argv) {
      const { out } = await run(["exec", name, ...argv]);
      return out;
    },

    /**
     * Run one command and return both output and exit code.
     *
     * The terminal and the repository tools need to know *whether* a command failed, not
     * only what it printed. The argv is a list, never a shell string, so nothing the caller
     * sends is interpreted by a shell.
     *
     * With `input`, the command runs under `docker exec -i` and the bytes arrive through
     * stdin — the only channel big enough for a whole repository.
     */
    /**
     * Run one command inside a container, optionally piping bytes to its stdin.
     *
     * When there is data to send it uses `spawn` and not `promisify(execFile)` with an
     * `input` option. That is a fix, and the reason is worth keeping: with `execFile` the
     * call **never came back** when the payload was an archive, which silently stalled
     * every push-and-open-PR — the branch never appeared and no error was ever raised.
     * Measured side by side on the same archive: `execFile` hung until cancelled,
     * `spawn` finished in 9 ms.
     *
     * stdin is ended explicitly; that is what tells the command there is no more input.
     */
    async runCommand(name, argv, { timeoutMs = 120_000, input = null } = {}) {
      if (input !== null && input !== undefined) {
        return new Promise((resolve) => {
          const child = spawn("docker", ["exec", "-i", name, ...argv], {
            stdio: ["pipe", "pipe", "pipe"],
          });
          let out = "";
          let err = "";
          const timer = setTimeout(() => {
            child.kill("SIGKILL");
            resolve({ code: 124, out, err: `${err}\nse cancelo tras ${Math.round(timeoutMs / 1000)}s`.trim() });
          }, timeoutMs);
          child.stdout?.on("data", (chunk) => { out += chunk; });
          child.stderr?.on("data", (chunk) => { err += chunk; });
          child.on("error", (error) => {
            clearTimeout(timer);
            resolve({ code: 1, out, err: error.message });
          });
          child.on("close", (code) => {
            clearTimeout(timer);
            resolve({ code: code ?? 1, out: out.trim(), err: err.trim() });
          });
          child.stdin.end(input);
        });
      }

      try {
        const { out, err } = await run(["exec", name, ...argv], { timeoutMs });
        return { code: 0, out, err };
      } catch (error) {
        // A non-zero exit is a result, not an internal failure: report it instead of throwing.
        const message = error instanceof Error ? error.message : String(error);
        const match = /failed \((\d+)\): ([\s\S]*)$/.exec(message);
        return { code: match ? Number(match[1]) : 1, out: "", err: match ? match[2] : message };
      }
    },

    // ── network attachments, used by the phase scheduler ──────────────────────
    async attachedNetworks(name) {
      const { out } = await run([
        "inspect", name,
        "--format", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}",
      ]);
      return out.split(/\s+/).filter(Boolean);
    },
    async ensureNetwork(network) {
      // Created if missing; "already exists" is not an error.
      await run(["network", "create", network]).catch(() => {});
    },
    async connectNetwork(name, network) {
      await run(["network", "connect", network, name]);
    },
    async disconnectNetwork(name, network) {
      await run(["network", "disconnect", network, name]).catch(() => {});
    },
  };
}

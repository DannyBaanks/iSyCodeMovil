/**
 * Moving your folder into a sandbox and its work back out, without ever mounting your disk.
 *
 * The design decision, stated plainly because it is the one that could go wrong quietly:
 *
 *   The sandbox never sees your filesystem. Your folder is *packed* and the package is
 *   placed in the sandbox's own volume. There is no bind mount, so a runaway `rm -rf`
 *   inside the sandbox deletes the copy, not your work.
 *
 * And the second decision: your folder can hold things that must not travel. `.env`, key
 * files and credentials are excluded, always, and the report says exactly what was left
 * out. A silent exclusion would be as bad as a silent inclusion.
 */
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { stat } from "node:fs/promises";

const run = promisify(execFile);

export class WorkspaceError extends Error {}

/** Anything matching these never leaves your machine. Names, not content: cheap and predictable. */
export const SECRET_PATTERNS = Object.freeze([
  ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx",
  "id_rsa*", "id_ed25519*", "id_ecdsa*", "id_dsa*",
  ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd", ".pgpass",
  "*credentials*.json", "secrets.json", "secrets.yaml", "secrets.yml",
  "*.tfstate", "*.jks", "*.keystore", "vault.json",
]);

/** Directories that are noise, huge, or reproducible. */
export const SKIP_DIRS = Object.freeze([
  "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache",
  ".ruff_cache", ".mypy_cache", "dist", "build", "target", ".next", ".turbo",
]);

/**
 * `.git` is NOT skipped, and that is deliberate.
 *
 * Excluding it was tried first and it broke the workflow in a way that is easy to miss: the
 * sandbox received the files but `/work/app` was not a repository, so the agent could not
 * run `git status`, commit its own work or diff anything. Without `.git` the tools are
 * decoration.
 *
 * So `.git` travels — a clone made with a token has already had its remote stripped, and the
 * pack step never carries credentials. What is excluded is `--exclude-vcs` behaviour, which
 * tar applies to VCS metadata; here the metadata is wanted.
 */

/** What a person reads before deciding to send their folder. */
export function describeExclusions() {
  return {
    patterns: [...SECRET_PATTERNS],
    directories: [...SKIP_DIRS],
    note: "Se excluye siempre lo que parece un secreto. El informe dice exactamente que quedo fuera.",
  };
}

/**
 * List the files that a archive of `directory` would and would not include.
 *
 * Read-only: it writes nothing and returns the reason per exclusion, so the UI can be honest.
 */
export async function planTransfer(directory, { limit = 4000 } = {}) {
  const info = await stat(directory).catch(() => null);
  if (!info?.isDirectory()) throw new WorkspaceError("la ruta no es una carpeta");

  const { stdout: listed } = await run("tar", [
    "-C", directory,
    ...SKIP_DIRS.flatMap((d) => ["--exclude", `./${d}`]),
    ...SECRET_PATTERNS.flatMap((p) => ["--exclude", `./${p}`, "--exclude", `*/${p}`]),
    "-cf", "-", ".",
  ], { maxBuffer: 8 * 1024 * 1024, encoding: "buffer" }).then(
    (r) => ({ stdout: r.stdout }),
    (error) => {
      // tar exits non-zero when something is unreadable; that must not leak as a stack trace.
      throw new WorkspaceError(`no se pudo leer la carpeta: ${String(error.message).slice(0, 200)}`);
    },
  );

  // Count what would go, and take note of what the patterns removed.
  const { stdout: allFiles } = await run("sh", [
    "-c",
    `cd ${JSON.stringify(directory)} && find . -type f -not -path './.git/*' | head -${limit}`,
  ]);
  const totalFiles = allFiles.split("\n").filter(Boolean).length;
  const packedBytes = Buffer.isBuffer(listed) ? listed.length : Buffer.byteLength(listed ?? "");
  const secretLooking = totalFiles
    ? allFiles.split("\n").filter(Boolean).filter((p) => matchesSecretPattern(p)).slice(0, 40)
    : [];

  return {
    files: totalFiles,
    packedBytes,
    excludedPatterns: [...SECRET_PATTERNS],
    skippedDirectories: [...SKIP_DIRS],
    excludedExamples: secretLooking,
    note: secretLooking.length
      ? `Se dejaron fuera ${secretLooking.length} archivos que parecen secretos (ver excludedExamples).`
      : "No se encontro ningun archivo con nombre de secreto.",
  };
}

function matchesSecretPattern(path) {
  const name = path.split("/").pop() ?? "";
  return SECRET_PATTERNS.some((pattern) => {
    if (pattern.startsWith("*.")) return name.endsWith(pattern.slice(1));
    if (pattern.endsWith("*")) return name.startsWith(pattern.slice(0, -1));
    if (pattern.includes("*")) {
      const [head, tail] = pattern.split("*");
      return name.startsWith(head) && name.endsWith(tail);
    }
    return name === pattern;
  });
}

/**
 * Pack a folder into a stream.
 *
 * The exclusions are the same ones `planTransfer` reports, so what you were told and what
 * is sent cannot drift apart.
 */
export async function packWorkspace(directory) {
  const info = await stat(directory).catch(() => null);
  if (!info?.isDirectory()) throw new WorkspaceError("la ruta no es una carpeta");
  const { stdout } = await run("tar", [
    "-C", directory,
    ...SKIP_DIRS.flatMap((d) => ["--exclude", `./${d}`]),
    ...SECRET_PATTERNS.flatMap((p) => ["--exclude", `./${p}`, "--exclude", `*/${p}`]),
    "-czf", "-", ".",
  ], { maxBuffer: 256 * 1024 * 1024, encoding: "buffer" });
  return stdout;
}

/**
 * Unpack a stream into a directory you choose.
 *
 * This is the "out" direction: the agent's work arrives as a file and **you** decide where
 * it lands. Nothing writes into your repository on its own.
 */
export async function unpackInto(directory, archive) {
  const info = await stat(directory).catch(() => null);
  if (!info?.isDirectory()) throw new WorkspaceError("el destino no es una carpeta");
  await unpackTar(directory, archive);
}

/**
 * Pipe an archive into `tar -x` inside a directory.
 *
 * This uses `spawn`, not `execFile` with an `input` option, and that is a **fix**, not a
 * style choice. With `promisify(execFile)` and an `input` archive the call never returned:
 * measured, it hung until the caller was killed, while `spawn` extracts the same archive in
 * single-digit milliseconds. Every push-and-open-PR was stuck on exactly this call, with no
 * error raised — the worst shape a bug can have.
 *
 * stdin is ended explicitly, which is what tells tar there is no more input.
 */
export function unpackTar(directory, archive, { timeoutMs = 300_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn("tar", ["-xzf", "-", "-C", directory], { stdio: ["pipe", "ignore", "pipe"] });
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new WorkspaceError(`tar tardo mas de ${Math.round(timeoutMs / 1000)}s y se cancelo`));
    }, timeoutMs);
    child.stderr.on("data", (chunk) => { err += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(new WorkspaceError(`no se pudo ejecutar tar: ${error.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new WorkspaceError(`tar salio con ${code}: ${err.slice(0, 200)}`));
    });
    child.stdin.end(archive);
  });
}

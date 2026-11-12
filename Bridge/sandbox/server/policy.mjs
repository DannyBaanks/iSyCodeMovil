/**
 * What the agent is allowed to do with a repository.
 *
 * Two rules, and both exist because of a real failure mode:
 *
 *  1. **`main` is read-only.** An agent that can push to the default branch can rewrite
 *     history you depend on. Work goes to a branch, and you merge it. Nobody merges it
 *     for you.
 *
 *  2. **Nothing destructive exists.** Not "it is discouraged": the operations are not in
 *     the code. Deleting a repository, changing its visibility, force-pushing or dropping
 *     a branch are irreversible, and none of them are needed to do useful work.
 *
 * The branch prefix is also the honest attribution. I cannot sign a commit as Claude or
 * as Copilot, so the branch name says plainly where the work came from: `movilclaw/<task>`.
 * That way you can see at a glance which branches came from the agent, and delete them
 * with one command when you are done.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** The branch prefix that marks agent work, and the way to clean it up later. */
export const BRANCH_PREFIX = "movilclaw/";

/** Branch names that mean "the shared trunk". Pushing to any of these is refused. */
export const PROTECTED_BRANCHES = Object.freeze(["main", "master", "trunk", "develop", "development"]);

export class PolicyError extends Error {}

/**
 * Operations that do not exist in this project, each with the reason it is missing.
 * Kept as data so the API can explain a refusal, and so a reviewer can check the list.
 */
export const FORBIDDEN = Object.freeze({
  "repo.delete": "borrar un repositorio es irreversible y no hace falta para trabajar",
  "repo.visibility": "cambiar la visibilidad expone o esconde codigo ajeno a la tarea",
  "repo.settings": "la configuracion del repositorio no es parte de editar codigo",
  "repo.transfer": "mover el repositorio de dueno no es una tarea de agente",
  "branch.delete": "borrar una rama pierde trabajo y deja el PR huerfano",
  "tag.delete": "borrar una etiqueta rompe publicaciones que dependen de ella",
  "push.force": "reescribir historia convierte un error en una perdida",
  "pr.merge": "fusionar es una decision humana, nunca del agente",
  "pr.close": "cerrar un PR ajeno mete al agente donde no lo llamaron",
  "secrets.write": "los secretos del repositorio no se tocan desde un agente",
  "collaborators": "dar o quitar acceso es una decision del dueno",
  "webhooks": "un webhook entrega datos fuera del repositorio",
});

/** Refuse a forbidden operation, naming the reason instead of failing vaguely. */
export function assertAllowed(operation) {
  const reason = FORBIDDEN[operation];
  if (reason) throw new PolicyError(`"${operation}" no esta permitido: ${reason}`);
}

/** The only branch shape this project will push to. */
export function assertPushableBranch(branch) {
  if (typeof branch !== "string" || !branch.trim()) {
    throw new PolicyError("hace falta el nombre de la rama");
  }
  const clean = branch.trim();
  if (PROTECTED_BRANCHES.includes(clean.toLowerCase())) {
    throw new PolicyError(
      `no se empuja a "${clean}": es una rama compartida. El trabajo va a una rama ${BRANCH_PREFIX}<tarea> y se abre un PR`,
    );
  }
  if (!clean.startsWith(BRANCH_PREFIX)) {
    throw new PolicyError(`la rama debe empezar por "${BRANCH_PREFIX}" para que se vea que la hizo el agente`);
  }
  if (clean.length > 120 || /[\s~^:?*[\]\\]/.test(clean) || clean.includes("..")) {
    throw new PolicyError("el nombre de la rama no es valido");
  }
  return clean;
}

/**
 * Build the branch name for a task: `movilclaw/<slug>`.
 * The date is appended when no task name is given, so two runs never collide.
 */
export function branchFor(task, now = new Date()) {
  const slug = String(task ?? "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  const day = now.toISOString().slice(0, 10);
  return `${BRANCH_PREFIX}${slug || "cambios"}-${day}`;
}

/**
 * Is the default branch protected on the remote?
 *
 * This is read-only and it is reported, never assumed: if `main` is *not* protected, you
 * should know before the agent pushes anything, not after.
 */
export async function defaultBranchProtection(remoteUrl, token, { timeoutMs = 20_000 } = {}) {
  const match = /github\.com[/:]([^/]+)\/([^/.]+)/.exec(remoteUrl ?? "");
  if (!match) return { known: false, reason: "no parece un repositorio de github.com" };
  const [, owner, repo] = match;
  try {
    const { stdout } = await run("curl", [
      "-s", "-o", "-", "-w", "\n%{http_code}", "--max-time", "15",
      "-H", `Authorization: Bearer ${token}`,
      "-H", "Accept: application/vnd.github+json",
      `https://api.github.com/repos/${owner}/${repo}/branches/main/protection`,
    ], { timeout: timeoutMs });
    const code = stdout.trim().split("\n").pop();
    if (code === "200") return { known: true, protected: true };
    if (code === "404") {
      // 404 means either "not protected" or "no access". Both deserve the same warning.
      return { known: true, protected: false, reason: "main no tiene proteccion, o el token no puede verla" };
    }
    return { known: false, reason: `github respondio ${code}` };
  } catch (error) {
    return { known: false, reason: `no se pudo consultar: ${error.message}` };
  }
}

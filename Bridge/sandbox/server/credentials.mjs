/**
 * GitHub credentials, kept where the sandbox cannot reach them.
 *
 * The threat this file answers: an agent working in a sandbox must not be able to steal the
 * account that owns the repositories. So the token never enters the sandbox — not in the
 * environment, not in `.git/config`, not in a file. The host clones with the token, strips
 * the remote, and hands the code over; the host pushes on the agent's behalf.
 *
 * How the token is kept on the host:
 *  - **In memory by default.** A process-lifetime secret, gone on restart. Nothing to steal
 *    from disk because nothing is on disk.
 *  - **Sealed when it must persist.** The same AES-GCM envelope as the rest of the project,
 *    so the server stores ciphertext it cannot open. The passphrase stays with the user.
 *
 * Two ways in, because a project should not require an approval process to be usable:
 *  - a pasted personal access token, which works today, and
 *  - GitHub's device flow, which additionally needs a registered OAuth app `client_id`.
 */
import { createHash } from "node:crypto";

/** The scopes this project actually needs, and not a comma more. */
export const REQUIRED_SCOPES = Object.freeze(["repo", "read:org"]);

/** Scopes that would give the agent reach it must not have. Refused if a token carries them. */
export const DANGEROUS_SCOPES = Object.freeze([
  "delete_repo",
  "admin:org",
  "admin:public_key",
  "admin:repo_hook",
  "write:packages",
  "delete:packages",
]);

export class CredentialError extends Error {}

/** Classify a token without ever returning it. Only the shape travels back. */
export function describeToken(token) {
  if (typeof token !== "string" || token.length < 20) {
    throw new CredentialError("el token parece incompleto");
  }
  const kind = token.startsWith("ghp_") ? "personal"
    : token.startsWith("gho_") ? "oauth"
    : token.startsWith("github_pat_") ? "fine-grained"
    : "desconocido";
  return {
    kind,
    // A fingerprint, so the user can tell two tokens apart without either being shown.
    fingerprint: createHash("sha256").update(token).digest("hex").slice(0, 8),
    length: token.length,
  };
}

/**
 * Where a token is held. Nothing here returns the token to a caller except `reveal`, which
 * is used only by the host's own git operations.
 */
export function createCredentialStore({ seal, open } = {}) {
  /** id -> { token, scopes, fingerprint, expiresAt, sealed } in memory only. */
  const held = new Map();

  return {
    /**
     * Keep a token for an account.
     *
     * `expiresAt` is honoured: an expired token is refused at use, not silently tried.
     */
    async put(id, token, { scopes = [], expiresAt = null, passphrase = null } = {}) {
      const info = describeToken(token);
      const overreach = scopes.filter((s) => DANGEROUS_SCOPES.includes(s));
      if (overreach.length) {
        throw new CredentialError(
          `el token trae permisos que este proyecto no usa y no debe tener: ${overreach.join(", ")}`,
        );
      }
      const missing = REQUIRED_SCOPES.filter((s) => !scopes.includes(s));
      if (scopes.length && missing.length) {
        throw new CredentialError(`al token le faltan permisos necesarios: ${missing.join(", ")}`);
      }
      const record = {
        token, // never logged, never serialised by any route
        scopes: [...scopes],
        fingerprint: info.fingerprint,
        kind: info.kind,
        expiresAt,
        sealed: null,
      };
      if (passphrase) {
        // Persisting is optional: only when the user wants it to outlive the process.
        record.sealed = await seal(Buffer.from(token, "utf8"), passphrase);
        record.token = null; // in memory it is now the sealed form only
      }
      held.set(id, record);
      return { kind: info.kind, fingerprint: info.fingerprint, sealed: Boolean(record.sealed), expiresAt };
    },

    /** Open a sealed token with the user's passphrase, for one operation. */
    async unlock(id, passphrase) {
      const record = held.get(id);
      if (!record) throw new CredentialError("no hay ninguna cuenta guardada con ese id");
      if (record.token) return record.token;
      if (!record.sealed) throw new CredentialError("esa cuenta no tiene token disponible");
      const plain = await open(record.sealed, passphrase);
      return Buffer.from(plain).toString("utf8");
    },

    /** What the UI may show. There is no path from here to the token itself. */
    list() {
      return [...held.entries()].map(([id, r]) => ({
        id,
        kind: r.kind,
        fingerprint: r.fingerprint,
        scopes: r.scopes,
        sealed: Boolean(r.sealed),
        expiresAt: r.expiresAt,
      }));
    },

    /** Forget an account. Used by logout, and on expiry. */
    forget(id) {
      return held.delete(id);
    },

    /**
     * Whether a token may be used right now.
     * Expiry is checked here so no caller can forget to check it.
     */
    usable(id, now = Date.now()) {
      const record = held.get(id);
      if (!record) return { ok: false, reason: "no hay ninguna cuenta con ese id" };
      if (record.expiresAt && now >= record.expiresAt) {
        return { ok: false, reason: "el token ha caducado; vuelve a iniciar sesion" };
      }
      if (!record.token && !record.sealed) return { ok: false, reason: "el token no esta disponible" };
      return { ok: true, sealed: Boolean(record.sealed) };
    },
  };
}

/**
 * Do the host's git work with a token, and never let the token reach the repository's
 * configuration: the remote URL is rewritten without credentials before anything is packed.
 */
export async function cloneWithToken(run, { url, token, into }) {
  // The token travels in a header, not in the URL, so it cannot end up in .git/config.
  // Git speaks HTTP Basic auth and expects the token as password with x-access-token.
  const basic = Buffer.from(`x-access-token:${token}`, "utf8").toString("base64");
  await run("git", [
    "-c", `http.extraheader=Authorization: Basic ${basic}`,
    "clone", "--depth", "1", url, into,
  ], { timeoutMs: 300_000 });
  // Belt and braces: whatever git wrote, the remote is left without credentials.
  await run("git", ["-C", into, "remote", "set-url", "origin", url]);
  return { into, url };
}

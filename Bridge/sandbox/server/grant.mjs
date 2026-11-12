/**
 * The time-limited signed grant: "la firma que él decidió por tiempo".
 *
 * A grant says: *this passphrase holder may unseal this sandbox until this moment*.
 * It is signed with the server's secret, so it cannot be forged, and it carries its
 * own expiry, so it cannot be replayed later.
 *
 * What it deliberately does NOT do: it does not give the server the passphrase, and it
 * does not let the server read a sealed blob. The signature proves *who* may unseal and
 * *until when*; the passphrase is still the only thing that opens the data.
 */
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export const GRANT_FORMAT = "movilclaw/grant/1";
/** The longest a grant may live, so a typo cannot mint a year-long pass. */
export const MAX_GRANT_MS = 24 * 60 * 60 * 1000;

export class GrantError extends Error {}

/** The server secret. Generated once per process if the operator did not provide one. */
export function serverSecret(env = process.env) {
  const provided = env.MOVILCLAW_GRANT_SECRET;
  if (provided && provided.length >= 16) return provided;
  if (!serverSecret._generated) {
    // A process-lifetime secret: grants do not survive a restart, which is the safe default.
    serverSecret._generated = randomBytes(32).toString("base64url");
    if (env.MOVILCLAW_GRANT_SECRET === undefined) {
      // Say it out loud: an operator who wants grants to survive a restart must set it.
      console.warn("[movilclaw] MOVILCLAW_GRANT_SECRET not set; grants will not survive a restart");
    }
  }
  return serverSecret._generated;
}

function sign(payload, secret) {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

/**
 * Mint a grant for one sandbox, for a limited time.
 * `ttlMs` is clamped to MAX_GRANT_MS: the caller cannot ask for more.
 */
export function issueGrant(sandboxId, ttlMs, { secret = serverSecret(), now = Date.now() } = {}) {
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) throw new GrantError("ttl must be a positive number of ms");
  const expiresAt = now + Math.min(ttlMs, MAX_GRANT_MS);
  const body = JSON.stringify({ format: GRANT_FORMAT, sandboxId, issuedAt: now, expiresAt });
  const payload = Buffer.from(body, "utf8").toString("base64url");
  return { token: `${payload}.${sign(payload, secret)}`, expiresAt };
}

/** Verify a grant: signature first, then expiry. Returns a verdict with a reason. */
export function verifyGrant(token, sandboxId, { secret = serverSecret(), now = Date.now() } = {}) {
  if (typeof token !== "string" || !token.includes(".")) {
    return { ok: false, reason: "el permiso no tiene el formato esperado" };
  }
  const [payload, signature] = token.split(".");
  const expected = sign(payload, secret);
  const given = Buffer.from(signature ?? "", "utf8");
  const want = Buffer.from(expected, "utf8");
  // Constant time, and length-checked first because timingSafeEqual throws on mismatch.
  if (given.length !== want.length || !timingSafeEqual(given, want)) {
    return { ok: false, reason: "la firma no es valida" };
  }
  let body;
  try {
    body = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return { ok: false, reason: "el permiso no se puede leer" };
  }
  if (body.format !== GRANT_FORMAT) return { ok: false, reason: "el permiso es de otro formato" };
  if (body.sandboxId !== sandboxId) return { ok: false, reason: "el permiso es de otro sandbox" };
  if (now > body.expiresAt) {
    return { ok: false, reason: "el permiso ha caducado", expiresAt: body.expiresAt };
  }
  return { ok: true, expiresAt: body.expiresAt };
}

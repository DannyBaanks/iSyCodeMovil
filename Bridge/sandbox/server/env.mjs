/**
 * Read a local `.env` file, so configuration does not have to be retyped on every start.
 *
 * Why this exists: the GitHub `client_id` was being passed inline
 * (`MOVILCLAW_GITHUB_CLIENT_ID=... npm start`), and retyping it every time is exactly how a
 * value ends up pasted into a shell history, a chat, or a commit. A file that is already
 * git-ignored is the safer place for something you have to keep.
 *
 * Deliberately tiny and dependency-free, with three rules that matter:
 *  - **The file never wins over the real environment.** An inline variable or a systemd unit
 *    must be able to override a stale file.
 *  - **It never overwrites what is already set**, so nothing here can hijack a variable.
 *  - **It never logs values.** Only which keys were read, because a client_id is not a secret
 *    but a token could be, and this loader does not get to decide which is which.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

/** Keys this project reads from the file. A closed list: an env file is not a back door. */
export const SUPPORTED_KEYS = Object.freeze([
  "MOVILCLAW_GITHUB_CLIENT_ID",
  "MOVILCLAW_STATE",
  "MOVILCLAW_ALLOW_EXEC",
  "MOVILCLAW_GRANT_SECRET",
  "PORT",
  "HOST",
]);

/** Parse `KEY=value` lines: comments, blanks, quotes and `export` are all tolerated. */
export function parseEnvFile(text) {
  const out = {};
  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const withoutExport = line.startsWith("export ") ? line.slice(7).trim() : line;
    const equals = withoutExport.indexOf("=");
    if (equals <= 0) continue;
    const key = withoutExport.slice(0, equals).trim();
    let value = withoutExport.slice(equals + 1).trim();
    // Strip one layer of matching quotes, which people add out of habit.
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!/^[A-Z_][A-Z0-9_]*$/.test(key)) continue;
    out[key] = value;
  }
  return out;
}

/**
 * Load `.env` into `env`, without ever overriding a variable that is already present.
 * Returns what it actually set, so a caller can report it truthfully.
 */
export function loadEnvFile({ directory = process.cwd(), env = process.env, filename = ".env" } = {}) {
  let text;
  try {
    text = readFileSync(resolve(directory, filename), "utf8");
  } catch {
    return { loaded: [], path: resolve(directory, filename), found: false };
  }

  const parsed = parseEnvFile(text);
  const loaded = [];
  for (const [key, value] of Object.entries(parsed)) {
    if (!SUPPORTED_KEYS.includes(key)) continue; // ignored on purpose, never reported as loaded
    if (env[key] !== undefined && env[key] !== "") continue; // the real environment wins
    env[key] = value;
    loaded.push(key);
  }
  return { loaded, path: resolve(directory, filename), found: true };
}

/** A client_id is not a secret, but keep showing only enough to confirm it is the right app. */
export function describeClientId(clientId) {
  if (!clientId) return null;
  return {
    present: true,
    // The first characters are enough to tell two apps apart without dumping the whole value.
    preview: `${clientId.slice(0, 8)}…`,
    length: clientId.length,
  };
}

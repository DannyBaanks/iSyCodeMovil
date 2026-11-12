/**
 * Sealing: encryption that the server cannot undo.
 *
 * The point of this module is a property, not a feature: **the key never leaves the
 * browser**. The server stores an opaque blob and, by construction, has nothing that
 * opens it. This file is used by the PWA and by the tests, so what is tested is the
 * exact code that runs.
 *
 * Honest scope, because this is easy to oversell:
 *  - This protects data AT REST: the sealed blob is unreadable without the passphrase.
 *  - It does NOT protect a running sandbox: whoever is root on the host can read the
 *    memory of a live container. That needs hardware (SEV/TDX) this machine does not have.
 */
const SUBTLE = globalThis.crypto.subtle;

/** Envelope version, so an old blob is never read with new code. */
export const SEAL_FORMAT = "movilclaw/sealed/1";
/** PBKDF2 rounds. High on purpose: a weak passphrase is the weak link, not the cipher. */
export const PBKDF2_ITERATIONS = 600_000;
const SALT_BYTES = 16;
const IV_BYTES = 12; // 96-bit nonce, the size AES-GCM expects

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Turn a passphrase into an AES-256-GCM key. Never returns the passphrase. */
export async function deriveKey(passphrase, salt) {
  if (typeof passphrase !== "string" || passphrase.length < 8) {
    throw new Error("la frase secreta debe tener al menos 8 caracteres");
  }
  const material = await SUBTLE.importKey("raw", encoder.encode(passphrase), "PBKDF2", false, ["deriveKey"]);
  return SUBTLE.deriveKey(
    { name: "PBKDF2", salt, iterations: PBKDF2_ITERATIONS, hash: "SHA-256" },
    material,
    { name: "AES-GCM", length: 256 },
    false, // not extractable: the key can be used but never read back
    ["encrypt", "decrypt"],
  );
}

/**
 * Encrypt bytes with a passphrase. Returns the envelope as JSON text.
 *
 * The salt and IV are random per call, so sealing the same file twice gives different
 * bytes, and an attacker cannot tell two blobs apart or replay one onto another.
 */
export async function seal(bytes, passphrase) {
  const salt = globalThis.crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const key = await deriveKey(passphrase, salt);
  const ciphertext = new Uint8Array(await SUBTLE.encrypt({ name: "AES-GCM", iv }, key, bytes));
  return JSON.stringify({
    format: SEAL_FORMAT,
    kdf: { name: "PBKDF2", hash: "SHA-256", iterations: PBKDF2_ITERATIONS, salt: b64(salt) },
    cipher: { name: "AES-256-GCM", iv: b64(iv) },
    // The GCM tag is appended by WebCrypto, so the ciphertext is tamper-evident.
    data: b64(ciphertext),
  });
}

/**
 * Decrypt a sealed envelope. Throws if the passphrase is wrong or the blob was altered.
 * A wrong passphrase and a modified byte are indistinguishable here on purpose: AES-GCM
 * fails authentication in both cases, and that is the correct behaviour.
 */
export async function open(sealed, passphrase) {
  const envelope = typeof sealed === "string" ? JSON.parse(sealed) : sealed;
  if (!envelope || envelope.format !== SEAL_FORMAT) {
    throw new Error("el archivo no es un sello de MovilClaw");
  }
  if (envelope.kdf?.iterations !== PBKDF2_ITERATIONS || envelope.kdf?.hash !== "SHA-256") {
    throw new Error("el sello usa parametros que esta version no acepta");
  }
  const salt = unb64(envelope.kdf.salt);
  const iv = unb64(envelope.cipher.iv);
  const data = unb64(envelope.data);
  const key = await deriveKey(passphrase, salt);
  try {
    const plain = await SUBTLE.decrypt({ name: "AES-GCM", iv }, key, data);
    return new Uint8Array(plain);
  } catch {
    throw new Error("no se pudo abrir: la frase secreta no es correcta o el archivo fue alterado");
  }
}

/** What the UI can show about a sealed file without opening it: no secrets here. */
export function inspect(sealed) {
  const envelope = typeof sealed === "string" ? JSON.parse(sealed) : sealed;
  if (!envelope || envelope.format !== SEAL_FORMAT) return null;
  return {
    format: envelope.format,
    kdf: envelope.kdf?.name,
    iterations: envelope.kdf?.iterations,
    cipher: envelope.cipher?.name,
    bytes: Math.floor((envelope.data?.length ?? 0) * 3 / 4),
  };
}

function b64(bytes) {
  if (typeof Buffer !== "undefined") {
    return Buffer.from(bytes).toString("base64");
  }
  const chunks = [];
  const chunkSize = 0x8000; // 32KB chunk avoids call stack size limits
  for (let i = 0; i < bytes.length; i += chunkSize) {
    chunks.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize)));
  }
  return btoa(chunks.join(""));
}
function unb64(text) {
  if (typeof Buffer !== "undefined") {
    return new Uint8Array(Buffer.from(text, "base64"));
  }
  const raw = atob(text);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

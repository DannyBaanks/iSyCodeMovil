/**
 * Where sealed blobs live on the host.
 *
 * The server keeps ciphertext and a manifest. It has no key, no passphrase and no way in,
 * by construction: the only functions here take bytes and store them. There is deliberately
 * no `decrypt` in this file, and adding one would defeat the whole design.
 *
 * A sealed blob is only accepted when it is a well-formed envelope, so a caller cannot use
 * this as a general file dump.
 */
import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const SEAL_FORMAT = "movilclaw/sealed/1";
const MAX_SEAL_BYTES = 64 * 1024 * 1024; // 64 MiB: a workspace snapshot, not a disk image

export class SealedError extends Error {}

/** Validate the envelope shape. Only shape: the server cannot check the contents. */
function assertEnvelope(text) {
  let envelope;
  try {
    envelope = JSON.parse(text);
  } catch {
    throw new SealedError("el sello no es JSON");
  }
  if (!envelope || envelope.format !== SEAL_FORMAT) {
    throw new SealedError("el sello no tiene el formato esperado");
  }
  if (envelope.kdf?.name !== "PBKDF2" || typeof envelope.kdf?.salt !== "string") {
    throw new SealedError("el sello no declara como derivar la clave");
  }
  if (envelope.cipher?.name !== "AES-256-GCM" || typeof envelope.cipher?.iv !== "string") {
    throw new SealedError("el sello no declara el cifrado esperado");
  }
  if (typeof envelope.data !== "string" || !envelope.data) {
    throw new SealedError("el sello no trae datos");
  }
  return envelope;
}

export function createSealedStore(root) {
  const dir = join(root, "sealed");
  return {
    /** Store ciphertext under an id. Returns only what is safe to show. */
    async put(id, text) {
      if (!/^mc-[a-z0-9]{4,32}$/.test(id)) throw new SealedError("id de sandbox invalido");
      const envelope = assertEnvelope(text);
      const bytes = Buffer.byteLength(text, "utf8");
      if (bytes > MAX_SEAL_BYTES) throw new SealedError(`el sello supera ${MAX_SEAL_BYTES / 1024 / 1024} MiB`);
      await mkdir(dir, { recursive: true, mode: 0o700 });
      // 0600: only this user can read the file, and even then it is ciphertext.
      await writeFile(join(dir, `${id}.sealed.json`), text, { encoding: "utf8", mode: 0o600 });

      // The digest is what the client checks after downloading: proof the blob did not change.
      const digest = createHash("sha256").update(text).digest("hex");
      const manifest = {
        format: "movilclaw/sealed-manifest/1",
        sandboxId: id,
        bytes,
        digest,
        salt: envelope.kdf.salt,
        iterations: envelope.kdf.iterations,
        cipher: envelope.cipher.name,
        storedAt: Date.now(),
        // Said out loud so nobody has to guess: the host cannot read this.
        hostCanRead: false,
      };
      await writeFile(join(dir, `${id}.manifest.json`), JSON.stringify(manifest, null, 2), { encoding: "utf8", mode: 0o600 });
      return manifest;
    },

    /** The blob, for the client that holds the passphrase. */
    async get(id) {
      if (!/^mc-[a-z0-9]{4,32}$/.test(id)) throw new SealedError("id de sandbox invalido");
      try {
        return await readFile(join(dir, `${id}.sealed.json`), "utf8");
      } catch {
        throw new SealedError("no hay ningun sello guardado para ese sandbox");
      }
    },

    async manifest(id) {
      try {
        return JSON.parse(await readFile(join(dir, `${id}.manifest.json`), "utf8"));
      } catch {
        return null;
      }
    },

    async list() {
      try {
        const names = await readdir(dir);
        return names.filter((n) => n.endsWith(".manifest.json")).map((n) => n.replace(".manifest.json", ""));
      } catch {
        return [];
      }
    },

    /** Destroy the ciphertext. Irreversible, and there is no backup to fall back to. */
    async destroy(id) {
      if (!/^mc-[a-z0-9]{4,32}$/.test(id)) throw new SealedError("id de sandbox invalido");
      await rm(join(dir, `${id}.sealed.json`), { force: true });
      await rm(join(dir, `${id}.manifest.json`), { force: true });
    },
  };
}

/** A fresh id for a seal, so two seals of the same workspace never collide. */
export function newSealId() {
  return `mc-${randomBytes(6).toString("hex")}`;
}

// There is intentionally no decrypt() here. If you are about to add one, stop:
// the server is not supposed to be able to open what it stores.

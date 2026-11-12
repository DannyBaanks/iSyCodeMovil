/**
 * GitHub device flow: the way a person signs in without pasting a token.
 *
 * How it goes: the server asks GitHub for a short code, shows it to the person, the person
 * types it on github.com and approves, and the server exchanges it for a token. Nothing is
 * typed into our form, and no password ever touches this code.
 *
 * ## About the client_id, because this is the part that matters
 *
 * The device flow needs a `client_id`, and it must be **your** OAuth app's. Using another
 * app's id — even a public one from an open-source project — would mean GitHub shows that
 * app's name on the consent screen instead of MovilClaw's. The person is not authorizing
 * what they think they are, and the project would break the day that app rotates its id.
 *
 * So this module refuses to run without a client_id that the operator supplied, and says
 * how to get one instead of quietly working. Registering the app takes two minutes and is
 * free: https://github.com/settings/applications/new
 *
 * The client_id is not a secret (it travels in a URL), but it is not ours to invent.
 */
import { request as httpsRequest } from "node:https";

const DEVICE_CODE_URL = "https://github.com/login/device/code";
const TOKEN_URL = "https://github.com/login/oauth/access_token";

/** The scopes this project needs. `repo` covers private repositories; `read:org` is for org listings. */
export const DEFAULT_SCOPES = Object.freeze(["repo", "read:org"]);

/** How long a pending authorization lives, per GitHub. */
export const CODE_TTL_MS = 15 * 60_000;

export class OAuthError extends Error {}

/** Where the client_id comes from: the operator's environment, never a hardcoded value. */
export function configuredClientId(env = process.env) {
  const id = (env.MOVILCLAW_GITHUB_CLIENT_ID ?? "").trim();
  return id || null;
}

/**
 * Refuse to start the flow without a client_id, and explain how to get one.
 * Failing with instructions is better than failing with a stack trace, and far better
 * than silently using somebody else's app.
 */
export function requireClientId(env = process.env) {
  const id = configuredClientId(env);
  if (!id) {
    throw new OAuthError(
      "falta MOVILCLAW_GITHUB_CLIENT_ID. Registra una OAuth App en " +
        "https://github.com/settings/applications/new (es gratis) y arranca con " +
        "MOVILCLAW_GITHUB_CLIENT_ID=<tu_id>. No usamos el client_id de otra app: " +
        "GitHub mostraria su nombre en la pantalla de permisos, y eso seria enganarte.",
    );
  }
  return id;
}

/** POST a form-encoded endpoint and decode the JSON reply. Small helper, no dependencies. */
function postForm(url, params) {
  const body = new URLSearchParams(params).toString();
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      url,
      {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          accept: "application/json",
          "content-length": Buffer.byteLength(body),
        },
        timeout: 20_000,
      },
      (res) => {
        let data = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => { data += chunk; });
        res.on("end", () => {
          try {
            resolve(JSON.parse(data));
          } catch {
            reject(new OAuthError(`github respondio algo que no es JSON (${res.statusCode})`));
          }
        });
      },
    );
    req.on("timeout", () => { req.destroy(); reject(new OAuthError("github no respondio a tiempo")); });
    req.on("error", (error) => {
      // A transient DNS or socket failure is not a verdict from GitHub: it is the network
      // being unhelpful for a moment. Marked so the caller can retry instead of throwing
      // away an authorization the person already granted.
      const transient = ["EAI_AGAIN", "ENOTFOUND", "ETIMEDOUT", "ECONNRESET", "ECONNREFUSED", "EPIPE"]
        .some((code) => String(error.code ?? "").includes(code) || String(error.message).includes(code));
      const wrapped = new OAuthError(`no se pudo hablar con github: ${error.message}`);
      wrapped.transient = transient;
      reject(wrapped);
    });
    req.end(body);
  });
}

/**
 * Step 1: ask GitHub for a code to show the person.
 * Returns the user code, where to type it, and when it dies.
 */
export async function requestDeviceCode({ clientId = requireClientId(), scopes = DEFAULT_SCOPES } = {}) {
  const reply = await postForm(DEVICE_CODE_URL, { client_id: clientId, scope: scopes.join(" ") });
  if (!reply.device_code || !reply.user_code) {
    throw new OAuthError(`github no devolvio un codigo: ${reply.error_description ?? reply.error ?? "sin motivo"}`);
  }
  return {
    deviceCode: reply.device_code, // kept server-side; it is the secret half
    userCode: reply.user_code, // this is what the person types
    verificationUri: reply.verification_uri ?? "https://github.com/login/device",
    expiresInMs: (reply.expires_in ?? 900) * 1000,
    intervalMs: (reply.interval ?? 5) * 1000,
  };
}

/**
 * Step 2: ask for the token until the person approves, denies, or it expires.
 *
 * GitHub's rules, followed exactly: poll no faster than `interval`, back off when it says
 * `slow_down`, and stop on `expired_token` or `access_denied`.
 */
export async function waitForToken({
  clientId = requireClientId(),
  deviceCode,
  intervalMs = 5_000,
  timeoutMs = CODE_TTL_MS,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  now = () => Date.now(),
} = {}) {
  const deadline = now() + Math.min(timeoutMs, CODE_TTL_MS);
  let wait = intervalMs;

  /** Network hiccups tolerated in a row before giving up. GitHub already said yes. */
  const MAX_TRANSIENT_FAILURES = 5;
  let transientFailures = 0;

  while (now() < deadline) {
    let reply;
    try {
      reply = await postForm(TOKEN_URL, {
        client_id: clientId,
        device_code: deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      });
    } catch (error) {
      // Measured in practice: a momentary DNS failure (`EAI_AGAIN`) killed a login the
      // person had already approved, forcing them to start over. That is not a real
      // refusal from GitHub, so it is retried; a non-network error still stops here.
      if (!error?.transient) throw error;
      transientFailures += 1;
      if (transientFailures > MAX_TRANSIENT_FAILURES) {
        throw new OAuthError(
          "no se pudo hablar con github tras varios intentos; revisa tu conexion y vuelve a empezar",
        );
      }
      await sleep(wait);
      continue;
    }
    transientFailures = 0;

    if (reply.access_token) {
      return { token: reply.access_token, scopes: String(reply.scope ?? "").split(",").map((s) => s.trim()).filter(Boolean) };
    }
    switch (reply.error) {
      case "authorization_pending":
        break; // keep waiting, at the current pace
      case "slow_down":
        wait += 5_000; // GitHub asks for more room; give it
        break;
      case "expired_token":
        throw new OAuthError("el codigo caduco; vuelve a empezar el inicio de sesion");
      case "access_denied":
        throw new OAuthError("cancelaste la autorizacion en github");
      default:
        throw new OAuthError(`github respondio: ${reply.error_description ?? reply.error ?? "sin motivo"}`);
    }
    await sleep(wait);
  }
  throw new OAuthError("se acabo el tiempo esperando la autorizacion");
}

/** What the person reads while waiting: the code and where to put it. */
export function instructions(pending) {
  return {
    userCode: pending.userCode,
    verificationUri: pending.verificationUri,
    expiresInMs: pending.expiresInMs,
    text:
      `Abre ${pending.verificationUri} y escribe el codigo ${pending.userCode}. ` +
      "Autoriza a MovilClaw para que pueda leer y escribir en tus repositorios.",
  };
}

/** The client_id is safe to show: it travels in a URL. Kept in one place so it is obvious. */
export function describeConfiguration(env = process.env) {
  const id = configuredClientId(env);
  return {
    configured: Boolean(id),
    clientId: id, // never a secret; present so the UI can confirm whose app it is
    registerUrl: "https://github.com/settings/applications/new",
    scopes: [...DEFAULT_SCOPES],
    howTo: [
      "Abre https://github.com/settings/applications/new",
      "Application name: MovilClaw",
      "Homepage URL: http://127.0.0.1:8788",
      'Marca "Enable Device Flow"',
      "Register application, y copia el Client ID (no el secret: no hace falta)",
      "Arranca con MOVILCLAW_GITHUB_CLIENT_ID=<tu_client_id>",
    ],
  };
}

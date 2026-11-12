/**
 * Inicio de sesión con Google para la compu: OAuth de "app de escritorio" con PKCE y un
 * servidor de loopback temporal (127.0.0.1) que recibe el código de regreso.
 *
 * Igual que con GitHub (Bridge/sandbox/server/oauth.mjs):
 *  - El `client_id` tiene que ser TUYO. No traemos uno de otra app: la pantalla de permisos
 *    de Google mostraría el nombre de otro proyecto y la persona autorizaría algo distinto
 *    de lo que cree. Sin client_id, el error explica cómo crear uno (es gratis).
 *  - El token vive solo en memoria. No se escribe a disco; al reiniciar, se vuelve a entrar.
 *  - Se piden solo los permisos de las herramientas que se van a usar (ver google-tools.mjs).
 */
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";

const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo";
const LOGIN_TTL_MS = 5 * 60_000;
/** Renovar un minuto antes de que venza, para no mandar un token que muere en el camino. */
const EXPIRY_MARGIN_MS = 60_000;

export class GoogleOAuthError extends Error {}

export function configuredClient(env = process.env) {
  const clientId = (env.ISY_GOOGLE_CLIENT_ID ?? "").trim();
  const clientSecret = (env.ISY_GOOGLE_CLIENT_SECRET ?? "").trim();
  return clientId ? { clientId, clientSecret: clientSecret || undefined } : null;
}

export function requireClient(env = process.env) {
  const client = configuredClient(env);
  if (!client) {
    throw new GoogleOAuthError(
      "falta ISY_GOOGLE_CLIENT_ID. Crea un cliente OAuth de tipo \"App de escritorio\" en " +
        "https://console.cloud.google.com/apis/credentials (es gratis), habilita las APIs que vayas a usar " +
        "y arranca con ISY_GOOGLE_CLIENT_ID=<tu_id> (y ISY_GOOGLE_CLIENT_SECRET si Google te dio uno). " +
        "No usamos el client_id de otra app: Google mostraría su nombre en la pantalla de permisos.",
    );
  }
  return client;
}

/** Par PKCE (RFC 7636): el verificador se queda aquí; solo el hash viaja en la URL. */
export function pkcePair(random = randomBytes) {
  const verifier = random(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export function buildAuthUrl({ clientId, redirectUri, scopes, state, challenge }) {
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: scopes.join(" "),
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
    access_type: "offline",
    // Sin "consent", Google no devuelve refresh_token en la segunda vez que alguien entra.
    prompt: "consent",
    include_granted_scopes: "false",
  });
  return `${AUTH_URL}?${params}`;
}

async function postForm(fetchImpl, url, fields) {
  const response = await fetchImpl(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new GoogleOAuthError(`Google rechazó la solicitud: ${data.error_description ?? data.error ?? response.status}.`);
  }
  return data;
}

/** Servidor de un solo uso en loopback que espera el redirect de Google. */
function listenForCode({ expectedState, timeoutMs }) {
  let resolveCode;
  let rejectCode;
  const codePromise = new Promise((resolve, reject) => {
    resolveCode = resolve;
    rejectCode = reject;
  });
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname !== "/callback") {
      res.writeHead(404).end();
      return;
    }
    const reply = (status, text) => {
      res.writeHead(status, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      res.end(`<!doctype html><meta charset="utf-8"><title>iSyCode</title><body style="font:16px system-ui;padding:2rem">${text}</body>`);
    };
    if (url.searchParams.get("state") !== expectedState) {
      reply(400, "Esta ventana no corresponde al inicio de sesión que abriste. Vuelve a intentarlo desde iSyCode.");
      return;
    }
    const error = url.searchParams.get("error");
    const code = url.searchParams.get("code");
    if (error || !code) {
      reply(400, "No se concedió el acceso. Puedes cerrar esta ventana.");
      rejectCode(new GoogleOAuthError(`Google no concedió el acceso (${error ?? "sin código"}).`));
    } else {
      reply(200, "Listo, ya puedes volver a iSyCode. Puedes cerrar esta ventana.");
      resolveCode(code);
    }
  });
  const timer = setTimeout(() => rejectCode(new GoogleOAuthError("El inicio de sesión tardó demasiado; inténtalo de nuevo.")), timeoutMs);
  timer.unref?.();
  const close = () => {
    clearTimeout(timer);
    server.close();
    server.closeAllConnections?.();
  };
  codePromise.then(close, close);
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve({ port: server.address().port, codePromise, close }));
  });
}

/**
 * Sesión de Google en memoria. Una sola persona (la dueña de la compu) por proceso.
 * `openUrl` es opcional: si se pasa, se llama con la URL de permisos (p. ej. para abrir el navegador).
 */
export function createGoogleSession({ client, fetchImpl = fetch, now = () => Date.now(), loginTimeoutMs = LOGIN_TTL_MS } = {}) {
  let tokens = null; // { accessToken, refreshToken, expiresAt, scopes }
  let profile = null;
  let pending = null;

  async function refresh() {
    if (!tokens?.refreshToken) throw new GoogleOAuthError("La sesión de Google venció; vuelve a iniciar sesión.");
    const data = await postForm(fetchImpl, TOKEN_URL, {
      client_id: client.clientId,
      ...(client.clientSecret ? { client_secret: client.clientSecret } : {}),
      refresh_token: tokens.refreshToken,
      grant_type: "refresh_token",
    }).catch((error) => {
      tokens = null;
      profile = null;
      throw error;
    });
    tokens = { ...tokens, accessToken: data.access_token, expiresAt: now() + data.expires_in * 1000 };
  }

  return {
    /**
     * Prepara el inicio de sesión: abre el servidor de loopback y devuelve la URL que la persona
     * debe visitar, más una promesa que se cumple cuando Google regresa y se canjea el código.
     */
    async beginLogin({ scopes }) {
      if (!client) throw new GoogleOAuthError("Falta configurar el cliente de Google.");
      pending?.cancel();
      const state = randomBytes(16).toString("base64url");
      const { verifier, challenge } = pkcePair();
      const listener = await listenForCode({ expectedState: state, timeoutMs: loginTimeoutMs });
      const redirectUri = `http://127.0.0.1:${listener.port}/callback`;
      const authUrl = buildAuthUrl({ clientId: client.clientId, redirectUri, scopes, state, challenge });
      const done = listener.codePromise.then(async (code) => {
        const data = await postForm(fetchImpl, TOKEN_URL, {
          client_id: client.clientId,
          ...(client.clientSecret ? { client_secret: client.clientSecret } : {}),
          code,
          code_verifier: verifier,
          grant_type: "authorization_code",
          redirect_uri: redirectUri,
        });
        tokens = {
          accessToken: data.access_token,
          refreshToken: data.refresh_token,
          expiresAt: now() + data.expires_in * 1000,
          scopes: String(data.scope ?? "").split(" ").filter(Boolean),
        };
        const info = await fetchImpl(USERINFO_URL, { headers: { Authorization: `Bearer ${tokens.accessToken}` } })
          .then((r) => (r.ok ? r.json() : null))
          .catch(() => null);
        profile = info ? { email: info.email ?? null, name: info.name ?? null } : null;
        pending = null;
        return this.status();
      });
      done.catch(() => { pending = null; });
      pending = { cancel: listener.close };
      return { authUrl, done };
    },

    /** Token vigente (renovándolo si hace falta) o null si no hay sesión. Nunca se registra en logs. */
    async getAccessToken() {
      if (!tokens) return null;
      if (tokens.expiresAt - now() < EXPIRY_MARGIN_MS) await refresh();
      return tokens.accessToken;
    },

    status() {
      return {
        configured: Boolean(client),
        signedIn: Boolean(tokens),
        email: profile?.email ?? null,
        name: profile?.name ?? null,
        scopes: tokens?.scopes ?? [],
        loginPending: Boolean(pending),
      };
    },

    async logout() {
      pending?.cancel();
      pending = null;
      const token = tokens?.refreshToken ?? tokens?.accessToken;
      tokens = null;
      profile = null;
      if (token) await postForm(fetchImpl, REVOKE_URL, { token }).catch(() => {});
    },
  };
}

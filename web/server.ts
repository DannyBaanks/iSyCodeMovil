import 'node:process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import { GoogleGenAI } from '@google/genai';
import { createGoogleClient } from '../Bridge/workspace/google-api.mjs';
import { configuredClient, createGoogleSession } from '../Bridge/workspace/google-oauth.mjs';
import { createContextStore } from '../Bridge/workspace/context-store.mjs';
import { createApp } from './server/app.ts';

const here = path.dirname(fileURLToPath(import.meta.url));

/** .env mínimo: KEY=valor, sin dependencias. Lo que ya esté en el entorno gana. */
function loadEnv(file: string) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (!match || line.trim().startsWith('#')) continue;
    process.env[match[1]] ??= match[2].replace(/^["']|["']$/g, '');
  }
}
loadEnv(path.join(here, '.env'));

const port = Number(process.env.PORT ?? 3000);
const clientConfig = configuredClient();
const session = createGoogleSession({ client: clientConfig });
const context = createContextStore();
const google = createGoogleClient({ getAccessToken: () => session.getAccessToken(), context });
const apiKey = (process.env.GEMINI_API_KEY ?? '').trim();
const ai = apiKey ? new GoogleGenAI({ apiKey }) : null;

const { app } = createApp({
  session: clientConfig ? session : null,
  google,
  context,
  ai,
  port,
  signedIn: () => Boolean(session.status().signedIn),
});

if (process.env.NODE_ENV === 'production') {
  const dist = path.join(here, 'dist');
  if (!fs.existsSync(dist)) {
    console.error('Falta web/dist. Corre `npm run build` primero, o usa `npm run dev`.');
    process.exit(1);
  }
  app.use(express.static(dist));
  app.get('*', (_req, res) => res.sendFile(path.join(dist, 'index.html')));
} else {
  const { createServer } = await import('vite');
  const vite = await createServer({ root: here, server: { middlewareMode: true, host: '127.0.0.1' }, appType: 'spa' });
  app.use(vite.middlewares);
}

app.listen(port, '127.0.0.1', () => {
  console.log(`iSyCode panel   http://127.0.0.1:${port}`);
  console.log(`Google          ${clientConfig ? 'cliente OAuth configurado' : 'sin ISY_GOOGLE_CLIENT_ID (el panel funciona, sin Google)'}`);
  console.log(`Gemini          ${ai ? 'API key configurada' : 'sin GEMINI_API_KEY (el asistente no responderá)'}`);
});

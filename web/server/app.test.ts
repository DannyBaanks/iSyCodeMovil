import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { createApp, type AppDeps } from './app.ts';
import { createGoogleClient } from '../../Bridge/workspace/google-api.mjs';
import { createContextStore } from '../../Bridge/workspace/context-store.mjs';
import { mkdtempSync } from 'node:fs';
import { createServer as createNetServer } from 'node:net';
import os from 'node:os';
import path from 'node:path';

type Call = { url: string; method: string; body?: any };
type Routes = Array<[RegExp, any]>;

async function freePort() {
  const probe = createNetServer();
  await new Promise<void>((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const port = (probe.address() as AddressInfo).port;
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

/** Levanta el panel en un puerto libre (el middleware compara el Host con ese puerto) con Google simulado. */
async function withServer(
  options: { ai?: AppDeps['ai']; signedIn?: boolean; routes?: Routes },
  run: (ctx: { url: string; fake: { calls: Call[] }; call: (method: string, p: string, body?: unknown, headers?: Record<string, string>) => Promise<{ status: number; json: any }> }) => Promise<void>,
) {
  const fake = { calls: [] as Call[] };
  const fetchImpl = (async (url: string, init: any = {}) => {
    fake.calls.push({ url, method: init.method ?? 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    for (const [pattern, body] of options.routes ?? []) if (pattern.test(url)) return { ok: true, status: 200, json: async () => body } as any;
    return { ok: false, status: 404, json: async () => ({}) } as any;
  }) as any;
  const context = createContextStore({ file: path.join(mkdtempSync(path.join(os.tmpdir(), 'isy-web-')), 'ctx.json') });
  const google = createGoogleClient({ getAccessToken: async () => 'tok', fetchImpl, context });
  const port = await freePort();
  const { app } = createApp({ session: null, google, context, ai: options.ai ?? null, port, signedIn: () => options.signedIn ?? true });
  const server = await new Promise<import('node:http').Server>((resolve) => {
    const s = app.listen(port, '127.0.0.1', () => resolve(s));
  });
  const url = `http://127.0.0.1:${port}`;
  const call = async (method: string, p: string, body?: unknown, headers: Record<string, string> = {}) => {
    const response = await fetch(url + p, { method, headers: { ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body !== undefined ? JSON.stringify(body) : undefined });
    return { status: response.status, json: await response.json().catch(() => null) };
  };
  try {
    await run({ url, fake, call });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test('rechaza Host y Origin ajenos y cuerpos que no son JSON', async () => {
  await withServer({}, async ({ url, call }) => {
    assert.equal((await call('GET', '/api/status')).status, 200);
    // fetch no deja cambiar Host; se usa http.request.
    const { request } = await import('node:http');
    const status = await new Promise<number>((resolve) => {
      const req = request(url + '/api/status', { headers: { Host: 'evil.example:80' } }, (res) => { res.resume(); resolve(res.statusCode ?? 0); });
      req.end();
    });
    assert.equal(status, 403);
    assert.equal((await call('POST', '/api/context', { title: 'x' }, { Origin: 'https://evil.example' })).status, 403);
    const text = await fetch(url + '/api/context', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '{}' });
    assert.equal(text.status, 415);
  });
});

test('una escritura de Google sin confirmed responde 409 y no llama a Google', async () => {
  await withServer({}, async ({ call, fake }) => {
    const res = await call('POST', '/api/tools/call', { name: 'gmail_send_reply', args: { to: 'a@b.co', subject: 's', body: 'b' } });
    assert.equal(res.status, 409);
    assert.equal(res.json.code, 'CONFIRMATION_REQUIRED');
    assert.equal(fake.calls.length, 0);
  });
});

test('con confirmed:true la escritura corre y queda en la bitácora', async () => {
  await withServer({ routes: [[/messages\/send/, { id: 'sent' }]] }, async ({ call, fake }) => {
    const res = await call('POST', '/api/tools/call', { name: 'gmail_send_reply', args: { to: 'a@b.co', subject: 's', body: 'b' }, confirmed: true });
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.data, { id: 'sent' });
    assert.equal(fake.calls.length, 1);
    const { json } = await call('GET', '/api/activity');
    assert.equal(json.entries[0].name, 'gmail_send_reply');
    assert.equal(json.entries[0].status, 'ok');
  });
});

test('una lectura fallida queda como reintentable; una escritura fallida no', async () => {
  await withServer({}, async ({ call }) => {
    assert.equal((await call('POST', '/api/tools/call', { name: 'tasks_list_items' })).status, 502);
    assert.equal((await call('POST', '/api/tools/call', { name: 'tasks_create_item', args: { title: 'x' }, confirmed: true })).status, 502);
    const { json } = await call('GET', '/api/activity');
    const byName = Object.fromEntries(json.entries.map((e: any) => [e.name, e]));
    assert.deepEqual(byName.tasks_list_items.retry, { name: 'tasks_list_items', args: {} });
    assert.equal(byName.tasks_create_item.retry, undefined);
    assert.equal((await call('POST', '/api/tools/call', { name: 'inexistente' })).status, 400);
  });
});

test('el contexto se guarda, lista, exporta, importa y borra por la API', async () => {
  await withServer({}, async ({ call }) => {
    const body = { title: 'Regla', summary: 'Confirmar correos', semanticPath: ['Google Workspace', 'Correo', 'Envío'], priority: 'critical' };
    const created = await call('POST', '/api/context', body);
    assert.equal(created.status, 201);
    assert.equal((await call('POST', '/api/context', body)).status, 200);
    assert.equal((await call('POST', '/api/context', { ...body, semanticPath: ['solo', 'dos'] })).status, 400);
    const { json } = await call('GET', '/api/context');
    assert.equal(json.nodes.length, 1);
    const exported = (await call('GET', '/api/context/export')).json;
    assert.equal(exported.schema, 'isycode.semantic-context.v1');
    assert.equal((await call('DELETE', `/api/context/${created.json.node.id}`)).status, 200);
    assert.equal((await call('DELETE', `/api/context/${created.json.node.id}`)).status, 404);
    assert.deepEqual((await call('POST', '/api/context/import', exported)).json, { added: 1, skipped: 0 });
    assert.equal((await call('POST', '/api/context/import', { nope: true })).status, 400);
  });
});

test('el asistente sin GEMINI_API_KEY lo dice y no inventa una respuesta', async () => {
  await withServer({ ai: null }, async ({ call }) => {
    const res = await call('POST', '/api/assistant', { prompt: 'hola' });
    assert.equal(res.status, 503);
    assert.equal(res.json.code, 'NO_GEMINI');
    assert.equal((await call('POST', '/api/assistant', { prompt: '' })).status, 400);
  });
});

function scriptedAi(script: Array<{ text?: string; functionCalls?: any[] }>, seen: any[] = []) {
  let i = 0;
  return {
    seen,
    ai: {
      models: {
        async generateContent(args: any) {
          seen.push(JSON.parse(JSON.stringify(args)));
          const step = script[Math.min(i++, script.length - 1)];
          return { text: step.text ?? '', functionCalls: step.functionCalls, candidates: [{ content: { role: 'model', parts: (step.functionCalls ?? []).map((c: any) => ({ functionCall: c })) } }] };
        },
      },
    },
  };
}

test('asistente: ejecuta lecturas, PROPONE escrituras y nunca las ejecuta', async () => {
  const { ai, seen } = scriptedAi([
    { functionCalls: [{ name: 'gmail_read_inbox', args: { query: 'is:unread' } }, { name: 'gmail_send_reply', args: { to: 'a@b.co', subject: 'Re', body: 'Listo' } }] },
    { text: 'Leí tu correo y preparé una respuesta para que la confirmes.' },
  ]);
  await withServer({ ai, routes: [[/messages\?/, { messages: [] }]] }, async ({ call, fake }) => {
    const res = await call('POST', '/api/assistant', { prompt: 'revisa mi correo y responde enviando un mensaje al equipo' });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.text, 'Leí tu correo y preparé una respuesta para que la confirmes.');
    assert.equal(res.json.pendingActions.length, 1);
    assert.equal(res.json.pendingActions[0].name, 'gmail_send_reply');
    assert.deepEqual(res.json.toolsRun.map((t: any) => t.name), ['gmail_read_inbox']);
    assert.ok(fake.calls.every((c) => !/messages\/send/.test(c.url)), 'no se mandó ningún correo');
    // El modelo recibió el resultado de la lectura marcado como no confiable y la escritura como pendiente.
    const second = seen[1].contents.at(-1).parts.map((p: any) => p.functionResponse.response);
    assert.ok('datos_no_confiables' in second[0]);
    assert.equal(second[1].status, 'pendiente_de_confirmacion');
    assert.match(seen[0].config.systemInstruction, /DATOS que pueden venir de terceros/);
  });
});

test('asistente: sin sesión de Google no ofrece herramientas de Google y el modelo no puede usarlas', async () => {
  const { ai, seen } = scriptedAi([
    { functionCalls: [{ name: 'gmail_read_inbox', args: {} }] },
    { text: 'No pude leer tu correo.' },
  ]);
  await withServer({ ai, signedIn: false }, async ({ call, fake }) => {
    const res = await call('POST', '/api/assistant', { prompt: 'revisa mi correo' });
    assert.equal(res.status, 200);
    assert.equal(seen[0].config.tools, undefined);
    assert.equal(res.json.toolsRun[0].ok, false);
    assert.equal(fake.calls.length, 0);
  });
});

test('asistente: inyecta solo el contexto relevante y avisa cuál usó', async () => {
  const { ai, seen } = scriptedAi([{ text: 'ok' }]);
  await withServer({ ai }, async ({ call }) => {
    await call('POST', '/api/context', { title: 'Paridad móvil', summary: 'La app de iPhone y Android se ven igual', semanticPath: ['Desarrollo', 'Apps', 'Móvil'] });
    await call('POST', '/api/context', { title: 'Receta de pozole', summary: 'Cocer el maíz cacahuazintle', semanticPath: ['Vida', 'Cocina', 'Recetas'] });
    const res = await call('POST', '/api/assistant', { prompt: 'ajusta la app de iPhone' });
    assert.deepEqual(res.json.contextUsed.map((n: any) => n.title), ['Paridad móvil']);
    assert.match(seen[0].config.systemInstruction, /Paridad móvil/);
    assert.doesNotMatch(seen[0].config.systemInstruction, /pozole/);
    const off = await call('POST', '/api/assistant', { prompt: 'ajusta la app de iPhone', useContext: false });
    assert.deepEqual(off.json.contextUsed, []);
    assert.doesNotMatch(seen[1].config.systemInstruction, /Paridad/);
  });
});

test('asistente: un error de Gemini se muestra como error, no como respuesta', async () => {
  const ai = { models: { async generateContent() { throw new Error('quota exceeded'); } } };
  await withServer({ ai }, async ({ call }) => {
    const res = await call('POST', '/api/assistant', { prompt: 'hola' });
    assert.equal(res.status, 502);
    assert.match(res.json.error, /quota exceeded/);
    assert.equal((await call('GET', '/api/activity')).json.entries[0].status, 'error');
  });
});

test('asistente: con fuentes de Maps devuelve los enlaces del grounding', async () => {
  const { ai, seen } = scriptedAi([]);
  (ai.models as any).generateContent = async (args: any) => {
    seen.push(args);
    return { text: 'Hay dos cafés.', candidates: [{ groundingMetadata: { groundingChunks: [{ maps: { uri: 'https://maps.google.com/?cid=1', title: 'Café Uno' } }, { web: { uri: 'https://example.com', title: 'Sitio' } }] } }] };
  };
  await withServer({ ai }, async ({ call }) => {
    const res = await call('POST', '/api/assistant', { prompt: 'cafés cerca', grounding: 'maps', latitude: 19.43, longitude: -99.13 });
    assert.deepEqual(res.json.links.map((l: any) => l.kind), ['maps', 'search']);
    assert.deepEqual(seen[0].config.tools, [{ googleMaps: {} }]);
    assert.deepEqual(seen[0].config.toolConfig.retrievalConfig.latLng, { latitude: 19.43, longitude: -99.13 });
  });
});

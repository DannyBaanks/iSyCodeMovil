import React, { useMemo, useState } from 'react';
import { api, ApiError, type PanelStatus, type ToolInfo } from '../lib/api';
import { Card, Eyebrow, Notice, inputClass, primaryButton } from './ui';
import type { PendingConfirmation } from './ConfirmModal';

interface Props {
  tools: ToolInfo[];
  status: PanelStatus | undefined;
  developerMode: boolean;
  onConfirm: (pending: PendingConfirmation) => void;
  onActivity: () => void;
}

/** Convierte lo escrito en el formulario a los argumentos reales según el esquema de la herramienta. */
export function buildArgs(tool: ToolInfo, raw: Record<string, string>): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  for (const [key, schema] of Object.entries(tool.inputSchema.properties)) {
    const value = (raw[key] ?? '').trim();
    if (!value) continue;
    if (schema.type === 'integer') args[key] = Number.parseInt(value, 10);
    else if (schema.type === 'array') args[key] = value.split(/\n|,/).map((v) => v.trim()).filter(Boolean);
    else args[key] = value;
  }
  return args;
}

const ToolCard: React.FC<{ tool: ToolInfo; disabled: boolean; developerMode: boolean; onConfirm: Props['onConfirm']; onActivity: () => void }> = ({ tool, disabled, developerMode, onConfirm, onActivity }) => {
  const [raw, setRaw] = useState<Record<string, string>>({});
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const isWrite = tool.mode === 'write';
  const missing = tool.inputSchema.required.filter((key) => !(raw[key] ?? '').trim());

  const run = async (confirmed: boolean) => {
    const args = buildArgs(tool, raw);
    const data = await api.callTool(tool.name, args, confirmed);
    setResult(JSON.stringify(data.data, null, 2));
    setError(null);
    onActivity();
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (isWrite) {
      onConfirm({
        title: `Confirmar: ${tool.service}`,
        description: tool.description,
        details: Object.entries(buildArgs(tool, raw)).map(([label, value]) => ({ label, value: typeof value === 'string' ? value : JSON.stringify(value) })),
        onConfirm: async () => { try { await run(true); } catch (err) { onActivity(); throw err; } },
      });
      return;
    }
    setBusy(true);
    try {
      await run(false);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      onActivity();
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="rounded-xl border border-slate-200 dark:border-slate-800 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium">{tool.name.replace(/_/g, ' ')}</p>
          <p className="mt-0.5 text-xs text-slate-600 dark:text-slate-400">{tool.description}</p>
        </div>
        <span className={`shrink-0 px-2 py-0.5 rounded-md text-[10px] font-mono ${isWrite ? 'bg-amber-100 dark:bg-amber-950/50 text-amber-800 dark:text-amber-300' : 'bg-emerald-100 dark:bg-emerald-950/50 text-emerald-800 dark:text-emerald-300'}`}>
          {isWrite ? 'pide confirmación' : 'lectura'}
        </span>
      </div>
      {Object.entries(tool.inputSchema.properties).map(([key, schema]) => (
        <label key={key} className="block text-xs">
          <span className="text-slate-600 dark:text-slate-400">{schema.description ?? key}{tool.inputSchema.required.includes(key) ? ' *' : ''}</span>
          {schema.enum ? (
            <select value={raw[key] ?? ''} onChange={(e) => setRaw({ ...raw, [key]: e.target.value })} className={`${inputClass} mt-1`}>
              <option value="">(por defecto)</option>
              {schema.enum.map((v) => <option key={v} value={v}>{v}</option>)}
            </select>
          ) : (
            <input value={raw[key] ?? ''} onChange={(e) => setRaw({ ...raw, [key]: e.target.value })} placeholder={schema.type === 'array' ? 'valores separados por coma' : ''} className={`${inputClass} mt-1`} />
          )}
        </label>
      ))}
      {developerMode && <p className="text-[11px] font-mono text-slate-400 break-all">{tool.id}{tool.scopes.length ? ` · ${tool.scopes.map((s) => s.replace('https://www.googleapis.com/auth/', '')).join(', ')}` : ''}</p>}
      <button type="submit" disabled={disabled || busy || missing.length > 0} className={primaryButton}>{busy ? 'Ejecutando…' : isWrite ? 'Revisar y enviar' : 'Ejecutar'}</button>
      {error && <Notice tone="error">{error}</Notice>}
      {result && <pre className="max-h-64 overflow-auto rounded-lg bg-slate-50 dark:bg-slate-950 border border-slate-200 dark:border-slate-800 p-3 text-[11px] font-mono whitespace-pre-wrap">{result}</pre>}
    </form>
  );
};

export const WorkspacePanel: React.FC<Props> = ({ tools, status, developerMode, onConfirm, onActivity }) => {
  const signedIn = status?.google.signedIn ?? false;
  const groups = useMemo(() => {
    const map = new Map<string, ToolInfo[]>();
    for (const tool of tools) map.set(tool.service, [...(map.get(tool.service) ?? []), tool]);
    return [...map.entries()];
  }, [tools]);
  const readOnlySession = signedIn && !(status?.google.scopes ?? []).some((s) => /gmail\.send|calendar\.events$|\/tasks$|\/spreadsheets$/.test(s));

  return (
    <div className="space-y-6">
      {!signedIn && <Notice>Inicia sesión con Google (arriba a la derecha) para usar estas herramientas. Las de «Contexto semántico» funcionan sin sesión.</Notice>}
      {readOnlySession && <Notice tone="warn">Tu sesión es de <strong>solo lectura</strong>. Para enviar correos, agendar o escribir en hojas, sal y vuelve a entrar activando «Permitir acciones de escritura» en Opciones.</Notice>}
      {groups.map(([service, list]) => (
        <Card key={service} className="p-5">
          <Eyebrow>{service}</Eyebrow>
          <div className="mt-3 grid grid-cols-1 xl:grid-cols-2 gap-4">
            {list.map((tool) => (
              <ToolCard key={tool.name} tool={tool} disabled={!tool.local && !signedIn} developerMode={developerMode} onConfirm={onConfirm} onActivity={onActivity} />
            ))}
          </div>
        </Card>
      ))}
    </div>
  );
};

import React, { useState } from 'react';
import { Copy, RotateCcw, Trash2 } from 'lucide-react';
import { api, type ActivityEntry } from '../lib/api';
import { Card, Eyebrow, ghostButton } from './ui';

interface Props {
  entries: ActivityEntry[];
  onRefresh: () => void;
}

const STATUS_STYLE = {
  ok: 'text-emerald-600 dark:text-emerald-400',
  error: 'text-red-600 dark:text-red-400',
  pending: 'text-amber-600 dark:text-amber-400',
} as const;

/** Bitácora real: cada línea es algo que de verdad pasó en este panel. */
export const ActivityPanel: React.FC<Props> = ({ entries, onRefresh }) => {
  const [filter, setFilter] = useState<'all' | ActivityEntry['status']>('all');
  const [retrying, setRetrying] = useState<string | null>(null);
  const shown = entries.filter((e) => filter === 'all' || e.status === filter);

  const retry = async (entry: ActivityEntry) => {
    if (!entry.retry) return;
    setRetrying(entry.id);
    try {
      await api.callTool(entry.retry.name, entry.retry.args, false);
    } catch { /* el fallo queda registrado en la bitácora */ }
    setRetrying(null);
    onRefresh();
  };

  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <Eyebrow>Bitácora</Eyebrow>
          <p className="mt-1 text-xs text-slate-500">Vive en la memoria del panel: se borra al reiniciarlo. No guarda el contenido de tus correos ni documentos.</p>
        </div>
        <div className="flex items-center gap-2">
          <select value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)} className="rounded-lg border border-slate-200 dark:border-slate-700 bg-transparent px-2 py-1.5 text-xs" aria-label="Filtrar">
            <option value="all">Todo</option><option value="ok">Correctos</option><option value="error">Con error</option><option value="pending">Pendientes</option>
          </select>
          <button type="button" onClick={() => api.clearActivity().then(onRefresh)} className={ghostButton}><Trash2 className="w-3.5 h-3.5" /> Limpiar</button>
        </div>
      </div>
      {shown.length === 0 ? (
        <p className="mt-4 text-sm text-slate-500">Nada por aquí todavía.</p>
      ) : (
        <ul className="mt-4 divide-y divide-slate-200 dark:divide-slate-800">
          {shown.map((entry) => (
            <li key={entry.id} className="py-3 flex items-start gap-3">
              <span className={`mt-0.5 text-[11px] font-mono uppercase ${STATUS_STYLE[entry.status]}`}>{entry.status}</span>
              <div className="min-w-0 flex-1">
                <p className="text-sm"><span className="font-mono text-xs text-slate-500">{entry.kind} · {entry.name}</span></p>
                <p className="text-sm break-words">{entry.message}</p>
                <p className="mt-0.5 text-[11px] font-mono text-slate-400">{new Date(entry.at).toLocaleTimeString()}</p>
              </div>
              <div className="flex gap-1.5 shrink-0">
                {entry.retry && <button type="button" onClick={() => void retry(entry)} disabled={retrying === entry.id} className={ghostButton}><RotateCcw className="w-3.5 h-3.5" /> Reintentar</button>}
                <button type="button" onClick={() => navigator.clipboard?.writeText(JSON.stringify(entry, null, 2))} className={ghostButton} aria-label="Copiar entrada"><Copy className="w-3.5 h-3.5" /></button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
};

import React, { useEffect, useState } from 'react';
import { ShieldCheck, X } from 'lucide-react';

export interface PendingConfirmation {
  title: string;
  description: string;
  details: Array<{ label: string; value: string }>;
  confirmLabel?: string;
  onConfirm: () => Promise<void>;
}

interface Props {
  pending: PendingConfirmation | null;
  onClose: () => void;
}

/** Toda acción que cambia algo pasa por aquí: se muestra exactamente qué se va a hacer. */
export const ConfirmModal: React.FC<Props> = ({ pending, onClose }) => {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setError(null);
    if (!pending) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && !submitting && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [pending, submitting, onClose]);

  if (!pending) return null;

  const confirm = async () => {
    setSubmitting(true);
    setError(null);
    try {
      await pending.onConfirm();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div role="dialog" aria-modal="true" aria-labelledby="confirm-title" className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/60 backdrop-blur-sm">
      <div className="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-xl">
        <div className="flex items-start justify-between gap-4 p-5 border-b border-slate-200 dark:border-slate-800">
          <div className="flex items-start gap-3">
            <ShieldCheck className="w-5 h-5 mt-0.5 text-blue-600 dark:text-blue-400 shrink-0" />
            <div>
              <h2 id="confirm-title" className="text-base font-semibold">{pending.title}</h2>
              <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">{pending.description}</p>
            </div>
          </div>
          <button type="button" onClick={onClose} disabled={submitting} aria-label="Cerrar" className="p-1 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800">
            <X className="w-4 h-4" />
          </button>
        </div>
        <dl className="p-5 space-y-2 max-h-72 overflow-y-auto">
          {pending.details.map((d) => (
            <div key={d.label} className="text-sm">
              <dt className="text-[11px] font-mono uppercase tracking-wide text-slate-500 dark:text-slate-400">{d.label}</dt>
              <dd className="mt-0.5 whitespace-pre-wrap break-words rounded-lg bg-slate-50 dark:bg-slate-950 border border-slate-200 dark:border-slate-800 px-3 py-2 font-mono text-xs">{d.value || '—'}</dd>
            </div>
          ))}
        </dl>
        {error && <p role="alert" className="mx-5 mb-3 rounded-lg bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-900 px-3 py-2 text-sm text-red-700 dark:text-red-300">{error}</p>}
        <div className="flex justify-end gap-2 p-5 pt-0">
          <button type="button" onClick={onClose} disabled={submitting} className="px-4 py-2 text-sm rounded-xl border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800">
            Cancelar
          </button>
          <button type="button" onClick={confirm} disabled={submitting} className="px-4 py-2 text-sm font-medium rounded-xl bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-60">
            {submitting ? 'Ejecutando…' : pending.confirmLabel ?? 'Confirmar y ejecutar'}
          </button>
        </div>
      </div>
    </div>
  );
};

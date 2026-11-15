import React, { useEffect, useRef, useState } from 'react';
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
  const [detailsOpen, setDetailsOpen] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const submittingRef = useRef(false);

  useEffect(() => {
    setError(null);
    setDetailsOpen(false);
    if (!pending) return;
    returnFocusRef.current = document.activeElement as HTMLElement | null;
    requestAnimationFrame(() => closeRef.current?.focus());
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !submittingRef.current) { onClose(); return; }
      if (e.key !== 'Tab' || !dialogRef.current) return;
      const focusable = Array.from(dialogRef.current.querySelectorAll<HTMLElement>('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'));
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      requestAnimationFrame(() => returnFocusRef.current?.focus());
    };
  }, [pending, onClose]);

  if (!pending) return null;

  const confirm = async () => {
    if (submitting) return;
    setSubmitting(true);
    submittingRef.current = true;
    setError(null);
    try {
      await pending.onConfirm();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
      submittingRef.current = false;
    }
  };

  return (
    <div role="dialog" aria-modal="true" aria-labelledby="confirm-title" aria-describedby="confirm-description" className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/60 p-4 backdrop-blur-sm">
      <div ref={dialogRef} className="w-full max-w-lg rounded-2xl border border-[var(--border)] bg-[var(--surface)] shadow-xl">
        <div className="flex items-start justify-between gap-4 border-b border-[var(--border)] p-5">
          <div className="flex items-start gap-3">
            <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-[var(--accent)]" aria-hidden="true" />
            <div>
              <h2 id="confirm-title" className="text-base font-semibold">{pending.title}</h2>
              <p id="confirm-description" className="mt-1 text-sm text-slate-600 dark:text-slate-400">{pending.description}</p>
            </div>
          </div>
          <button ref={closeRef} type="button" onClick={onClose} disabled={submitting} aria-label="Cerrar confirmación" className="rounded-lg p-1 hover:bg-slate-100 dark:hover:bg-slate-800">
            <X className="h-4 w-4" aria-hidden="true" />
          </button>
        </div>
        <div className="p-5">
          <p className="text-sm font-medium">Esto es lo que se autorizará</p>
          <p className="mt-1 text-xs text-slate-600 dark:text-slate-400">Revisa el efecto y confirma solo si coincide con lo que pediste.</p>
          <button type="button" onClick={() => setDetailsOpen((open) => !open)} aria-expanded={detailsOpen} className="mt-3 text-xs font-medium text-[var(--information)] underline underline-offset-4">{detailsOpen ? 'Ocultar detalles técnicos' : 'Ver detalles técnicos'}</button>
          {detailsOpen && <dl className="mt-3 max-h-72 space-y-2 overflow-y-auto">
            {pending.details.map((d) => (
              <div key={d.label} className="text-sm">
                <dt className="text-[11px] font-mono uppercase tracking-wide text-slate-500 dark:text-slate-400">{d.label}</dt>
                <dd className="mt-0.5 whitespace-pre-wrap break-words rounded-lg border border-[var(--border)] bg-[var(--background)] px-3 py-2 font-mono text-xs">{d.value || '—'}</dd>
              </div>
            ))}
          </dl>}
        </div>
        {error && <p role="alert" className="mx-5 mb-3 rounded-lg border border-[var(--danger)]/30 bg-[var(--danger)]/10 px-3 py-2 text-sm text-[var(--danger)]">No se pudo ejecutar: {error}</p>}
        <div className="flex justify-end gap-2 p-5 pt-0">
          <button type="button" onClick={onClose} disabled={submitting} className="rounded-xl border border-[var(--border)] px-4 py-2 text-sm hover:bg-[var(--surface-elevated)]">Cancelar</button>
          <button type="button" onClick={confirm} disabled={submitting} className="rounded-xl bg-[var(--accent-strong)] px-4 py-2 text-sm font-medium text-[var(--accent-contrast)] hover:brightness-110 disabled:opacity-60">
            {submitting ? 'Ejecutando…' : pending.confirmLabel ?? 'Confirmar y ejecutar'}
          </button>
        </div>
      </div>
    </div>
  );
};

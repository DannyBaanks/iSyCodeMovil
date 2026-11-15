import React from 'react';
import { Activity, ArrowRight, CheckCircle2, Eye, LockKeyhole, Sparkles } from 'lucide-react';
import type { ActivityEntry, PanelStatus } from '../lib/api';
import { Card } from './ui';
import { ConnectionStatusBar } from './ConnectionStatusBar';

interface Props {
  status: PanelStatus | undefined;
  loadError: string | null;
  activity: ActivityEntry[];
  onOpenOptions: () => void;
  onOpenActivity: () => void;
}

const capabilities = [
  { title: 'Preguntar y resumir', detail: 'Consulta información y recibe respuestas con fuentes cuando estén disponibles.', icon: Sparkles },
  { title: 'Leer tu Google', detail: 'Revisa correo, agenda, Drive y tareas sin cambiar nada automáticamente.', icon: Eye },
  { title: 'Actuar contigo', detail: 'Enviar, crear o guardar requiere revisar la propuesta y confirmarla.', icon: LockKeyhole },
];

export const SummaryPanel: React.FC<Props> = ({ status, loadError, activity, onOpenOptions, onOpenActivity }) => (
  <div className="space-y-6">
    <ConnectionStatusBar status={status} loadError={loadError} onOpenOptions={onOpenOptions} />
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
      <Card className="lg:col-span-7 p-5">
        <p className="eyebrow">Qué puedes hacer</p>
        <h2 className="mt-1 text-base font-semibold">Un asistente local que trabaja contigo</h2>
        <p className="mt-2 max-w-2xl text-sm leading-relaxed text-slate-600 dark:text-slate-400">Pídele que lea, busque o prepare algo. La memoria vive en tu computadora y las operaciones que cambian datos pasan por una confirmación clara.</p>
        <div className="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-3">
          {capabilities.map(({ title, detail, icon: Icon }) => (
            <div key={title} className="summary-capability">
              <Icon className="h-4 w-4 text-[var(--accent)]" aria-hidden="true" />
              <h3 className="mt-2 text-sm font-semibold">{title}</h3>
              <p className="mt-1 text-xs leading-relaxed text-slate-600 dark:text-slate-400">{detail}</p>
            </div>
          ))}
        </div>
        <div className="mt-5 flex flex-wrap items-center gap-2 border-t border-[var(--border)] pt-4 text-xs text-slate-500 dark:text-slate-400">
          <CheckCircle2 className="h-4 w-4 text-[var(--success)]" aria-hidden="true" />
          <span>La regla de seguridad está activa: proponer → confirmar → ejecutar.</span>
        </div>
      </Card>
      <Card className="lg:col-span-5 p-5">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="eyebrow">Actividad reciente</p>
            <h2 className="mt-1 text-base font-semibold">Lo último que ocurrió</h2>
          </div>
          <button type="button" onClick={onOpenActivity} className="secondary-button" aria-label="Ver toda la actividad"><ArrowRight className="h-3.5 w-3.5" /> Ver todo</button>
        </div>
        {activity.length === 0 ? (
          <div className="mt-5 rounded-xl border border-dashed border-[var(--border)] p-4 text-sm text-slate-500 dark:text-slate-400"><Activity className="mb-2 h-4 w-4" aria-hidden="true" />Todavía no hay actividad en este panel.</div>
        ) : (
          <ul className="mt-4 space-y-3">
            {activity.slice(0, 3).map((entry) => (
              <li key={entry.id} className="border-b border-[var(--border)] pb-3 last:border-0 last:pb-0">
                <div className="flex items-center justify-between gap-2"><span className={`status-label status-${entry.status}`}>{entry.status === 'ok' ? 'Correcto' : entry.status === 'error' ? 'Error' : 'Pendiente'}</span><time className="text-[11px] text-slate-400" dateTime={entry.at}>{new Date(entry.at).toLocaleTimeString()}</time></div>
                <p className="mt-1 text-sm font-medium">{entry.message}</p>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  </div>
);

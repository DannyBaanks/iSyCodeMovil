import React from 'react';
import { CheckCircle2, CircleHelp, CloudOff, LoaderCircle, LockKeyhole, Settings2, ShieldAlert, WifiOff } from 'lucide-react';
import type { PanelStatus } from '../lib/api';
import { Card } from './ui';

type Tone = 'success' | 'warning' | 'neutral' | 'error';

interface StatusItem {
  label: string;
  value: string;
  detail: string;
  tone: Tone;
  icon: React.ComponentType<{ className?: string }>;
}

interface Props {
  status: PanelStatus | undefined;
  loadError: string | null;
  onOpenOptions: () => void;
}

const toneClass: Record<Tone, string> = {
  success: 'status-success',
  warning: 'status-warning',
  neutral: 'status-neutral',
  error: 'status-error',
};

function googleState(status: PanelStatus | undefined): StatusItem {
  if (!status) return { label: 'Google', value: 'Comprobando…', detail: 'Consultando la sesión local', tone: 'neutral', icon: LoaderCircle };
  if (!status.google.clientConfigured) return { label: 'Google', value: 'No configurado', detail: 'Falta el cliente OAuth local', tone: 'warning', icon: Settings2 };
  if (!status.google.signedIn) return { label: 'Google', value: 'Sin conectar', detail: 'Puedes iniciar una sesión de solo lectura', tone: 'warning', icon: CloudOff };
  const canWrite = status.google.scopes.some((scope) => /gmail\.send|calendar\.events$|\/tasks$|\/spreadsheets$/.test(scope));
  return { label: 'Google', value: canWrite ? 'Lectura y escritura' : 'Solo lectura', detail: status.google.email ?? 'Sesión activa', tone: 'success', icon: canWrite ? CheckCircle2 : LockKeyhole };
}

function assistantState(status: PanelStatus | undefined): StatusItem {
  if (!status) return { label: 'Asistente', value: 'Comprobando…', detail: 'Consultando la configuración local', tone: 'neutral', icon: LoaderCircle };
  if (!status.gemini.configured) return { label: 'Asistente', value: 'Requiere configuración', detail: 'Falta GEMINI_API_KEY', tone: 'warning', icon: Settings2 };
  return { label: 'Asistente', value: 'Disponible', detail: status.gemini.model, tone: 'success', icon: CheckCircle2 };
}

function memoryState(status: PanelStatus | undefined): StatusItem {
  if (!status) return { label: 'Memoria', value: 'Comprobando…', detail: 'Consultando el archivo local', tone: 'neutral', icon: LoaderCircle };
  return { label: 'Memoria', value: 'Local', detail: `${status.context.nodes} recuerdo(s) en tu computadora`, tone: 'success', icon: CheckCircle2 };
}

function hostState(status: PanelStatus | undefined): StatusItem {
  if (!status) return { label: 'Equipo local', value: 'Estado no verificado', detail: 'Aún no hay respuesta del panel', tone: 'neutral', icon: CircleHelp };
  return { label: 'Equipo local', value: 'Estado no verificado', detail: 'La web no recibe una señal de host conectado', tone: 'neutral', icon: WifiOff };
}

export const ConnectionStatusBar: React.FC<Props> = ({ status, loadError, onOpenOptions }) => {
  const items = [googleState(status), assistantState(status), memoryState(status), hostState(status)];
  return (
    <Card className="status-surface p-4" aria-label="Estado de conexiones y capacidades">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="eyebrow">Estado real</p>
          <h2 className="mt-1 text-base font-semibold">Lo que está disponible ahora</h2>
        </div>
        {(loadError || items.some((item) => item.tone === 'warning')) && (
          <button type="button" onClick={onOpenOptions} className="secondary-button">
            <Settings2 className="h-3.5 w-3.5" /> Revisar configuración
          </button>
        )}
      </div>
      {loadError && (
        <p role="alert" className="mt-3 status-message status-error"><ShieldAlert className="h-4 w-4 shrink-0" /> No pude actualizar todo el estado: {loadError}</p>
      )}
      <div className="mt-4 grid grid-cols-1 gap-2 sm:grid-cols-2 xl:grid-cols-4">
        {items.map((item) => {
          const Icon = item.icon;
          return (
            <div key={item.label} className={`status-item ${toneClass[item.tone]}`}>
              <Icon className={`h-4 w-4 shrink-0 ${item.tone === 'neutral' && item.value === 'Comprobando…' ? 'animate-spin' : ''}`} aria-hidden="true" />
              <div className="min-w-0">
                <p className="text-xs font-medium">{item.label}</p>
                <p className="mt-0.5 text-sm font-semibold">{item.value}</p>
                <p className="mt-0.5 truncate text-[11px] opacity-80" title={item.detail}>{item.detail}</p>
              </div>
            </div>
          );
        })}
      </div>
      <p className="mt-3 text-xs text-slate-500 dark:text-slate-400">Los colores acompañan al texto; una acción de escritura siempre te pide confirmación antes de ejecutarse.</p>
    </Card>
  );
};

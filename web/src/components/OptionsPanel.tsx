import React from 'react';
import type { PanelStatus } from '../lib/api';
import type { ThemeMode } from '../lib/theme';
import { Card, Eyebrow } from './ui';

interface Props {
  status: PanelStatus | undefined;
  themeMode: ThemeMode;
  effectiveTheme: 'dark' | 'light';
  onThemeModeChange: (mode: ThemeMode) => void;
  developerMode: boolean;
  onDeveloperModeChange: (value: boolean) => void;
  allowWrite: boolean;
  onAllowWriteChange: (value: boolean) => void;
}

const Switch: React.FC<{ checked: boolean; onChange: (v: boolean) => void; label: string; hint: string }> = ({ checked, onChange, label, hint }) => (
  <label className="flex items-start justify-between gap-4 cursor-pointer">
    <span>
      <span className="block text-sm font-medium">{label}</span>
      <span className="block text-xs text-slate-500 dark:text-slate-400">{hint}</span>
    </span>
    <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} className="mt-1 h-5 w-9 accent-blue-600" />
  </label>
);

const Row: React.FC<{ label: string; ok: boolean; detail: string }> = ({ label, ok, detail }) => (
  <li className="flex items-center justify-between gap-3 py-2 text-sm">
    <span>{label}</span>
    <span className={`text-xs font-mono ${ok ? 'text-emerald-600 dark:text-emerald-400' : 'text-amber-600 dark:text-amber-400'}`}>{detail}</span>
  </li>
);

export const OptionsPanel: React.FC<Props> = ({ status, themeMode, effectiveTheme, onThemeModeChange, developerMode, onDeveloperModeChange, allowWrite, onAllowWriteChange }) => (
  <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
    <Card className="p-5 space-y-5">
      <div>
        <Eyebrow>Apariencia</Eyebrow>
        <div role="group" aria-label="Tema" className="mt-3 inline-flex rounded-xl border border-slate-200 dark:border-slate-700 p-1 gap-1">
          {(['auto', 'dark', 'light'] as const).map((mode) => (
            <button key={mode} type="button" onClick={() => onThemeModeChange(mode)} aria-pressed={themeMode === mode} className={`px-3.5 py-1.5 text-xs font-medium rounded-lg ${themeMode === mode ? 'bg-blue-600 text-white' : 'hover:bg-slate-100 dark:hover:bg-slate-800'}`}>
              {mode === 'auto' ? 'Auto' : mode === 'dark' ? 'Oscuro' : 'Claro'}
            </button>
          ))}
        </div>
        <p className="mt-2 text-xs text-slate-500">Ahora se ve en modo {effectiveTheme === 'dark' ? 'oscuro' : 'claro'}{themeMode === 'auto' ? ' (sigue a tu sistema).' : '.'}</p>
      </div>
      <Switch checked={developerMode} onChange={onDeveloperModeChange} label="Modo desarrollador" hint="Muestra la bitácora, los permisos de cada herramienta y los pasos del recorrido de memoria." />
      <Switch checked={allowWrite} onChange={onAllowWriteChange} label="Permitir acciones de escritura de Google" hint="Al iniciar sesión se piden también los permisos para enviar correos, agendar y escribir en hojas. Cada acción sigue pidiendo tu confirmación. Por defecto la sesión es de solo lectura." />
    </Card>

    <Card className="p-5">
      <Eyebrow>Estado</Eyebrow>
      <ul className="mt-2 divide-y divide-slate-200 dark:divide-slate-800">
        <Row label="Gemini (asistente)" ok={Boolean(status?.gemini.configured)} detail={status?.gemini.configured ? status.gemini.model : 'falta GEMINI_API_KEY'} />
        <Row label="Cliente OAuth de Google" ok={Boolean(status?.google.clientConfigured)} detail={status?.google.clientConfigured ? 'configurado' : 'falta ISY_GOOGLE_CLIENT_ID'} />
        <Row label="Sesión de Google" ok={Boolean(status?.google.signedIn)} detail={status?.google.signedIn ? status.google.email ?? 'activa' : 'sin sesión'} />
        <Row label="Memoria" ok detail={`${status?.context.nodes ?? 0} recuerdo(s)`} />
      </ul>
      <p className="mt-4 text-xs text-slate-500">Cómo configurar lo que falta: <code className="font-mono">web/README.md</code>. Tu token de Google vive solo en la memoria de este panel; no se escribe a disco.</p>
    </Card>
  </div>
);

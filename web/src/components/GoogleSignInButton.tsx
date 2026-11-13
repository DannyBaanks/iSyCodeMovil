import React from 'react';
import type { PanelStatus } from '../lib/api';

interface Props {
  google: PanelStatus['google'] | undefined;
  busy: boolean;
  onLogin: () => void;
  onLogout: () => void;
}

const GoogleG = () => (
  <svg viewBox="0 0 48 48" className="w-4 h-4" aria-hidden="true">
    <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.9 6.1C12.4 13.6 17.7 9.5 24 9.5z" />
    <path fill="#4285F4" d="M46.1 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.4c-.5 2.9-2.2 5.3-4.6 6.9l7.4 5.8c4.3-4 6.9-9.9 6.9-17.2z" />
    <path fill="#FBBC05" d="M10.5 28.7a14.5 14.5 0 0 1 0-9.4l-7.9-6.1a24 24 0 0 0 0 21.6l7.9-6.1z" />
    <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.4-5.8c-2.1 1.4-4.9 2.3-8.5 2.3-6.3 0-11.6-4.1-13.5-9.8l-7.9 6.1C6.5 42.6 14.6 48 24 48z" />
  </svg>
);

export const GoogleSignInButton: React.FC<Props> = ({ google, busy, onLogin, onLogout }) => {
  if (google?.signedIn) {
    return (
      <div className="flex items-center gap-2">
        <span className="text-xs text-slate-600 dark:text-slate-400 max-w-[180px] truncate" title={google.email ?? undefined}>
          {google.email ?? 'Sesión de Google'}
        </span>
        <button type="button" onClick={onLogout} className="px-3 py-1.5 text-xs font-medium rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors">
          Salir
        </button>
      </div>
    );
  }
  const unavailable = google ? !google.clientConfigured : false;
  return (
    <button
      type="button"
      onClick={onLogin}
      disabled={busy || unavailable}
      title={unavailable ? 'Falta ISY_GOOGLE_CLIENT_ID en web/.env (ver web/README.md)' : undefined}
      className="inline-flex items-center gap-2 px-3.5 py-2 text-xs font-medium rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 hover:bg-slate-50 dark:hover:bg-slate-800 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
    >
      <GoogleG />
      {busy || google?.loginPending ? 'Esperando a Google…' : 'Iniciar sesión con Google'}
    </button>
  );
};

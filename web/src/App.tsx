import React, { useCallback, useEffect, useState } from 'react';
import { api, type ActivityEntry, type PanelStatus, type PendingAction, type ToolInfo } from './lib/api';
import type { SemanticContextNode } from './lib/semantic';
import { readStored, resolveEffectiveTheme, type ThemeMode, writeStored } from './lib/theme';
import { ActivityPanel } from './components/ActivityPanel';
import { AssistantPanel } from './components/AssistantPanel';
import { ConfirmModal, type PendingConfirmation } from './components/ConfirmModal';
import { ContextPanel } from './components/ContextPanel';
import { GoogleSignInButton } from './components/GoogleSignInButton';
import { OptionsPanel } from './components/OptionsPanel';
import { WorkspacePanel } from './components/WorkspacePanel';
import { Notice } from './components/ui';

type Section = 'assistant' | 'context' | 'workspace' | 'activity' | 'options';

const TABS: Array<{ id: Section; label: string; devLabel?: string; devOnly?: boolean }> = [
  { id: 'assistant', label: 'Asistente' },
  { id: 'context', label: 'Memoria & Contexto', devLabel: 'Árbol de contexto' },
  { id: 'workspace', label: 'Mis Apps de Google', devLabel: 'Herramientas de Google' },
  { id: 'activity', label: 'Bitácora', devOnly: true },
  { id: 'options', label: 'Opciones' },
];

export default function App() {
  const [section, setSection] = useState<Section>('assistant');
  const [developerMode, setDeveloperMode] = useState(() => readStored('isy.dev', ['1', '0'], '0') === '1');
  const [allowWrite, setAllowWrite] = useState(() => readStored('isy.write', ['1', '0'], '0') === '1');
  const [themeMode, setThemeMode] = useState<ThemeMode>(() => readStored('isy.theme', ['auto', 'dark', 'light'] as const, 'auto'));
  const [systemDark, setSystemDark] = useState(() => window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? true);

  const [status, setStatus] = useState<PanelStatus>();
  const [tools, setTools] = useState<ToolInfo[]>([]);
  const [nodes, setNodes] = useState<SemanticContextNode[]>([]);
  const [contextFile, setContextFile] = useState('');
  const [activity, setActivity] = useState<ActivityEntry[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loginBusy, setLoginBusy] = useState(false);
  const [pending, setPending] = useState<PendingConfirmation | null>(null);

  const effectiveTheme = resolveEffectiveTheme(themeMode, systemDark);
  const visibleTabs = TABS.filter((t) => developerMode || !t.devOnly);

  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);
  useEffect(() => { document.documentElement.classList.toggle('dark', effectiveTheme === 'dark'); }, [effectiveTheme]);

  const refreshStatus = useCallback(() => api.status().then(setStatus).catch((e) => setLoadError(e.message)), []);
  const refreshContext = useCallback(async () => {
    const data = await api.context().catch((e) => { setLoadError(e.message); return null; });
    if (data) { setNodes(data.nodes); setContextFile(data.file); }
    void refreshStatus();
  }, [refreshStatus]);
  const refreshActivity = useCallback(() => api.activity().then(setActivity).catch(() => {}), []);

  useEffect(() => {
    void refreshStatus();
    void refreshContext();
    void refreshActivity();
    api.tools().then(setTools).catch((e) => setLoadError(e.message));
  }, [refreshStatus, refreshContext, refreshActivity]);

  // Mientras se espera a Google, se consulta el estado hasta que la sesión se complete o falle.
  useEffect(() => {
    if (!loginBusy && !status?.google.loginPending) return;
    const timer = setInterval(() => { void refreshStatus(); void refreshActivity(); }, 1500);
    return () => clearInterval(timer);
  }, [loginBusy, status?.google.loginPending, refreshStatus, refreshActivity]);
  useEffect(() => { if (loginBusy && !status?.google.loginPending) setLoginBusy(false); }, [status?.google.loginPending, loginBusy]);

  const login = async () => {
    setLoginBusy(true);
    try {
      const { authUrl } = await api.login(allowWrite);
      window.open(authUrl, '_blank', 'noopener');
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
      setLoginBusy(false);
    }
  };
  const logout = async () => { await api.logout(); await refreshStatus(); await refreshActivity(); };

  const confirmAction = (action: PendingAction) =>
    setPending({
      title: `Confirmar: ${action.service}`,
      description: `${action.description} El asistente lo propuso; no se hace nada hasta que lo confirmes.`,
      details: Object.entries(action.args).map(([label, value]) => ({ label, value: typeof value === 'string' ? value : JSON.stringify(value) })),
      onConfirm: async () => {
        try { await api.callTool(action.name, action.args, true); await refreshContext(); } finally { void refreshActivity(); }
      },
    });

  const setDev = (value: boolean) => {
    setDeveloperMode(value);
    writeStored('isy.dev', value ? '1' : '0');
    if (!value && section === 'activity') setSection('options');
  };

  return (
    <div className="min-h-screen bg-slate-50 dark:bg-slate-950 text-slate-900 dark:text-slate-100 transition-colors">
      <header className="flex items-center justify-between gap-8 px-6 py-4 border-b border-slate-200 dark:border-slate-800 bg-white/90 dark:bg-slate-900/90 backdrop-blur-md sticky top-0 z-30">
        <a href="#assistant" onClick={(e) => { e.preventDefault(); setSection('assistant'); }} className="text-lg font-bold tracking-tight whitespace-nowrap shrink-0">iSyCode Móvil</a>
        <nav aria-label="Navegación principal" className="flex items-center gap-6 text-sm font-medium text-slate-600 dark:text-slate-400 overflow-x-auto">
          {visibleTabs.map((tab) => (
            <a key={tab.id} href={`#${tab.id}`} onClick={(e) => { e.preventDefault(); setSection(tab.id); }} aria-current={section === tab.id ? 'page' : undefined}
              className={`hover:text-slate-900 dark:hover:text-slate-100 transition-colors whitespace-nowrap shrink-0 ${section === tab.id ? 'text-blue-600 dark:text-blue-400 underline underline-offset-8' : ''}`}>
              {developerMode && tab.devLabel ? tab.devLabel : tab.label}
            </a>
          ))}
        </nav>
        <div className="flex items-center shrink-0">
          <GoogleSignInButton google={status?.google} busy={loginBusy} onLogin={() => void login()} onLogout={() => void logout()} />
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 sm:px-6 py-8 space-y-8">
        <section className="pb-6 border-b border-slate-200 dark:border-slate-800">
          <p className="text-xs font-mono text-slate-500 dark:text-slate-400">Gmail · Calendar · Drive · Docs · Sheets · Tasks · Keep · Maps · Memoria semántica</p>
          <h1 className="mt-1 text-2xl sm:text-3xl font-bold tracking-tight" style={{ textWrap: 'balance' }}>Tu asistente conectado con Google y tu memoria</h1>
          <p className="mt-2 max-w-3xl text-sm text-slate-600 dark:text-slate-400 leading-relaxed">
            Corre en tu computadora y solo escucha en <code className="font-mono">127.0.0.1</code>. Lo que cambia algo siempre te pide confirmación.
          </p>
        </section>

        {loadError && <Notice tone="error">{loadError}</Notice>}

        {section === 'assistant' && <AssistantPanel status={status} developerMode={developerMode} onConfirmAction={confirmAction} onOpenOptions={() => setSection('options')} />}
        {section === 'context' && <ContextPanel nodes={nodes} file={contextFile} developerMode={developerMode} onChanged={refreshContext} onConfirm={setPending} />}
        {section === 'workspace' && <WorkspacePanel tools={tools} status={status} developerMode={developerMode} onConfirm={setPending} onActivity={() => { void refreshActivity(); void refreshContext(); }} />}
        {section === 'activity' && <ActivityPanel entries={activity} onRefresh={() => void refreshActivity()} />}
        {section === 'options' && (
          <OptionsPanel status={status} themeMode={themeMode} effectiveTheme={effectiveTheme}
            onThemeModeChange={(m) => { setThemeMode(m); writeStored('isy.theme', m); }}
            developerMode={developerMode} onDeveloperModeChange={setDev}
            allowWrite={allowWrite} onAllowWriteChange={(v) => { setAllowWrite(v); writeStored('isy.write', v ? '1' : '0'); }} />
        )}
      </main>

      <ConfirmModal pending={pending} onClose={() => setPending(null)} />
    </div>
  );
}

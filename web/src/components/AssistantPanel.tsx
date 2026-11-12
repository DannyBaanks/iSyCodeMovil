import React, { useEffect, useRef, useState } from 'react';
import { Mic, Send, Sparkles } from 'lucide-react';
import { api, type AssistantReply, type PanelStatus, type PendingAction } from '../lib/api';
import { Card, Eyebrow, Notice, ghostButton, inputClass, primaryButton } from './ui';

interface QuickAction { id: string; label: string; hint: string; prompt: string; grounding?: 'maps' | 'search'; needsGoogle: boolean }

const QUICK_ACTIONS: QuickAction[] = [
  { id: 'mail', label: 'Revisar correos sin leer', hint: 'Lee tu bandeja y resume lo urgente', prompt: 'Revisa mis correos sin leer (is:unread) y resúmeme los urgentes.', needsGoogle: true },
  { id: 'agenda', label: 'Mi agenda de hoy', hint: 'Consulta Google Calendar y propone huecos', prompt: '¿Qué tengo hoy en mi calendario? Propón dos huecos libres de 45 minutos.', needsGoogle: true },
  { id: 'tasks', label: 'Mis pendientes', hint: 'Lista tus tareas de Google Tasks', prompt: 'Lista mis pendientes de Google Tasks.', needsGoogle: true },
  { id: 'docs', label: 'Documentos recientes', hint: 'Busca en Drive', prompt: 'Busca mis documentos más recientes en Drive.', needsGoogle: true },
  { id: 'maps', label: 'Cafés cerca de mí', hint: 'Google Maps (pide tu ubicación)', prompt: 'Encuentra cafeterías con buen WiFi para trabajar cerca de mí.', grounding: 'maps', needsGoogle: false },
  { id: 'web', label: 'Buscar en la web', hint: 'Google Search con fuentes', prompt: '¿Cuáles son las novedades recientes de llama.cpp?', grounding: 'search', needsGoogle: false },
];

interface Props {
  status: PanelStatus | undefined;
  developerMode: boolean;
  onConfirmAction: (action: PendingAction) => void;
  onOpenOptions: () => void;
}

type SpeechRecognitionCtor = new () => { lang: string; interimResults: boolean; onresult: ((e: any) => void) | null; onend: (() => void) | null; onerror: (() => void) | null; start(): void; stop(): void };

export const AssistantPanel: React.FC<Props> = ({ status, developerMode, onConfirmAction, onOpenOptions }) => {
  const [prompt, setPrompt] = useState('');
  const [useContext, setUseContext] = useState(true);
  const [busy, setBusy] = useState(false);
  const [reply, setReply] = useState<AssistantReply | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [listening, setListening] = useState(false);
  const recognition = useRef<InstanceType<SpeechRecognitionCtor> | null>(null);

  const speechSupported = typeof window !== 'undefined' && Boolean((window as any).SpeechRecognition || (window as any).webkitSpeechRecognition);
  useEffect(() => () => recognition.current?.stop(), []);

  const geminiReady = status?.gemini.configured ?? false;
  const signedIn = status?.google.signedIn ?? false;

  const send = async (text: string, grounding?: 'maps' | 'search') => {
    if (!text.trim() || busy) return;
    setBusy(true);
    setError(null);
    setReply(null);
    try {
      let coords: { latitude: number; longitude: number } | undefined;
      if (grounding === 'maps') {
        coords = await new Promise((resolve, reject) => {
          if (!navigator.geolocation) return reject(new Error('Tu navegador no ofrece ubicación.'));
          navigator.geolocation.getCurrentPosition(
            (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
            () => reject(new Error('Necesito tu permiso de ubicación para buscar cerca de ti.')),
            { timeout: 10_000 },
          );
        });
      }
      setReply(await api.assistant({ prompt: text, useContext, grounding, ...coords }));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const toggleMic = () => {
    if (listening) return recognition.current?.stop();
    const Ctor: SpeechRecognitionCtor | undefined = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (!Ctor) return;
    const rec = new Ctor();
    rec.lang = 'es-MX';
    rec.interimResults = false;
    rec.onresult = (e: any) => setPrompt((prev) => `${prev} ${e.results[0][0].transcript}`.trim());
    rec.onend = () => setListening(false);
    rec.onerror = () => setListening(false);
    recognition.current = rec;
    setListening(true);
    rec.start();
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
      <Card className="lg:col-span-5 p-5">
        <Eyebrow>Acciones rápidas</Eyebrow>
        <h2 className="mt-1 text-base font-semibold">Con un toque</h2>
        <ul className="mt-4 space-y-2">
          {QUICK_ACTIONS.map((qa) => {
            const blocked = !geminiReady || (qa.needsGoogle && !signedIn);
            return (
              <li key={qa.id}>
                <button
                  type="button"
                  disabled={busy || blocked}
                  onClick={() => { setPrompt(qa.prompt); void send(qa.prompt, qa.grounding); }}
                  className="w-full text-left rounded-xl border border-slate-200 dark:border-slate-800 px-4 py-3 hover:bg-slate-50 dark:hover:bg-slate-800/60 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
                >
                  <span className="block text-sm font-medium">{qa.label}</span>
                  <span className="block text-xs text-slate-500 dark:text-slate-400">{qa.hint}</span>
                </button>
              </li>
            );
          })}
        </ul>
        {!geminiReady && <div className="mt-4"><Notice tone="warn">Falta <code className="font-mono">GEMINI_API_KEY</code> en <code className="font-mono">web/.env</code>. Sin ella el asistente no puede responder.</Notice></div>}
        {geminiReady && !signedIn && <div className="mt-4"><Notice>Inicia sesión con Google para las acciones de correo, agenda, tareas y Drive.</Notice></div>}
      </Card>

      <Card className="lg:col-span-7 p-5 flex flex-col gap-4">
        <div>
          <Eyebrow>Asistente</Eyebrow>
          <h2 className="mt-1 text-base font-semibold">Pídele algo</h2>
        </div>
        <form onSubmit={(e) => { e.preventDefault(); void send(prompt); }} className="space-y-3">
          <textarea
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void send(prompt); } }}
            rows={3}
            maxLength={8000}
            placeholder="Ej. Revisa mis correos sin leer y propón una respuesta para el más urgente"
            className={inputClass}
            aria-label="Mensaje para el asistente"
          />
          <div className="flex flex-wrap items-center justify-between gap-3">
            <label className="inline-flex items-center gap-2 text-xs text-slate-600 dark:text-slate-400 cursor-pointer">
              <input type="checkbox" checked={useContext} onChange={(e) => setUseContext(e.target.checked)} className="accent-blue-600" />
              <Sparkles className="w-3.5 h-3.5 text-blue-500" /> Usar mi memoria (solo se envía lo relevante a Gemini)
            </label>
            <div className="flex items-center gap-2">
              {speechSupported && (
                <button type="button" onClick={toggleMic} className={ghostButton} aria-pressed={listening} aria-label="Dictar con el micrófono">
                  <Mic className={`w-3.5 h-3.5 ${listening ? 'text-red-500' : ''}`} /> {listening ? 'Escuchando…' : 'Dictar'}
                </button>
              )}
              <button type="submit" disabled={busy || !geminiReady || !prompt.trim()} className={primaryButton}>
                <Send className="w-4 h-4" /> {busy ? 'Pensando…' : 'Enviar'}
              </button>
            </div>
          </div>
        </form>

        {error && <Notice tone="error">{error}</Notice>}

        {reply && (
          <div className="space-y-4 border-t border-slate-200 dark:border-slate-800 pt-4">
            {reply.text && <p className="whitespace-pre-wrap text-sm leading-relaxed">{reply.text}</p>}

            {reply.pendingActions.length > 0 && (
              <div className="space-y-2">
                <Eyebrow>Propuestas que esperan tu confirmación</Eyebrow>
                {reply.pendingActions.map((action, i) => (
                  <div key={`${action.name}-${i}`} className="flex items-center justify-between gap-3 rounded-xl border border-amber-200 dark:border-amber-900 bg-amber-50 dark:bg-amber-950/30 px-3.5 py-2.5">
                    <div className="min-w-0">
                      <p className="text-sm font-medium">{action.service}: <span className="font-mono text-xs">{action.name}</span></p>
                      <p className="text-xs text-slate-600 dark:text-slate-400 truncate">{JSON.stringify(action.args)}</p>
                    </div>
                    <button type="button" onClick={() => onConfirmAction(action)} className={primaryButton}>Revisar</button>
                  </div>
                ))}
              </div>
            )}

            {reply.links.length > 0 && (
              <ul className="flex flex-wrap gap-2">
                {reply.links.map((l, i) => (
                  <li key={i}><a href={l.uri} target="_blank" rel="noreferrer noopener" className={ghostButton}>{l.kind === 'maps' ? '📍' : '🔗'} {l.title}</a></li>
                ))}
              </ul>
            )}

            <div className="flex flex-wrap gap-1.5 text-[11px] font-mono text-slate-500 dark:text-slate-400">
              {reply.toolsRun.map((t, i) => (
                <span key={i} className={`px-2 py-0.5 rounded-md border ${t.ok ? 'border-emerald-300 dark:border-emerald-800' : 'border-red-300 dark:border-red-900 text-red-600 dark:text-red-400'}`} title={t.summary}>
                  {t.ok ? '✓' : '✕'} {t.name}
                </span>
              ))}
              {reply.contextUsed.map((c) => (
                <span key={c.id} className="px-2 py-0.5 rounded-md border border-blue-300 dark:border-blue-900 text-blue-700 dark:text-blue-300" title={c.semanticPath.join(' › ')}>memoria: {c.title}</span>
              ))}
            </div>
            {developerMode && reply.traversalSteps.length > 0 && (
              <pre className="rounded-xl bg-slate-50 dark:bg-slate-950 border border-slate-200 dark:border-slate-800 p-3 text-[11px] font-mono whitespace-pre-wrap">{reply.traversalSteps.join('\n')}{reply.selectedTools ? `\nHerramientas ofrecidas: ${reply.selectedTools.join(', ') || '(ninguna)'}` : ''}</pre>
            )}
          </div>
        )}
        {!signedIn && geminiReady && (
          <button type="button" onClick={onOpenOptions} className="self-start text-xs text-blue-600 dark:text-blue-400 underline underline-offset-4">¿Cómo conecto Google?</button>
        )}
      </Card>
    </div>
  );
};

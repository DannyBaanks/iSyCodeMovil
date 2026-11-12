import React, { useMemo, useRef, useState } from 'react';
import { ChevronDown, ChevronRight, Download, Folder, FolderOpen, Search, Trash2, Upload } from 'lucide-react';
import { api } from '../lib/api';
import { buildTree, retrieve, searchNodes, type SemanticContextNode, type SemanticTreeFolder } from '../lib/semantic';
import { SemanticObsidianGraph } from './SemanticObsidianGraph';
import { Card, Eyebrow, Notice, ghostButton, inputClass, primaryButton } from './ui';
import type { PendingConfirmation } from './ConfirmModal';

interface Props {
  nodes: SemanticContextNode[];
  file: string;
  developerMode: boolean;
  onChanged: () => Promise<void> | void;
  onConfirm: (pending: PendingConfirmation) => void;
}

const PRIORITY_LABEL = { normal: 'Normal', high: 'Alta', critical: 'Crítica (siempre activa)' } as const;

const Folder_: React.FC<{ folder: SemanticTreeFolder; highlight: Set<string>; onDelete: (n: SemanticContextNode) => void; developerMode: boolean }> = ({ folder, highlight, onDelete, developerMode }) => {
  const [open, setOpen] = useState(true);
  return (
    <li>
      <button type="button" onClick={() => setOpen(!open)} className="flex w-full items-center gap-1.5 py-1 text-sm font-medium text-left" aria-expanded={open}>
        {open ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
        {open ? <FolderOpen className="w-4 h-4 text-blue-500" /> : <Folder className="w-4 h-4 text-blue-500" />}
        <span>{folder.name}</span>
        <span className="ml-auto text-[11px] font-mono text-slate-400">{folder.totalDescendantNodes}{developerMode ? ` · ~${folder.totalEstimatedTokens} tok` : ''}</span>
      </button>
      {open && (
        <ul className="ml-3 pl-3 border-l border-slate-200 dark:border-slate-800">
          {folder.subfolders.map((sub) => <Folder_ key={sub.fullPath.join('/')} folder={sub} highlight={highlight} onDelete={onDelete} developerMode={developerMode} />)}
          {folder.nodes.map((node) => (
            <li key={node.id} className={`group my-1 rounded-xl border px-3 py-2 ${highlight.has(node.id) ? 'border-blue-300 dark:border-blue-800 bg-blue-50 dark:bg-blue-950/30' : 'border-slate-200 dark:border-slate-800'}`}>
              <div className="flex items-start justify-between gap-2">
                <p className="text-sm font-medium">{node.title}</p>
                <button type="button" onClick={() => onDelete(node)} aria-label={`Borrar ${node.title}`} className="opacity-0 group-hover:opacity-100 focus:opacity-100 p-1 rounded-md hover:bg-slate-100 dark:hover:bg-slate-800"><Trash2 className="w-3.5 h-3.5" /></button>
              </div>
              <p className="mt-0.5 text-xs text-slate-600 dark:text-slate-400">{node.summary}</p>
              <p className="mt-1 text-[11px] font-mono text-slate-400">
                {PRIORITY_LABEL[node.priority]} · {new Date(node.createdAt).toLocaleDateString()}{developerMode ? ` · ${node.sourceTool} · ~${node.estimatedTokens} tok` : ''}
              </p>
            </li>
          ))}
        </ul>
      )}
    </li>
  );
};

export const ContextPanel: React.FC<Props> = ({ nodes, file, developerMode, onChanged, onConfirm }) => {
  const [query, setQuery] = useState('');
  const [probe, setProbe] = useState('');
  const [form, setForm] = useState({ title: '', summary: '', domain: '', category: '', topic: '', priority: 'normal' });
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const matches = useMemo(() => searchNodes(nodes, query), [nodes, query]);
  const visible = useMemo(() => matches.map((m) => m.node), [matches]);
  const tree = useMemo(() => buildTree(visible), [visible]);
  const preview = useMemo(() => (probe.trim() ? retrieve(nodes, probe) : null), [nodes, probe]);
  const highlight = useMemo(() => new Set(preview?.selectedNodes.map((n) => n.id) ?? []), [preview]);
  const domains = useMemo(() => Array.from(new Set(nodes.map((n) => n.semanticPath[0]))), [nodes]);

  const askDelete = (node: SemanticContextNode) =>
    onConfirm({
      title: '¿Borrar este recuerdo?',
      description: 'Se quita del árbol y el asistente dejará de usarlo.',
      details: [{ label: 'Título', value: node.title }, { label: 'Carpeta', value: node.semanticPath.join(' › ') }],
      confirmLabel: 'Borrar',
      onConfirm: async () => { await api.deleteContext(node.id); await onChanged(); },
    });

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    setError(null);
    try {
      await api.saveContext({ title: form.title, summary: form.summary, semanticPath: [form.domain, form.category, form.topic], priority: form.priority });
      setForm({ ...form, title: '', summary: '' });
      await onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  const exportJson = async () => {
    const doc = await api.exportContext();
    const url = URL.createObjectURL(new Blob([JSON.stringify(doc, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = 'isycode-contexto.json';
    a.click();
    URL.revokeObjectURL(url);
  };

  const importJson = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    try {
      const result = await api.importContext(JSON.parse(await file.text()));
      setError(null);
      onConfirm({ title: 'Importación lista', description: 'Se mezcló el archivo sin duplicar lo que ya tenías.', details: [{ label: 'Agregados', value: String(result.added) }, { label: 'Ya existían', value: String(result.skipped) }], confirmLabel: 'Entendido', onConfirm: async () => {} });
      await onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'El archivo no es un JSON de contexto válido.');
    } finally {
      if (fileInput.current) fileInput.current.value = '';
    }
  };

  return (
    <div className="space-y-6">
      <Card className="p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <Eyebrow>Buscar en tu memoria</Eyebrow>
            <p className="mt-1 text-xs text-slate-500">{nodes.length} recuerdo(s) · se guardan en tu compu: <code className="font-mono">{file}</code></p>
          </div>
          <div className="flex gap-2">
            <button type="button" onClick={exportJson} className={ghostButton}><Download className="w-3.5 h-3.5" /> Exportar</button>
            <button type="button" onClick={() => fileInput.current?.click()} className={ghostButton}><Upload className="w-3.5 h-3.5" /> Importar</button>
            <input ref={fileInput} type="file" accept="application/json" hidden onChange={(e) => void importJson(e.target.files?.[0])} />
          </div>
        </div>
        <div className="relative mt-3">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-400" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Título o carpeta (tolera erratas: «swft», «calendr»)" className={`${inputClass} pl-9`} aria-label="Buscar en la memoria" />
        </div>
      </Card>

      {error && <Notice tone="error">{error}</Notice>}

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        <Card className="lg:col-span-7 p-5">
          <Eyebrow>Carpetas</Eyebrow>
          {tree.length === 0 ? (
            <p className="mt-3 text-sm text-slate-500">{nodes.length === 0 ? 'Todavía no guardas nada. Usa el formulario o pídele al asistente que guarde un acuerdo.' : 'Sin coincidencias.'}</p>
          ) : (
            <ul className="mt-3 space-y-1">{tree.map((f) => <Folder_ key={f.name} folder={f} highlight={highlight} onDelete={askDelete} developerMode={developerMode} />)}</ul>
          )}
        </Card>

        <div className="lg:col-span-5 space-y-6">
          <Card className="p-5">
            <Eyebrow>¿Qué vería el modelo?</Eyebrow>
            <p className="mt-1 text-xs text-slate-500">Escribe un mensaje y mira qué recuerdos se inyectarían (se resaltan a la izquierda).</p>
            <input value={probe} onChange={(e) => setProbe(e.target.value)} placeholder="Ej. ajusta la app de iPhone" className={`${inputClass} mt-3`} aria-label="Mensaje de prueba" />
            {preview && (
              <ol className="mt-3 space-y-1 text-xs font-mono text-slate-600 dark:text-slate-400">
                {preview.traversalSteps.map((s, i) => <li key={i}>{i + 1}. {s}</li>)}
              </ol>
            )}
          </Card>

          <Card className="p-5">
            <Eyebrow>Guardar un recuerdo</Eyebrow>
            <form onSubmit={save} className="mt-3 space-y-2.5">
              <input required value={form.title} maxLength={120} onChange={(e) => setForm({ ...form, title: e.target.value })} placeholder="Título corto" className={inputClass} aria-label="Título" />
              <textarea required value={form.summary} maxLength={1200} rows={3} onChange={(e) => setForm({ ...form, summary: e.target.value })} placeholder="Lo que quieres que el asistente recuerde" className={inputClass} aria-label="Resumen" />
              <div className="grid grid-cols-3 gap-2">
                <input required list="ctx-domains" value={form.domain} maxLength={60} onChange={(e) => setForm({ ...form, domain: e.target.value })} placeholder="Dominio" className={inputClass} aria-label="Carpeta 1: dominio" />
                <input required value={form.category} maxLength={60} onChange={(e) => setForm({ ...form, category: e.target.value })} placeholder="Categoría" className={inputClass} aria-label="Carpeta 2: categoría" />
                <input required value={form.topic} maxLength={60} onChange={(e) => setForm({ ...form, topic: e.target.value })} placeholder="Tema" className={inputClass} aria-label="Carpeta 3: tema" />
              </div>
              <datalist id="ctx-domains">{domains.map((d) => <option key={d} value={d} />)}</datalist>
              <div className="flex items-center justify-between gap-2">
                <select value={form.priority} onChange={(e) => setForm({ ...form, priority: e.target.value })} className={`${inputClass} w-auto`} aria-label="Prioridad">
                  {Object.entries(PRIORITY_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                </select>
                <button type="submit" disabled={saving} className={primaryButton}>{saving ? 'Guardando…' : 'Guardar'}</button>
              </div>
              <p className="text-[11px] text-slate-500">Las «críticas» se le muestran al modelo en cada mensaje; úsalas solo para reglas que nunca deba olvidar.</p>
            </form>
          </Card>
        </div>
      </div>

      {nodes.length > 0 && (
        <SemanticObsidianGraph contextNodes={nodes} developerMode={developerMode} onSelectClusterQuery={setQuery} />
      )}
    </div>
  );
};

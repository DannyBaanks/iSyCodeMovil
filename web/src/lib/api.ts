import type { SemanticContextNode } from './semantic';

export interface ToolInfo {
  name: string;
  id: string;
  service: string;
  mode: 'read' | 'write';
  description: string;
  inputSchema: { type: 'object'; properties: Record<string, { type: string; description?: string; enum?: string[]; items?: unknown }>; required: string[] };
  scopes: string[];
  local: boolean;
}

export interface PanelStatus {
  google: { clientConfigured: boolean; configured?: boolean; signedIn: boolean; email: string | null; name: string | null; scopes: string[]; loginPending: boolean };
  gemini: { configured: boolean; model: string };
  context: { file: string; nodes: number };
  tools: number;
}

export interface PendingAction { name: string; args: Record<string, unknown>; service: string; description: string }

export interface AssistantReply {
  text: string;
  toolsRun: Array<{ name: string; ok: boolean; summary: string }>;
  pendingActions: PendingAction[];
  links: Array<{ title: string; uri: string; kind: 'maps' | 'search' }>;
  contextUsed: Array<{ id: string; title: string; semanticPath: string[] }>;
  traversalSteps: string[];
  selectedTools?: string[];
}

export interface ActivityEntry {
  id: string;
  at: string;
  kind: 'tool' | 'assistant' | 'auth' | 'context';
  name: string;
  status: 'ok' | 'error' | 'pending';
  message: string;
  retry?: { name: string; args: Record<string, unknown> };
}

export class ApiError extends Error {
  constructor(message: string, public status: number, public code?: string) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(data?.error ?? `Error ${response.status}`, response.status, data?.code);
  return data as T;
}

export const api = {
  status: () => request<PanelStatus>('GET', '/api/status'),
  tools: () => request<{ tools: ToolInfo[] }>('GET', '/api/tools').then((r) => r.tools),
  login: (write: boolean) => request<{ authUrl: string }>('POST', '/api/google/login', { write }),
  logout: () => request<{ ok: true }>('POST', '/api/google/logout'),
  callTool: (name: string, args: Record<string, unknown>, confirmed = false) =>
    request<{ ok: true; data: unknown }>('POST', '/api/tools/call', { name, args, confirmed }),
  assistant: (body: { prompt: string; useContext: boolean; grounding?: 'maps' | 'search'; latitude?: number; longitude?: number }) =>
    request<AssistantReply>('POST', '/api/assistant', body),
  context: () => request<{ nodes: SemanticContextNode[]; file: string }>('GET', '/api/context'),
  saveContext: (node: { title: string; summary: string; semanticPath: string[]; priority: string }) =>
    request<{ node: SemanticContextNode; created: boolean }>('POST', '/api/context', node),
  deleteContext: (id: string) => request<{ removed: boolean }>('DELETE', `/api/context/${encodeURIComponent(id)}`),
  exportContext: () => request<unknown>('GET', '/api/context/export'),
  importContext: (doc: unknown) => request<{ added: number; skipped: number }>('POST', '/api/context/import', doc),
  activity: () => request<{ entries: ActivityEntry[] }>('GET', '/api/activity').then((r) => r.entries),
  clearActivity: () => request<{ ok: true }>('DELETE', '/api/activity'),
};

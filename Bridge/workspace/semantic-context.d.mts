// Tipos de semantic-context.mjs, para el panel web (TypeScript) y para el editor.
export const SCHEMA: 'isycode.semantic-context.v1';
export const PRIORITIES: readonly ['normal', 'high', 'critical'];
export const LIMITS: { readonly title: number; readonly summary: number; readonly segment: number; readonly maxNodes: number };
export class ContextError extends Error {}

export type Priority = 'normal' | 'high' | 'critical';

export interface SemanticContextNode {
  id: string;
  title: string;
  summary: string;
  /** Exactamente tres carpetas: dominio, categoría y tema. */
  semanticPath: string[];
  priority: Priority;
  sourceTool: string;
  estimatedTokens: number;
  /** ISO 8601. */
  createdAt: string;
}

export interface SemanticTreeFolder {
  name: string;
  fullPath: string[];
  depth: number;
  subfolders: SemanticTreeFolder[];
  nodes: SemanticContextNode[];
  totalDescendantNodes: number;
  totalEstimatedTokens: number;
}

export interface FuzzyMatchedContextNode {
  node: SemanticContextNode;
  score: number;
  matchedField: 'title' | 'semanticPath' | 'both';
}

export interface RetrievalResult {
  matchedPath: string[];
  selectedNodes: SemanticContextNode[];
  traversalSteps: string[];
  estimatedTokens: number;
}

export interface SemanticGraphNode {
  id: string;
  label: string;
  shortLabel: string;
  kind: 'domain-hub' | 'path-cluster' | 'context-node';
  domain: string;
  semanticPath: string[];
  parentClusterId: string | null;
  childCount: number;
  priority: Priority;
  radius: number;
  estimatedTokens: number;
  sourceTool: string;
  createdAt: string;
  summary: string;
}

export interface SemanticGraphLink {
  id: string;
  source: string;
  target: string;
  kind: 'folder-hierarchy' | 'cross-semantic';
  relationshipLabel: string;
  reason: string;
  strength: number;
}

export function normalizeText(input: unknown): string;
export function estimateTokens(text: unknown): number;
export function significantWords(text: string, minLength?: number): string[];
export function editDistance(a: string, b: string): number;
export function scoreToken(normalizedCandidate: string, candidateWords: string[], token: string): number;
export function scoreFuzzy(candidate: string, query: string): number;
export function scoreRelevance(candidate: string, tokens: string[]): number;
export function createNode(
  input: { id?: string; title: string; summary: string; semanticPath: string[]; priority?: Priority; sourceTool?: string; createdAt?: string },
  options?: { now?: Date; id?: string },
): SemanticContextNode;
export function nodeKey(node: SemanticContextNode): string;
export function suggestPath(text: string): string[];
export function buildTree(nodes: SemanticContextNode[]): SemanticTreeFolder[];
export function searchNodes(nodes: SemanticContextNode[], query: string): FuzzyMatchedContextNode[];
export function retrieve(nodes: SemanticContextNode[], prompt: string, options?: { maxNodes?: number; tokenBudget?: number; branchWidth?: number }): RetrievalResult;
export function formatForPrompt(result: RetrievalResult): string | null;
export function buildGraph(nodes: SemanticContextNode[]): { graphNodes: SemanticGraphNode[]; graphLinks: SemanticGraphLink[] };
export function exportDocument(nodes: SemanticContextNode[], now?: Date): { schema: string; exportedAt: string; nodes: SemanticContextNode[] };
export function parseDocument(value: unknown): SemanticContextNode[];

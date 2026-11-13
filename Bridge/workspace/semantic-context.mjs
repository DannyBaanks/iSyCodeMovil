/**
 * Árbol de contexto semántico progresivo.
 *
 * En vez de una lista plana de recuerdos, cada nodo vive en una ruta de tres carpetas
 * (dominio › categoría › tema). Para armar el contexto de un mensaje se recorre el árbol
 * de arriba abajo y solo se inyectan los nodos de las ramas que de verdad se parecen al
 * mensaje. Así un modelo pequeño (GUS en el iPhone, Ollama en la compu) recibe pocas
 * líneas y relevantes, no todo lo que el usuario ha guardado alguna vez.
 *
 * Es el motor de la compu (Bridge y panel web). Las apps tienen el suyo, con la misma idea pero otra
 * forma de datos: Sources/Assistant/SemanticContext.swift y android/.../assistant/SemanticContext.kt.
 * Todavía no hay sincronización entre ambos; si algún día la hay, el formato de intercambio es el de
 * `exportDocument` / `parseDocument` de este archivo (schema isycode.semantic-context.v1).
 *
 * Sin dependencias y sin I/O: es lógica pura para poder probarla en cualquier parte.
 */

export const SCHEMA = "isycode.semantic-context.v1";
export const PRIORITIES = Object.freeze(["normal", "high", "critical"]);

export const LIMITS = Object.freeze({
  title: 120,
  summary: 1200,
  segment: 60,
  maxNodes: 500,
});

/** Palabras que no distinguen un tema de otro. Se ignoran al comparar un mensaje con el árbol. */
const STOPWORDS = new Set(
  (
    "de la el en y a los las un una unos unas por para con sin que se su sus al del lo es son fue " +
    "como mas pero muy ya no si me mi te tu yo nos hay esto esta este estos estas eso esa ese " +
    "the and for with that this from your you are was were has have not but can will into about " +
    "ejecuta usa haz quiero necesito puedes favor"
  ).split(" "),
);

export class ContextError extends Error {}

// ---------------------------------------------------------------------------
// Texto
// ---------------------------------------------------------------------------

/** Minúsculas y sin acentos, para comparar "Ingeniería" con "ingenieria". */
export function normalizeText(input) {
  return String(input ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .trim();
}

/** Aproximación de tokens (4 caracteres ≈ 1 token). Es una estimación, no un conteo real. */
export function estimateTokens(text) {
  return Math.max(1, Math.ceil(String(text ?? "").length / 4));
}

/** Palabras con significado de un texto: normalizadas, de 3+ letras, sin stopwords, sin repetidos. */
export function significantWords(text, minLength = 3) {
  const seen = new Set();
  const words = [];
  for (const word of normalizeText(text).split(/[^a-z0-9]+/)) {
    if (word.length < minLength || STOPWORDS.has(word) || seen.has(word)) continue;
    seen.add(word);
    words.push(word);
  }
  return words;
}

/** Distancia de edición acotada: si difieren por más de 2 letras ya no nos interesa el valor exacto. */
export function editDistance(a, b) {
  if (a === b) return 0;
  if (Math.abs(a.length - b.length) > 2) return 99;
  let previous = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost);
    }
    previous = current;
  }
  return previous[b.length];
}

/**
 * Puntaje (0–120) de una palabra de la búsqueda contra un texto ya normalizado.
 *  1. aparece tal cual (más puntos si empieza una palabra o está cerca del inicio),
 *  2. aparece con una errata (1 letra de diferencia en palabras de 4+, 2 en las de 7+),
 *  3. sus letras aparecen en orden y juntas ("swft" → "swiftui").
 */
export function scoreToken(normalizedCandidate, candidateWords, token) {
  const index = normalizedCandidate.indexOf(token);
  if (index !== -1) {
    const startsWord = index === 0 || /[^a-z0-9]/.test(normalizedCandidate[index - 1]);
    return 100 + (startsWord ? 20 : 0) - Math.min(25, index);
  }

  if (token.length >= 4) {
    const allowed = token.length >= 7 ? 2 : 1;
    let best = 0;
    for (const word of candidateWords) {
      if (Math.abs(word.length - token.length) > allowed) continue;
      const distance = editDistance(token, word);
      if (distance <= allowed) best = Math.max(best, 80 - distance * 15);
    }
    if (best > 0) return best;
  }

  if (token.length >= 2) {
    let queryIndex = 0;
    let first = -1;
    let last = -1;
    let consecutive = 0;
    for (let i = 0; i < normalizedCandidate.length && queryIndex < token.length; i++) {
      if (normalizedCandidate[i] !== token[queryIndex]) continue;
      if (first === -1) first = i;
      if (last !== -1 && i === last + 1) consecutive += 12;
      last = i;
      queryIndex++;
    }
    if (queryIndex === token.length) {
      const span = last - first + 1;
      // Letras sueltas por todo el texto no cuentan: el tramo tiene que ser compacto.
      if (span <= token.length * 3 + 2) {
        return 45 + consecutive + Math.max(0, 35 - (span - token.length) * 5);
      }
    }
  }
  return 0;
}

/**
 * Búsqueda tolerante a errores: TODAS las palabras de la consulta tienen que aparecer.
 * Es la que usa el buscador del panel. Devuelve 0 si alguna no coincide.
 */
export function scoreFuzzy(candidate, query) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return 100;
  const normalizedCandidate = normalizeText(candidate);
  if (!normalizedCandidate) return 0;
  const tokens = normalizedQuery.split(/\s+/).filter(Boolean);
  const words = normalizedCandidate.split(/[^a-z0-9]+/).filter(Boolean);
  let total = 0;
  for (const token of tokens) {
    const score = scoreToken(normalizedCandidate, words, token);
    if (score <= 0) return 0;
    total += score;
  }
  return Math.round(total / tokens.length);
}

/**
 * Parecido de un mensaje largo con un nodo: aquí NO se exige que todas las palabras coincidan
 * (un mensaje tiene muchas palabras sueltas); se promedia sobre las que sí tienen significado.
 */
export function scoreRelevance(candidate, tokens) {
  if (tokens.length === 0) return 0;
  const normalizedCandidate = normalizeText(candidate);
  const words = normalizedCandidate.split(/[^a-z0-9]+/).filter(Boolean);
  let total = 0;
  for (const token of tokens) total += scoreToken(normalizedCandidate, words, token);
  return Math.round(total / tokens.length);
}

// ---------------------------------------------------------------------------
// Nodos
// ---------------------------------------------------------------------------

function cleanSegment(value, label) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!text) throw new ContextError(`La carpeta "${label}" no puede ir vacía.`);
  if (text.length > LIMITS.segment) throw new ContextError(`La carpeta "${label}" pasa de ${LIMITS.segment} caracteres.`);
  if (text.includes("›")) throw new ContextError(`La carpeta "${label}" no puede incluir "›".`);
  return text;
}

/** Crea un nodo validado. `now` y `id` se pueden inyectar para que las pruebas sean deterministas. */
export function createNode(input, { now = new Date(), id } = {}) {
  const title = String(input?.title ?? "").replace(/\s+/g, " ").trim();
  const summary = String(input?.summary ?? "").trim();
  if (!title) throw new ContextError("El contexto necesita un título.");
  if (!summary) throw new ContextError("El contexto necesita un resumen.");
  if (title.length > LIMITS.title) throw new ContextError(`El título pasa de ${LIMITS.title} caracteres.`);
  if (summary.length > LIMITS.summary) throw new ContextError(`El resumen pasa de ${LIMITS.summary} caracteres.`);

  const rawPath = input?.semanticPath ?? [];
  if (!Array.isArray(rawPath) || rawPath.length !== 3) {
    throw new ContextError("La ruta semántica lleva exactamente tres carpetas: dominio, categoría y tema.");
  }
  const semanticPath = [
    cleanSegment(rawPath[0], "dominio"),
    cleanSegment(rawPath[1], "categoría"),
    cleanSegment(rawPath[2], "tema"),
  ];

  const priority = input?.priority ?? "normal";
  if (!PRIORITIES.includes(priority)) throw new ContextError(`Prioridad desconocida: ${priority}.`);

  return {
    id: id ?? input?.id ?? `ctx-${now.getTime().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    title,
    summary,
    semanticPath,
    priority,
    sourceTool: String(input?.sourceTool ?? "as.save.context").slice(0, 64),
    estimatedTokens: estimateTokens(`${title}\n${summary}`),
    createdAt: (input?.createdAt ? new Date(input.createdAt) : now).toISOString(),
  };
}

/** Dos nodos son "el mismo recuerdo" si tienen el mismo título en la misma ruta. */
export function nodeKey(node) {
  return normalizeText(`${node.semanticPath.join("/")}::${node.title}`);
}

/**
 * Clasificador de respaldo para cuando solo hay texto libre (una nota suelta, una voz).
 * Lo normal es que quien guarda —el modelo o la persona— elija la ruta; esto solo evita
 * que algo se quede sin carpeta. Las reglas son genéricas, no de un proyecto.
 */
export function suggestPath(text) {
  const t = normalizeText(text);
  if (/gmail|correo|email|calendar|agenda|reunion|disponibilidad|contacto/.test(t)) {
    return ["Google Workspace", "Comunicación y agenda", "Correo y calendario"];
  }
  if (/drive|docs|documento|sheets|hoja de calculo|keep|classroom|tasks|tarea|nota/.test(t)) {
    return ["Google Workspace", "Conocimiento y métricas", "Documentos, hojas y notas"];
  }
  if (/swift|kotlin|ios|android|xcode|gradle|movil|app/.test(t)) {
    return ["Desarrollo", "Apps móviles", "iOS y Android"];
  }
  if (/modelo|gus|llama|ollama|gguf|contexto|agente|prompt|mcp|bridge|daemon/.test(t)) {
    return ["Desarrollo", "Agentes y modelos", "Modelos y contexto"];
  }
  if (/mapa|ubicacion|ruta|cerca|direccion|lugar|cafe/.test(t)) {
    return ["Entorno", "Lugares", "Ubicaciones frecuentes"];
  }
  return ["General", "Memoria conversacional", "Decisiones del usuario"];
}

// ---------------------------------------------------------------------------
// Árbol
// ---------------------------------------------------------------------------

/** Agrupa nodos en carpetas anidadas con totales por nivel (para el panel y para recorrerlo). */
export function buildTree(nodes) {
  const roots = [];
  for (const node of nodes) {
    let level = roots;
    node.semanticPath.forEach((name, index) => {
      let folder = level.find((candidate) => candidate.name === name);
      if (!folder) {
        folder = {
          name,
          fullPath: node.semanticPath.slice(0, index + 1),
          depth: index + 1,
          subfolders: [],
          nodes: [],
          totalDescendantNodes: 0,
          totalEstimatedTokens: 0,
        };
        level.push(folder);
      }
      folder.totalDescendantNodes += 1;
      folder.totalEstimatedTokens += node.estimatedTokens;
      if (index === node.semanticPath.length - 1) folder.nodes.push(node);
      level = folder.subfolders;
    });
  }
  return roots;
}

/** Nodos que coinciden con lo que escribió la persona en el buscador, de mejor a peor. */
export function searchNodes(nodes, query) {
  const trimmed = String(query ?? "").trim();
  if (!trimmed) return nodes.map((node) => ({ node, score: 100, matchedField: "both" }));
  const results = [];
  for (const node of nodes) {
    const pathText = node.semanticPath.join(" › ");
    const title = scoreFuzzy(node.title, trimmed);
    const path = scoreFuzzy(pathText, trimmed);
    const combined = scoreFuzzy(`${node.title} ${pathText}`, trimmed);
    const best = Math.max(title, path, combined);
    if (best <= 0) continue;
    const matchedField = title > 0 && path > 0 ? "both" : title >= path ? "title" : "semanticPath";
    results.push({ node, score: best, matchedField });
  }
  return results.sort((a, b) => b.score - a.score);
}

const PRIORITY_WEIGHT = { normal: 0, high: 5, critical: 10 };

/**
 * Recorre el árbol para un mensaje y devuelve los nodos que vale la pena inyectar.
 *
 *  Nivel 1  se puntúa cada nodo contra el mensaje y se eligen los 2 dominios con mejor nodo.
 *  Nivel 2  dentro de ellos, las 2 categorías con mejor nodo.
 *  Nivel 3  de esas ramas se toman los nodos por puntaje hasta `maxNodes` o `tokenBudget`.
 *  Siempre  los nodos "critical" (reglas que el usuario quiere que nunca se olviden) se suman
 *           al final si todavía hay presupuesto, aunque el mensaje no los mencione.
 *
 * Los pasos de `traversalSteps` describen lo que de verdad pasó; no hay métricas inventadas.
 */
export function retrieve(nodes, prompt, { maxNodes = 5, tokenBudget = 400, branchWidth = 2 } = {}) {
  const tokens = significantWords(prompt);
  const traversalSteps = [];
  const scored = nodes
    .map((node) => ({
      node,
      score: scoreRelevance(`${node.title} ${node.summary} ${node.semanticPath.join(" ")}`, tokens),
    }))
    .filter((entry) => entry.score > 0);

  const bestBy = (entries, key) => {
    const best = new Map();
    for (const entry of entries) {
      const name = key(entry.node);
      best.set(name, Math.max(best.get(name) ?? 0, entry.score));
    }
    return [...best.entries()].sort((a, b) => b[1] - a[1]).slice(0, branchWidth);
  };

  const domains = bestBy(scored, (node) => node.semanticPath[0]);
  domains.forEach(([name, score]) => traversalSteps.push(`Dominio: ${name} (${score})`));
  const inDomains = scored.filter((entry) => domains.some(([name]) => name === entry.node.semanticPath[0]));

  const categories = bestBy(inDomains, (node) => `${node.semanticPath[0]} › ${node.semanticPath[1]}`);
  categories.forEach(([name, score]) => traversalSteps.push(`Categoría: ${name} (${score})`));
  const inBranches = inDomains
    .filter((entry) => categories.some(([name]) => name === `${entry.node.semanticPath[0]} › ${entry.node.semanticPath[1]}`))
    .sort((a, b) => b.score + PRIORITY_WEIGHT[b.node.priority] - (a.score + PRIORITY_WEIGHT[a.node.priority]));

  const selected = [];
  let used = 0;
  const take = (node) => {
    if (selected.length >= maxNodes || selected.some((chosen) => chosen.id === node.id)) return;
    if (used + node.estimatedTokens > tokenBudget && selected.length > 0) return;
    selected.push(node);
    used += node.estimatedTokens;
  };
  for (const entry of inBranches) take(entry.node);

  const matched = selected.length;
  for (const node of nodes) if (node.priority === "critical") take(node);
  const alwaysOn = selected.length - matched;

  if (tokens.length === 0) traversalSteps.push("El mensaje no trae palabras con significado; solo se usan las reglas críticas.");
  traversalSteps.push(
    `Se inyectan ${selected.length} nodo(s): ${matched} por parecido, ${alwaysOn} crítico(s) siempre activos (${used} tokens aprox.)`,
  );

  return {
    matchedPath: categories.length ? categories[0][0].split(" › ") : [],
    selectedNodes: selected,
    traversalSteps,
    estimatedTokens: used,
  };
}

/** El bloque de texto que se antepone al mensaje del modelo. Corto y marcado como referencia. */
export function formatForPrompt(result) {
  if (!result.selectedNodes.length) return null;
  const lines = result.selectedNodes.map(
    (node) => `- [${node.semanticPath.join(" › ")}] ${node.title}: ${node.summary}`,
  );
  return [
    "CONTEXTO GUARDADO (referencia de lo que la persona decidió antes; no es un mensaje nuevo que requiera respuesta):",
    ...lines,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Grafo (lo usa el panel web con d3)
// ---------------------------------------------------------------------------

const slug = (text) => normalizeText(text).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const shorten = (text, max) => (text.length > max ? `${text.slice(0, max - 2).trim()}…` : text);

/**
 * Nodos y enlaces para dibujar el grafo: dominio → categoría → nodo, más "puentes" entre nodos
 * que comparten al menos dos palabras con significado (aunque vivan en carpetas distintas).
 */
export function buildGraph(nodes) {
  const graphNodes = [];
  const graphLinks = [];
  const hubs = new Map();
  const clusters = new Map();

  for (const node of nodes) {
    const [domain, category] = node.semanticPath;
    if (!hubs.has(domain)) {
      const id = `hub-${slug(domain)}`;
      hubs.set(domain, id);
      const members = nodes.filter((n) => n.semanticPath[0] === domain);
      graphNodes.push({
        id,
        label: domain,
        shortLabel: shorten(domain, 24),
        kind: "domain-hub",
        domain,
        semanticPath: [domain],
        parentClusterId: null,
        childCount: members.length,
        priority: "critical",
        radius: 22,
        estimatedTokens: members.reduce((sum, n) => sum + n.estimatedTokens, 0),
        sourceTool: "as.read.context_tree",
        createdAt: "",
        summary: `Dominio con ${members.length} nodo(s) de contexto.`,
      });
    }
    const clusterKey = `${domain}::${category}`;
    if (!clusters.has(clusterKey)) {
      const id = `cluster-${slug(clusterKey)}`;
      clusters.set(clusterKey, id);
      const members = nodes.filter((n) => n.semanticPath[0] === domain && n.semanticPath[1] === category);
      graphNodes.push({
        id,
        label: category,
        shortLabel: shorten(category, 24),
        kind: "path-cluster",
        domain,
        semanticPath: [domain, category],
        parentClusterId: hubs.get(domain),
        childCount: members.length,
        priority: "high",
        radius: 17,
        estimatedTokens: members.reduce((sum, n) => sum + n.estimatedTokens, 0),
        sourceTool: "as.read.context_tree",
        createdAt: "",
        summary: `${domain} › ${category}: ${members.length} nodo(s).`,
      });
      graphLinks.push({
        id: `link-${hubs.get(domain)}-${id}`,
        source: hubs.get(domain),
        target: id,
        kind: "folder-hierarchy",
        relationshipLabel: "Dominio → categoría",
        reason: `"${domain}" contiene la categoría "${category}".`,
        strength: 0.85,
      });
    }
  }

  for (const node of nodes) {
    const parent = clusters.get(`${node.semanticPath[0]}::${node.semanticPath[1]}`);
    graphNodes.push({
      id: node.id,
      label: node.title,
      shortLabel: shorten(node.title, 28),
      kind: "context-node",
      domain: node.semanticPath[0],
      semanticPath: node.semanticPath,
      parentClusterId: parent,
      childCount: 0,
      priority: node.priority,
      radius: node.priority === "critical" ? 15 : node.priority === "high" ? 13.5 : 12,
      estimatedTokens: node.estimatedTokens,
      sourceTool: node.sourceTool,
      createdAt: node.createdAt,
      summary: node.summary,
    });
    graphLinks.push({
      id: `link-${parent}-${node.id}`,
      source: parent,
      target: node.id,
      kind: "folder-hierarchy",
      relationshipLabel: node.semanticPath.slice(1).join(" › "),
      reason: `Guardado en ${node.semanticPath.join(" › ")}.`,
      strength: 0.8,
    });
  }

  const wordsOf = nodes.map((node) => new Set(significantWords(`${node.title} ${node.summary}`, 5)));
  for (let i = 0; i < nodes.length; i++) {
    for (let j = i + 1; j < nodes.length; j++) {
      const shared = [...wordsOf[i]].filter((word) => wordsOf[j].has(word));
      if (shared.length < 2) continue;
      const sameDomain = nodes[i].semanticPath[0] === nodes[j].semanticPath[0];
      graphLinks.push({
        id: `link-sem-${nodes[i].id}-${nodes[j].id}`,
        source: nodes[i].id,
        target: nodes[j].id,
        kind: "cross-semantic",
        relationshipLabel: `Comparten: ${shared.slice(0, 3).join(", ")}`,
        reason: `Los dos nodos hablan de ${shared.slice(0, 4).join(", ")}.`,
        strength: Math.min(0.95, (sameDomain ? 0.55 : 0.7) + shared.length * 0.05),
      });
    }
  }

  return { graphNodes, graphLinks };
}

// ---------------------------------------------------------------------------
// Intercambio (export/import JSON del panel y de la CLI)
// ---------------------------------------------------------------------------

export function exportDocument(nodes, now = new Date()) {
  return { schema: SCHEMA, exportedAt: now.toISOString(), nodes };
}

/** Lee un documento exportado y rechaza lo que no cumpla, en vez de mezclar datos dudosos. */
export function parseDocument(value) {
  const data = typeof value === "string" ? JSON.parse(value) : value;
  if (!data || data.schema !== SCHEMA || !Array.isArray(data.nodes)) {
    throw new ContextError(`Documento no reconocido; se esperaba ${SCHEMA}.`);
  }
  if (data.nodes.length > LIMITS.maxNodes) throw new ContextError(`Hay más de ${LIMITS.maxNodes} nodos.`);
  return data.nodes.map((node) => createNode(node, { id: node.id }));
}

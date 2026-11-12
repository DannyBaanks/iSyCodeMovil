/**
 * Dónde viven los nodos del contexto en la computadora.
 *
 * Un solo JSON en ~/.iyscodemovil/semantic-context.json, escrito de forma atómica (archivo
 * temporal + rename) y con permisos 0600: el contexto puede traer preferencias personales y
 * no tiene por qué leerlo otro usuario de la máquina. Si el archivo se corrompe, no lo borramos:
 * lo apartamos como .corrupt para que la persona pueda recuperarlo.
 */
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { LIMITS, SCHEMA, ContextError, createNode, exportDocument, nodeKey, parseDocument } from "./semantic-context.mjs";

export function defaultContextFile(env = process.env) {
  return env.ISY_CONTEXT_FILE || path.join(os.homedir(), ".iyscodemovil", "semantic-context.json");
}

export function createContextStore({ file = defaultContextFile(), now = () => new Date() } = {}) {
  let writing = Promise.resolve();

  async function load() {
    let raw;
    try {
      raw = await readFile(file, "utf8");
    } catch (error) {
      if (error.code === "ENOENT") return [];
      throw error;
    }
    try {
      return parseDocument(raw);
    } catch (error) {
      await rename(file, `${file}.corrupt`).catch(() => {});
      throw new ContextError(`El archivo de contexto estaba dañado y se apartó en ${file}.corrupt (${error.message}).`);
    }
  }

  async function save(nodes) {
    const body = JSON.stringify(exportDocument(nodes, now()), null, 2);
    const temp = `${file}.${process.pid}.tmp`;
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    await writeFile(temp, body, { mode: 0o600 });
    await rename(temp, file);
    await chmod(file, 0o600).catch(() => {});
  }

  /** Las escrituras se encolan: dos peticiones a la vez no se pisan el archivo. */
  function mutate(change) {
    const run = writing.then(async () => {
      const nodes = await load();
      const result = await change(nodes);
      await save(result.nodes);
      return result.value;
    });
    writing = run.catch(() => {});
    return run;
  }

  return {
    file,
    list: load,

    /** Guarda un nodo; si ya existe uno con el mismo título en la misma ruta, lo actualiza. */
    upsert: (input) =>
      mutate((nodes) => {
        const created = createNode(input, { now: now() });
        const key = nodeKey(created);
        const index = nodes.findIndex((node) => nodeKey(node) === key);
        if (index >= 0) {
          const updated = { ...created, id: nodes[index].id, createdAt: nodes[index].createdAt };
          nodes[index] = updated;
          return { nodes, value: { node: updated, created: false } };
        }
        if (nodes.length >= LIMITS.maxNodes) {
          throw new ContextError(`Ya hay ${LIMITS.maxNodes} nodos guardados; borra alguno antes de agregar más.`);
        }
        nodes.push(created);
        return { nodes, value: { node: created, created: true } };
      }),

    remove: (id) =>
      mutate((nodes) => {
        const next = nodes.filter((node) => node.id !== id);
        return { nodes: next, value: next.length !== nodes.length };
      }),

    /** Mezcla un documento exportado (de la app móvil, por ejemplo) sin duplicar lo que ya hay. */
    importDocument: (value) =>
      mutate((nodes) => {
        const incoming = parseDocument(value);
        const known = new Set(nodes.map(nodeKey));
        let added = 0;
        for (const node of incoming) {
          if (known.has(nodeKey(node))) continue;
          if (nodes.length >= LIMITS.maxNodes) break;
          nodes.push(node);
          known.add(nodeKey(node));
          added += 1;
        }
        return { nodes, value: { added, skipped: incoming.length - added } };
      }),

    exportDocument: async () => exportDocument(await load(), now()),
  };
}

export { SCHEMA };

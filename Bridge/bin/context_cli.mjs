/**
 * `iyscodemovil context ...`: el árbol de contexto desde la terminal.
 *
 *   context list                       carpetas y nodos guardados
 *   context search <texto>             búsqueda tolerante a erratas
 *   context show <texto del mensaje>   qué se inyectaría al modelo para ese mensaje
 *   context add <dominio> <categoría> <tema> <título> <resumen> [--priority critical]
 *   context export [archivo]           JSON isycode.semantic-context.v1 (sale por stdout si no hay archivo)
 *   context import <archivo>           mezcla un export (de otra compu o del panel)
 *   context remove <id>
 */
import { readFile, writeFile } from "node:fs/promises";
import { createContextStore } from "../workspace/context-store.mjs";
import { ContextError, buildTree, formatForPrompt, retrieve, searchNodes } from "../workspace/semantic-context.mjs";

const USAGE = "uso: iyscodemovil context list | search <texto> | show <mensaje> | add <dominio> <categoría> <tema> <título> <resumen> [--priority normal|high|critical] | export [archivo] | import <archivo> | remove <id>";

function printTree(folders, out, indent = "") {
  for (const folder of folders) {
    out(`${indent}${folder.name}  (${folder.totalDescendantNodes} nodo(s), ~${folder.totalEstimatedTokens} tokens)`);
    for (const node of folder.nodes) out(`${indent}  • [${node.priority}] ${node.title}  ${node.id}`);
    printTree(folder.subfolders, out, `${indent}  `);
  }
}

export async function runContextCommand(args, { store = createContextStore(), out = console.log, err = console.error } = {}) {
  const [command, ...rest] = args;
  try {
    switch (command) {
      case "list": {
        const nodes = await store.list();
        if (!nodes.length) out("Todavía no hay contexto guardado.");
        else printTree(buildTree(nodes), out);
        return 0;
      }
      case "search": {
        const matches = searchNodes(await store.list(), rest.join(" "));
        if (!matches.length) out("Sin coincidencias.");
        for (const { node, score } of matches) out(`${score}\t${node.semanticPath.join(" › ")}\t${node.title}\t${node.id}`);
        return 0;
      }
      case "show": {
        const result = retrieve(await store.list(), rest.join(" "));
        for (const step of result.traversalSteps) out(step);
        out("");
        out(formatForPrompt(result) ?? "(nada que inyectar)");
        return 0;
      }
      case "add": {
        const priorityAt = rest.indexOf("--priority");
        const priority = priorityAt >= 0 ? rest[priorityAt + 1] : "normal";
        const positional = priorityAt >= 0 ? rest.filter((_, i) => i !== priorityAt && i !== priorityAt + 1) : rest;
        const [domain, category, topic, title, summary] = positional;
        if (positional.length !== 5) throw new ContextError(USAGE);
        const { node, created } = await store.upsert({ title, summary, semanticPath: [domain, category, topic], priority });
        out(`${created ? "Guardado" : "Actualizado"}: ${node.id}`);
        return 0;
      }
      case "export": {
        const body = JSON.stringify(await store.exportDocument(), null, 2);
        if (rest[0]) {
          await writeFile(rest[0], body, { mode: 0o600 });
          out(`Exportado a ${rest[0]}`);
        } else out(body);
        return 0;
      }
      case "import": {
        if (!rest[0]) throw new ContextError(USAGE);
        const { added, skipped } = await store.importDocument(await readFile(rest[0], "utf8"));
        out(`Importados ${added}, ya existían ${skipped}.`);
        return 0;
      }
      case "remove": {
        if (!rest[0]) throw new ContextError(USAGE);
        const removed = await store.remove(rest[0]);
        out(removed ? "Borrado." : "No existe un nodo con ese id.");
        return removed ? 0 : 1;
      }
      default:
        err(USAGE);
        return 2;
    }
  } catch (error) {
    err(error instanceof ContextError || error instanceof SyntaxError ? error.message : `No se pudo completar: ${error.message}`);
    return 1;
  }
}

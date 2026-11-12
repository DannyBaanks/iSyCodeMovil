import React, { useEffect, useMemo, useRef, useState } from 'react';
import * as d3 from 'd3';
import {
  Network,
  RotateCcw,
  ZoomIn,
  ZoomOut,
  Lock,
  Unlock,
  Sparkles,
  ArrowRight,
  GitBranch,
  Layers,
  Clock,
  Tag,
  FolderTree,
} from 'lucide-react';
import {
  SemanticContextNode,
  SemanticGraphNode,
  SemanticGraphLink,
  buildGraph as buildSemanticDependencyGraph,
} from '../lib/semantic';

interface SimNode extends SemanticGraphNode, d3.SimulationNodeDatum {
  x?: number;
  y?: number;
  fx?: number | null;
  fy?: number | null;
}

interface SimLink extends d3.SimulationLinkDatum<SimNode> {
  id: string;
  source: SimNode | string;
  target: SimNode | string;
  kind: 'folder-hierarchy' | 'cross-semantic';
  relationshipLabel: string;
  reason: string;
  strength: number;
}

interface SemanticObsidianGraphProps {
  contextNodes: SemanticContextNode[];
  developerMode: boolean;
  selectedExternalNodeId?: string | null;
  onSelectNodeChange?: (nodeId: string) => void;
  onSelectClusterQuery: (queryText: string) => void;
}

const PALETTES = [
  { fill: '#2563eb', clusterFill: '#1d4ed8', stroke: '#93c5fd', badgeBg: 'bg-blue-500/15 text-blue-600 dark:text-blue-400' },
  { fill: '#059669', clusterFill: '#047857', stroke: '#6ee7b7', badgeBg: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400' },
  { fill: '#d97706', clusterFill: '#b45309', stroke: '#fcd34d', badgeBg: 'bg-amber-500/15 text-amber-600 dark:text-amber-400' },
  { fill: '#4f46e5', clusterFill: '#4338ca', stroke: '#a5b4fc', badgeBg: 'bg-indigo-500/15 text-indigo-600 dark:text-indigo-400' },
  { fill: '#db2777', clusterFill: '#be185d', stroke: '#f9a8d4', badgeBg: 'bg-pink-500/15 text-pink-600 dark:text-pink-400' },
  { fill: '#0891b2', clusterFill: '#0e7490', stroke: '#67e8f9', badgeBg: 'bg-cyan-500/15 text-cyan-600 dark:text-cyan-400' },
];

/** Cada dominio recibe siempre el mismo color (según su nombre), sin depender de nombres fijos. */
function getDomainPalette(domain: string) {
  let hash = 0;
  for (const ch of domain) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  return { ...PALETTES[hash % PALETTES.length], text: domain };
}

export const SemanticObsidianGraph: React.FC<SemanticObsidianGraphProps> = ({
  contextNodes,
  developerMode,
  selectedExternalNodeId,
  onSelectNodeChange,
  onSelectClusterQuery,
}) => {
  const WIDTH = 780;
  const HEIGHT = 450;

  const rawGraph = useMemo(
    () => buildSemanticDependencyGraph(contextNodes),
    [contextNodes]
  );

  // Los dominios se reparten en una elipse: no hay nombres de dominio escritos a mano.
  const domains = useMemo(
    () => Array.from(new Set(rawGraph.graphNodes.map((n) => n.domain))),
    [rawGraph]
  );
  const anchorFor = (domain: string) => {
    const index = domains.indexOf(domain);
    if (index < 0 || domains.length <= 1) return { x: WIDTH / 2, y: HEIGHT / 2 };
    const angle = (index / domains.length) * Math.PI * 2 - Math.PI / 2;
    return { x: WIDTH / 2 + Math.cos(angle) * 205, y: HEIGHT / 2 + Math.sin(angle) * 120 };
  };

  const [linkFilter, setLinkFilter] = useState<'all' | 'cross-only'>('all');
  const [pinOnDrag, setPinOnDrag] = useState<boolean>(true);
  const [zoomTransform, setZoomTransform] = useState<{ k: number; x: number; y: number }>({
    k: 1,
    x: 0,
    y: 0,
  });
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(() =>
    contextNodes[0]?.id || null
  );
  const [hoveredNodeId, setHoveredNodeId] = useState<string | null>(null);

  const [simNodes, setSimNodes] = useState<SimNode[]>([]);
  const [simLinks, setSimLinks] = useState<SimLink[]>([]);

  const simulationRef = useRef<d3.Simulation<SimNode, SimLink> | null>(null);
  const svgRef = useRef<SVGSVGElement | null>(null);
  const zoomBehaviorRef = useRef<d3.ZoomBehavior<SVGSVGElement, unknown> | null>(null);
  const draggingNodeIdRef = useRef<string | null>(null);

  // Sync external node selection from the Context Tree folder explorer if provided
  useEffect(() => {
    if (
      selectedExternalNodeId &&
      rawGraph.graphNodes.some((n) => n.id === selectedExternalNodeId)
    ) {
      setSelectedNodeId(selectedExternalNodeId);
    }
  }, [selectedExternalNodeId, rawGraph]);

  const selectNode = (nodeId: string) => {
    setSelectedNodeId(nodeId);
    if (onSelectNodeChange) {
      onSelectNodeChange(nodeId);
    }
  };

  // Attach D3 zoom & pan behavior to the SVG canvas
  useEffect(() => {
    const svgEl = svgRef.current;
    if (!svgEl) return;

    const zoomBehavior = d3
      .zoom<SVGSVGElement, unknown>()
      .scaleExtent([0.65, 2.2])
      .filter((event) => {
        // Prevent canvas pan when user is dragging a specific node circle
        if (draggingNodeIdRef.current) return false;
        const target = event.target as Element | null;
        if (target && target.closest('[data-graph-node="true"]') && event.type !== 'wheel') {
          return false;
        }
        return true;
      })
      .on('zoom', (event) => {
        setZoomTransform({
          k: Number(event.transform.k.toFixed(3)),
          x: Number(event.transform.x.toFixed(1)),
          y: Number(event.transform.y.toFixed(1)),
        });
      });

    d3.select(svgEl).call(zoomBehavior);
    zoomBehaviorRef.current = zoomBehavior;

    return () => {
      d3.select(svgEl).on('.zoom', null);
    };
  }, []);

  // Initialize and run D3 force simulation with parent-child semantic path clustering
  useEffect(() => {
    const nodesCopy: SimNode[] = rawGraph.graphNodes.map((n, idx) => {
      const anchor = anchorFor(n.domain);
      const angle = (idx / Math.max(1, rawGraph.graphNodes.length)) * Math.PI * 2;
      const dist =
        n.kind === 'domain-hub' ? 15 : n.kind === 'path-cluster' ? 68 : 118;
      return {
        ...n,
        x: anchor.x + Math.cos(angle) * dist,
        y: anchor.y + Math.sin(angle) * dist,
      };
    });

    const filteredLinksSource: SemanticGraphLink[] =
      linkFilter === 'cross-only'
        ? rawGraph.graphLinks.filter((l) => l.kind === 'cross-semantic')
        : rawGraph.graphLinks;

    const linksCopy: SimLink[] = filteredLinksSource.map((l) => ({
      ...l,
    }));

    const simulation = d3
      .forceSimulation<SimNode>(nodesCopy)
      .force(
        'link',
        d3
          .forceLink<SimNode, SimLink>(linksCopy)
          .id((d) => d.id)
          .distance((l) => {
            if (l.kind === 'cross-semantic') return 165;
            return l.relationshipLabel.includes('Nivel 1 → 2') ? 76 : 72;
          })
          .strength((l) => (l.kind === 'folder-hierarchy' ? 0.72 : 0.28))
      )
      .force(
        'charge',
        d3
          .forceManyBody<SimNode>()
          .strength((d) =>
            d.kind === 'domain-hub'
              ? -380
              : d.kind === 'path-cluster'
              ? -270
              : -230
          )
      )
      .force('center', d3.forceCenter(WIDTH / 2, HEIGHT / 2))
      .force(
        'collide',
        d3
          .forceCollide<SimNode>()
          .radius((d) => d.radius + 32)
          .iterations(3)
      )
      .force(
        'x',
        d3
          .forceX<SimNode>((d) => anchorFor(d.domain).x)
          .strength(0.14)
      )
      .force(
        'y',
        d3
          .forceY<SimNode>((d) => anchorFor(d.domain).y)
          .strength(0.14)
      );

    simulation.on('tick', () => {
      for (const node of nodesCopy) {
        const pad = node.radius + 26;
        node.x = Math.max(pad, Math.min(WIDTH - pad, node.x ?? WIDTH / 2));
        node.y = Math.max(pad, Math.min(HEIGHT - pad, node.y ?? HEIGHT / 2));
      }
      setSimNodes([...nodesCopy]);
      setSimLinks([...linksCopy]);
    });

    simulationRef.current = simulation;

    return () => {
      simulation.stop();
    };
  }, [rawGraph, linkFilter]);

  const handleZoomBy = (factor: number) => {
    const svgEl = svgRef.current;
    const zb = zoomBehaviorRef.current;
    if (svgEl && zb) {
      d3.select(svgEl).transition().duration(180).call(zb.scaleBy, factor);
    } else {
      setZoomTransform((prev) => ({
        ...prev,
        k: Math.max(0.65, Math.min(2.2, Number((prev.k * factor).toFixed(2)))),
      }));
    }
  };

  const handleReorganizeGraph = () => {
    const sim = simulationRef.current;
    if (sim) {
      for (const n of sim.nodes()) {
        n.fx = null;
        n.fy = null;
      }
      sim.alpha(0.95).restart();
    }
    const svgEl = svgRef.current;
    const zb = zoomBehaviorRef.current;
    if (svgEl && zb) {
      d3.select(svgEl).transition().duration(220).call(zb.transform, d3.zoomIdentity);
    } else {
      setZoomTransform({ k: 1, x: 0, y: 0 });
    }
  };

  // Convert client pointer coordinates to SVG world coordinates accounting for D3 zoom/pan transform
  const clientToGraphCoords = (clientX: number, clientY: number) => {
    const svg = svgRef.current;
    if (!svg) return { x: WIDTH / 2, y: HEIGHT / 2 };
    const rect = svg.getBoundingClientRect();
    const svgX = ((clientX - rect.left) / Math.max(1, rect.width)) * WIDTH;
    const svgY = ((clientY - rect.top) / Math.max(1, rect.height)) * HEIGHT;
    return {
      x: (svgX - zoomTransform.x) / zoomTransform.k,
      y: (svgY - zoomTransform.y) / zoomTransform.k,
    };
  };

  const handleNodePointerDown = (
    e: React.PointerEvent<SVGGElement>,
    nodeId: string
  ) => {
    e.stopPropagation();
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    draggingNodeIdRef.current = nodeId;
    selectNode(nodeId);

    const sim = simulationRef.current;
    if (!sim) return;
    sim.alphaTarget(0.35).restart();

    const targetNode = sim.nodes().find((n) => n.id === nodeId);
    if (targetNode) {
      const coords = clientToGraphCoords(e.clientX, e.clientY);
      targetNode.fx = coords.x;
      targetNode.fy = coords.y;
    }
  };

  const handleSvgPointerMove = (e: React.PointerEvent<SVGSVGElement>) => {
    const activeId = draggingNodeIdRef.current;
    if (!activeId) return;
    const sim = simulationRef.current;
    if (!sim) return;
    const targetNode = sim.nodes().find((n) => n.id === activeId);
    if (!targetNode) return;

    const coords = clientToGraphCoords(e.clientX, e.clientY);
    const pad = targetNode.radius + 20;
    targetNode.fx = Math.max(pad, Math.min(WIDTH - pad, coords.x));
    targetNode.fy = Math.max(pad, Math.min(HEIGHT - pad, coords.y));
  };

  const handleSvgPointerUp = () => {
    const activeId = draggingNodeIdRef.current;
    if (!activeId) return;
    draggingNodeIdRef.current = null;

    const sim = simulationRef.current;
    if (!sim) return;
    sim.alphaTarget(0);

    if (!pinOnDrag) {
      const targetNode = sim.nodes().find((n) => n.id === activeId);
      if (targetNode) {
        targetNode.fx = null;
        targetNode.fy = null;
      }
    }
  };

  const focusNodeId = hoveredNodeId || selectedNodeId;

  // Compute 1st-degree neighborhood + parent/child cluster members for Obsidian spotlight effect
  const connectedNodeIds = useMemo(() => {
    const set = new Set<string>();
    if (!focusNodeId) return set;
    set.add(focusNodeId);
    for (const l of rawGraph.graphLinks) {
      if (l.source === focusNodeId) set.add(l.target);
      if (l.target === focusNodeId) set.add(l.source);
    }
    return set;
  }, [focusNodeId, rawGraph]);

  // Compute Parent-Child Semantic Cluster Halos (bounding circles around each path-cluster and its children)
  const clusterHalos = useMemo(() => {
    const clusters = simNodes.filter((n) => n.kind === 'path-cluster');
    return clusters
      .map((clusterNode) => {
        if (clusterNode.x === undefined || clusterNode.y === undefined) return null;
        const memberNodes = simNodes.filter(
          (n) => n.id === clusterNode.id || n.parentClusterId === clusterNode.id
        );
        const validMembers = memberNodes.filter(
          (m) => m.x !== undefined && m.y !== undefined
        );
        if (validMembers.length === 0) return null;

        const cx =
          validMembers.reduce((sum, m) => sum + (m.x ?? 0), 0) / validMembers.length;
        const cy =
          validMembers.reduce((sum, m) => sum + (m.y ?? 0), 0) / validMembers.length;
        let maxDist = 36;
        for (const m of validMembers) {
          const d = Math.hypot((m.x ?? cx) - cx, (m.y ?? cy) - cy) + m.radius + 18;
          if (d > maxDist) maxDist = d;
        }

        return {
          id: `halo-${clusterNode.id}`,
          clusterId: clusterNode.id,
          label: clusterNode.label,
          domain: clusterNode.domain,
          cx,
          cy,
          r: Math.min(130, maxDist),
        };
      })
      .filter(Boolean) as Array<{
      id: string;
      clusterId: string;
      label: string;
      domain: string;
      cx: number;
      cy: number;
      r: number;
    }>;
  }, [simNodes]);

  const activeNode = useMemo(
    () =>
      rawGraph.graphNodes.find((n) => n.id === (selectedNodeId || hoveredNodeId)) ||
      rawGraph.graphNodes.find((n) => n.kind === 'context-node') ||
      rawGraph.graphNodes[0],
    [rawGraph, selectedNodeId, hoveredNodeId]
  );

  const parentClusterNode = useMemo(() => {
    if (!activeNode?.parentClusterId) return null;
    return (
      rawGraph.graphNodes.find((n) => n.id === activeNode.parentClusterId) || null
    );
  }, [activeNode, rawGraph]);

  const childClusterNodes = useMemo(() => {
    if (!activeNode) return [];
    return rawGraph.graphNodes.filter((n) => n.parentClusterId === activeNode.id);
  }, [activeNode, rawGraph]);

  const activeNodeConnections = useMemo(() => {
    if (!activeNode) return [];
    return rawGraph.graphLinks
      .filter((l) => l.source === activeNode.id || l.target === activeNode.id)
      .map((l) => {
        const otherId = l.source === activeNode.id ? l.target : l.source;
        const otherNode = rawGraph.graphNodes.find((n) => n.id === otherId);
        return {
          link: l,
          otherNode,
        };
      })
      .filter((item) => Boolean(item.otherNode));
  }, [activeNode, rawGraph]);

  const crossSemanticCount = rawGraph.graphLinks.filter(
    (l) => l.kind === 'cross-semantic'
  ).length;
  const clusterCount = rawGraph.graphNodes.filter(
    (n) => n.kind === 'domain-hub' || n.kind === 'path-cluster'
  ).length;

  return (
    <section
      aria-label="Grafo Semántico Interactivo estilo Obsidian"
      className="rounded-2xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden"
    >
      {/* Top Header & Interactive Controls Bar */}
      <div className="px-5 py-4 border-b border-slate-200 dark:border-slate-800 flex flex-col lg:flex-row lg:items-center justify-between gap-4">
        <div className="space-y-1">
          <div className="flex items-center gap-2 text-xs font-mono text-blue-600 dark:text-blue-400">
            <Network className="w-4 h-4 shrink-0" />
            <span>
              {developerMode
                ? `D3 Force-Directed Graph · ${clusterCount} Clústeres Padre-Hijo & ${crossSemanticCount} Puentes Semánticos`
                : 'Grafo Interactivo de Nodos y Clústeres Semánticos (Estilo Obsidian)'}
            </span>
          </div>
          <h3 className="text-base font-bold text-slate-900 dark:text-slate-100">
            Clústeres Padre-Hijo por Ruta Semántica y Conexiones entre Nodos
          </h3>
          <p className="text-xs text-slate-500 dark:text-slate-400">
            Haz zoom con la rueda del ratón o botones, arrastra cualquier círculo para reacomodar tu constelación y haz clic en un nodo para inspeccionar su{' '}
            <span className="font-semibold text-slate-700 dark:text-slate-200">
              resumen y metadatos completos
            </span>{' '}
            en el panel lateral.
          </p>
        </div>

        {/* Graph Toolbar */}
        <div className="flex flex-wrap items-center gap-2 shrink-0">
          <div
            role="group"
            aria-label="Filtro de enlaces del grafo"
            className="flex items-center p-1 rounded-xl bg-slate-100 dark:bg-slate-950 border border-slate-200 dark:border-slate-800 text-xs"
          >
            <button
              type="button"
              onClick={() => setLinkFilter('all')}
              className={`px-2.5 py-1 rounded-lg font-medium transition-colors whitespace-nowrap ${
                linkFilter === 'all'
                  ? 'bg-blue-600 text-white'
                  : 'text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-200'
              }`}
            >
              Clústeres + Puentes
            </button>
            <button
              type="button"
              onClick={() => setLinkFilter('cross-only')}
              className={`px-2.5 py-1 rounded-lg font-medium transition-colors whitespace-nowrap ${
                linkFilter === 'cross-only'
                  ? 'bg-blue-600 text-white'
                  : 'text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-200'
              }`}
            >
              Solo Puentes ({crossSemanticCount})
            </button>
          </div>

          <button
            type="button"
            onClick={() => setPinOnDrag(!pinOnDrag)}
            title="Fijar posición al soltar un nodo arrastrado"
            className={`inline-flex items-center gap-1.5 px-2.5 py-1.5 text-xs font-medium rounded-xl border transition-colors whitespace-nowrap ${
              pinOnDrag
                ? 'bg-blue-50 dark:bg-slate-800 border-blue-200 dark:border-slate-700 text-blue-600 dark:text-blue-400'
                : 'bg-white dark:bg-slate-950 border-slate-200 dark:border-slate-800 text-slate-600 dark:text-slate-400'
            }`}
          >
            {pinOnDrag ? <Lock className="w-3.5 h-3.5" /> : <Unlock className="w-3.5 h-3.5" />}
            <span>{pinOnDrag ? 'Fijar al arrastrar' : 'Física libre'}</span>
          </button>

          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={() => handleZoomBy(1.2)}
              aria-label="Acercar grafo"
              className="p-1.5 rounded-lg border border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950 text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800"
            >
              <ZoomIn className="w-3.5 h-3.5" />
            </button>
            <span className="px-1.5 text-[11px] font-mono text-slate-600 dark:text-slate-400 tabular-nums">
              {Math.round(zoomTransform.k * 100)}%
            </span>
            <button
              type="button"
              onClick={() => handleZoomBy(0.84)}
              aria-label="Alejar grafo"
              className="p-1.5 rounded-lg border border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950 text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800"
            >
              <ZoomOut className="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              onClick={handleReorganizeGraph}
              className="inline-flex items-center gap-1 px-2.5 py-1.5 text-xs font-medium rounded-xl border border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950 text-slate-700 dark:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors whitespace-nowrap"
            >
              <RotateCcw className="w-3.5 h-3.5" />
              <span>Reorganizar</span>
            </button>
          </div>
        </div>
      </div>

      {/* Main Split Body: Left Obsidian Canvas (7 cols) + Right Node Summary & Metadata Sidebar (5 cols) */}
      <div className="grid grid-cols-1 lg:grid-cols-12">
        {/* Obsidian-Style Interactive SVG Canvas */}
        <div className="lg:col-span-7 relative bg-slate-950 text-slate-100 border-b lg:border-b-0 lg:border-r border-slate-800 select-none flex flex-col justify-between">
          {/* Top-Left Legend Overlay */}
          <div className="absolute top-3 left-3 z-10 flex flex-wrap items-center gap-2 pointer-events-none">
            {domains.map((dom) => {
              const pal = getDomainPalette(dom);
              return (
                <span
                  key={dom}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-slate-900/90 border border-slate-800 text-[11px] text-slate-200 backdrop-blur-xs"
                >
                  <span
                    className="w-2.5 h-2.5 rounded-full shrink-0"
                    style={{ backgroundColor: pal.fill }}
                  />
                  <span>{dom}</span>
                </span>
              );
            })}
          </div>

          <svg
            ref={svgRef}
            data-testid="semantic-d3-force-graph"
            viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
            onPointerMove={handleSvgPointerMove}
            onPointerUp={handleSvgPointerUp}
            onPointerLeave={handleSvgPointerUp}
            className="w-full h-[420px] sm:h-[460px] block cursor-grab active:cursor-grabbing touch-none"
          >
            <defs>
              <pattern
                id="obsidian-grid"
                width="28"
                height="28"
                patternUnits="userSpaceOnUse"
              >
                <circle cx="2" cy="2" r="1" fill="rgba(148, 163, 184, 0.14)" />
              </pattern>
            </defs>

            <rect width={WIDTH} height={HEIGHT} fill="url(#obsidian-grid)" />

            <g
              transform={`translate(${zoomTransform.x}, ${zoomTransform.y}) scale(${zoomTransform.k})`}
            >
              {/* 1. Render Parent-Child Semantic Path Cluster Halos */}
              {clusterHalos.map((halo) => {
                const pal = getDomainPalette(halo.domain);
                const isFocusedCluster =
                  focusNodeId === halo.clusterId ||
                  activeNode?.parentClusterId === halo.clusterId;
                return (
                  <g
                    key={halo.id}
                    transform={`translate(${halo.cx}, ${halo.cy})`}
                    className="pointer-events-none"
                  >
                    <circle
                      r={halo.r}
                      fill={pal.fill}
                      fillOpacity={isFocusedCluster ? 0.11 : 0.05}
                      stroke={pal.stroke}
                      strokeOpacity={isFocusedCluster ? 0.45 : 0.2}
                      strokeWidth={isFocusedCluster ? 1.5 : 1}
                      strokeDasharray="6 4"
                    />
                  </g>
                );
              })}

              {/* 2. Render Edges (Parent-Child Cluster Links + Cross-Semantic Bridges) */}
              {simLinks.map((link) => {
                const sourceNode =
                  typeof link.source === 'object' ? link.source : null;
                const targetNode =
                  typeof link.target === 'object' ? link.target : null;
                if (
                  !sourceNode ||
                  !targetNode ||
                  sourceNode.x === undefined ||
                  sourceNode.y === undefined ||
                  targetNode.x === undefined ||
                  targetNode.y === undefined
                ) {
                  return null;
                }

                const isHighlighted =
                  !focusNodeId ||
                  sourceNode.id === focusNodeId ||
                  targetNode.id === focusNodeId;

                const isCross = link.kind === 'cross-semantic';
                const midX = (sourceNode.x + targetNode.x) / 2;
                const midY = (sourceNode.y + targetNode.y) / 2;

                return (
                  <g
                    key={link.id}
                    opacity={isHighlighted ? 1 : 0.18}
                    className="transition-opacity duration-200"
                  >
                    <line
                      x1={sourceNode.x}
                      y1={sourceNode.y}
                      x2={targetNode.x}
                      y2={targetNode.y}
                      stroke={isCross ? '#38bdf8' : '#64748b'}
                      strokeWidth={isCross ? 2.2 : 1.5}
                      strokeDasharray={isCross ? '5 4' : undefined}
                    />
                    {/* Show bridge badge on cross-semantic links when hovering or filtering bridges */}
                    {isCross &&
                      isHighlighted &&
                      (Boolean(hoveredNodeId) || linkFilter === 'cross-only') && (
                        <g transform={`translate(${midX}, ${midY})`}>
                          <rect
                            x={-68}
                            y={-8.5}
                            width={136}
                            height={17}
                            rx={5}
                            fill="rgba(15, 23, 42, 0.92)"
                            stroke="rgba(56, 189, 248, 0.45)"
                            strokeWidth={1}
                          />
                          <text
                            textAnchor="middle"
                            dy="3"
                            fill="#bae6fd"
                            fontSize="9"
                            fontFamily="monospace"
                          >
                            {link.relationshipLabel.slice(0, 22)}
                          </text>
                        </g>
                      )}
                  </g>
                );
              })}

              {/* 3. Render Interconnected Circles (Domain Hubs, Path Clusters & Leaf Context Nodes) */}
              {simNodes.map((node) => {
                if (node.x === undefined || node.y === undefined) return null;
                const palette = getDomainPalette(node.domain);
                const isSelected = node.id === activeNode?.id;
                const isInNeighborhood =
                  !focusNodeId || connectedNodeIds.has(node.id);
                const isPinned = node.fx !== null && node.fx !== undefined;

                const circleFill =
                  node.kind === 'domain-hub'
                    ? palette.fill
                    : node.kind === 'path-cluster'
                    ? palette.clusterFill
                    : palette.fill;

                return (
                  <g
                    key={node.id}
                    data-graph-node="true"
                    role="button"
                    tabIndex={0}
                    aria-label={`Nodo semántico: ${node.label}`}
                    transform={`translate(${node.x}, ${node.y})`}
                    opacity={isInNeighborhood ? 1 : 0.25}
                    onPointerDown={(e) => handleNodePointerDown(e, node.id)}
                    onPointerEnter={() => setHoveredNodeId(node.id)}
                    onPointerLeave={() => setHoveredNodeId(null)}
                    onClick={() => selectNode(node.id)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        selectNode(node.id);
                      }
                    }}
                    className="cursor-pointer transition-opacity duration-200 focus:outline-hidden"
                  >
                    {/* Outer Halo for Selected, Domain Hub, or Path Cluster Node */}
                    {(isSelected ||
                      node.kind === 'domain-hub' ||
                      node.kind === 'path-cluster') && (
                      <circle
                        r={node.radius + (isSelected ? 7 : 4)}
                        fill="none"
                        stroke={isSelected ? '#38bdf8' : palette.stroke}
                        strokeWidth={isSelected ? 2.4 : 1.3}
                        strokeDasharray={
                          node.kind === 'domain-hub'
                            ? '3 3'
                            : node.kind === 'path-cluster'
                            ? '5 2'
                            : undefined
                        }
                        opacity={0.9}
                      />
                    )}

                    {/* Main Node Circle */}
                    <circle
                      r={node.radius}
                      fill={circleFill}
                      stroke={isSelected ? '#ffffff' : palette.stroke}
                      strokeWidth={isSelected ? 2.5 : 1.5}
                    />

                    {/* Inner Circle Badge Text */}
                    <text
                      textAnchor="middle"
                      dy="3.5"
                      fill="#ffffff"
                      fontSize={node.kind === 'domain-hub' ? '9.5' : '8.5'}
                      fontWeight="bold"
                      fontFamily="monospace"
                    >
                      {node.kind === 'domain-hub'
                        ? 'RAÍZ'
                        : node.kind === 'path-cluster'
                        ? `C(${node.childCount})`
                        : isPinned
                        ? 'PIN'
                        : `${node.estimatedTokens}t`}
                    </text>

                    {/* Node Label Box below circle */}
                    <g transform={`translate(0, ${node.radius + 13})`}>
                      <rect
                        x={-78}
                        y={-8.5}
                        width={156}
                        height={17}
                        rx={5}
                        fill="rgba(15, 23, 42, 0.88)"
                        stroke={
                          isSelected
                            ? 'rgba(56, 189, 248, 0.8)'
                            : 'rgba(51, 65, 85, 0.8)'
                        }
                        strokeWidth={1}
                      />
                      <text
                        textAnchor="middle"
                        dy="3"
                        fill={isSelected ? '#f8fafc' : '#cbd5e1'}
                        fontSize={node.kind === 'domain-hub' ? '10' : '9.5'}
                        fontWeight={
                          node.kind !== 'context-node' || isSelected ? '600' : '500'
                        }
                      >
                        {node.shortLabel}
                      </text>
                    </g>
                  </g>
                );
              })}
            </g>
          </svg>

          {/* Bottom Helper Overlay */}
          <div className="px-4 py-2.5 bg-slate-900/95 border-t border-slate-800 flex flex-wrap items-center justify-between gap-2 text-[11px] text-slate-400">
            <span>
              Zoom: rueda del ratón o botones · Arrastra círculos para reorganizar · Clic para ver resumen y metadatos.
            </span>
            <span className="font-mono text-slate-300 tabular-nums">
              {rawGraph.graphNodes.length} círculos ({clusterCount} clústeres · {contextNodes.length} nodos) · {rawGraph.graphLinks.length} enlaces
            </span>
          </div>
        </div>

        {/* Right Side (5 cols): Interactive Node Summary & Metadata Sidebar */}
        <aside
          aria-label="Resumen y metadatos del nodo seleccionado en el grafo"
          className="lg:col-span-5 p-5 flex flex-col justify-between space-y-4 bg-slate-50/60 dark:bg-slate-900/60"
        >
          {activeNode ? (
            <div className="space-y-4">
              {/* Node Header, Kind Badge & Title */}
              <div className="space-y-2">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span
                    className={`px-2.5 py-0.5 rounded-md text-[11px] font-mono font-semibold ${
                      getDomainPalette(activeNode.domain).badgeBg
                    }`}
                  >
                    {activeNode.kind === 'domain-hub'
                      ? 'Clúster Padre Raíz (Nivel 1)'
                      : activeNode.kind === 'path-cluster'
                      ? 'Clúster Padre-Hijo (Nivel 2)'
                      : 'Nodo Semántico (Nivel 3)'}
                  </span>
                  <span className="text-[11px] font-mono text-emerald-600 dark:text-emerald-400 font-semibold tabular-nums">
                    ~{activeNode.estimatedTokens} tokens
                  </span>
                </div>

                <h4 className="text-sm font-bold text-slate-900 dark:text-slate-100 leading-snug">
                  {activeNode.label}
                </h4>

                {/* Summary Box */}
                <div className="p-3 rounded-xl bg-white dark:bg-slate-950 border border-slate-200 dark:border-slate-800 space-y-1">
                  <span className="text-[10px] font-mono uppercase tracking-wider text-slate-400 dark:text-slate-500 block">
                    Resumen del Nodo
                  </span>
                  <p className="text-xs text-slate-700 dark:text-slate-300 leading-relaxed">
                    {activeNode.summary}
                  </p>
                </div>
              </div>

              {/* Structured Metadata Grid in the Graph Sidebar */}
              <div className="space-y-2">
                <div className="flex items-center gap-1.5 text-xs font-semibold text-slate-900 dark:text-slate-100">
                  <Layers className="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" />
                  <span>Metadatos y Jerarquía de Clúster</span>
                </div>

                <div className="grid grid-cols-2 gap-2 text-xs">
                  <div className="col-span-2 p-2.5 rounded-xl bg-white dark:bg-slate-950 border border-slate-200 dark:border-slate-800">
                    <span className="text-[10px] font-mono text-slate-400 dark:text-slate-500 flex items-center gap-1">
                      <FolderTree className="w-3 h-3 text-blue-500" />
                      <span>Ruta de Clúster Semántico (Padre → Hijo)</span>
                    </span>
                    <p className="mt-0.5 text-xs font-mono font-medium text-slate-800 dark:text-slate-200">
                      {activeNode.semanticPath.join(' › ')}
                    </p>
                  </div>

                  <div className="p-2.5 rounded-xl bg-white dark:bg-slate-950 border border-slate-200 dark:border-slate-800">
                    <span className="text-[10px] font-mono text-slate-400 dark:text-slate-500 flex items-center gap-1">
                      <Tag className="w-3 h-3 text-blue-500" />
                      <span>Prioridad & Origen</span>
                    </span>
                    <p className="mt-0.5 font-mono font-semibold text-slate-800 dark:text-slate-200">
                      {activeNode.priority.toUpperCase()} · {activeNode.sourceTool}
                    </p>
                  </div>

                  <div className="p-2.5 rounded-xl bg-white dark:bg-slate-950 border border-slate-200 dark:border-slate-800">
                    <span className="text-[10px] font-mono text-slate-400 dark:text-slate-500 flex items-center gap-1">
                      <Clock className="w-3 h-3 text-blue-500" />
                      <span>Registro / Nivel</span>
                    </span>
                    <p className="mt-0.5 font-mono font-medium text-slate-800 dark:text-slate-200">
                      {activeNode.createdAt ? new Date(activeNode.createdAt).toLocaleString() : 'Carpeta'}
                    </p>
                  </div>
                </div>

                {/* Parent / Child Cluster Quick Jump Pills */}
                {(parentClusterNode || childClusterNodes.length > 0) && (
                  <div className="flex flex-wrap items-center gap-1.5 pt-1">
                    {parentClusterNode && (
                      <button
                        type="button"
                        onClick={() => selectNode(parentClusterNode.id)}
                        className="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg text-[11px] font-mono bg-blue-50 dark:bg-slate-800 text-blue-700 dark:text-blue-300 border border-blue-200 dark:border-slate-700 hover:border-blue-400 transition-colors"
                      >
                        <span>Clúster Padre: {parentClusterNode.shortLabel}</span>
                        <ArrowRight className="w-3 h-3" />
                      </button>
                    )}
                    {childClusterNodes.slice(0, 3).map((child) => (
                      <button
                        key={child.id}
                        type="button"
                        onClick={() => selectNode(child.id)}
                        className="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg text-[11px] font-mono bg-slate-100 dark:bg-slate-800 text-slate-700 dark:text-slate-300 border border-slate-200 dark:border-slate-700 hover:border-blue-400 transition-colors"
                      >
                        <span>Hijo: {child.shortLabel}</span>
                      </button>
                    ))}
                  </div>
                )}
              </div>

              {/* Connected Nodes & Semantic Bridges */}
              <div className="space-y-2 pt-2 border-t border-slate-200 dark:border-slate-800">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-semibold text-slate-900 dark:text-slate-100 flex items-center gap-1.5">
                    <GitBranch className="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" />
                    <span>
                      Nodos Interconectados ({activeNodeConnections.length})
                    </span>
                  </span>
                  <span className="text-[11px] font-mono text-slate-500 dark:text-slate-400">
                    Clic para inspeccionar
                  </span>
                </div>

                <div className="space-y-1.5 max-h-[165px] overflow-y-auto pr-1">
                  {activeNodeConnections.map(({ link, otherNode }) => {
                    if (!otherNode) return null;
                    const isCross = link.kind === 'cross-semantic';
                    return (
                      <button
                        key={link.id}
                        type="button"
                        onClick={() => selectNode(otherNode.id)}
                        className="w-full text-left p-2.5 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-950 hover:border-blue-400 dark:hover:border-blue-700 transition-colors space-y-0.5"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span
                            className={`text-[10px] font-mono font-semibold ${
                              isCross
                                ? 'text-blue-600 dark:text-blue-400'
                                : 'text-slate-500 dark:text-slate-400'
                            }`}
                          >
                            {isCross ? '★ Puente Semántico' : 'Clúster Padre-Hijo'} ·{' '}
                            {link.relationshipLabel}
                          </span>
                          <ArrowRight className="w-3 h-3 text-slate-400 shrink-0" />
                        </div>
                        <p className="text-xs font-semibold text-slate-900 dark:text-slate-100">
                          {otherNode.label}
                        </p>
                        <p className="text-[11px] text-slate-600 dark:text-slate-400 leading-snug">
                          {link.reason}
                        </p>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          ) : null}

          {activeNode && (
            <button
              type="button"
              onClick={() =>
                onSelectClusterQuery(activeNode.semanticPath.slice(0, 2).join(' '))
              }
              className="w-full py-2.5 px-4 text-xs font-semibold text-white bg-blue-600 hover:bg-blue-500 rounded-xl transition-colors flex items-center justify-center gap-2"
            >
              <Sparkles className="w-3.5 h-3.5" />
              <span>Filtrar la memoria por este clúster</span>
            </button>
          )}
        </aside>
      </div>
    </section>
  );
};

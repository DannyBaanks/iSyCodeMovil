import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Asistente: Google, memoria semántica y el monitor de tu PC.
// Por defecto se ve sencillo; el registro y el corpus de tools aparecen al
// activar el modo desarrollador en Opciones. Misma estructura que
// android/.../ui/AssistantScreens.kt.

/// How other screens open the Asistente (a toolbar button or a tapped notification).
public enum AssistantLaunch {
    public static let openKey = "assistant.openOnActivate"
    public static let openNotification = Notification.Name("iyscode.openAssistant")

    @MainActor public static func open() {
        NotificationCenter.default.post(name: openNotification, object: nil)
    }
}

public struct AssistantRootView: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(IysAppearance.storageKey) private var appearance = IysAppearance.automatic.rawValue

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sectionPicker
                if let message = store.message {
                    MessageBanner(text: message) { store.message = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Group {
                    switch store.section {
                    case .home: HomeSection(openMaps: openMaps)
                    case .memory: MemorySection()
                    case .google: GoogleSection()
                    case .log: LogSection()
                    case .options: OptionsSection()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: store.message)
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("Asistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
            .sheet(item: $store.pending) { action in
                ConfirmActionSheet(action: action)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(IysAppearance(rawValue: appearance)?.colorScheme)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AssistantCatalog.sections(developerMode: store.developerMode)) { section in
                    Pill(title: section.title, symbol: section.symbol, selected: store.section == section) {
                        store.section = section
                    }
                }
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, 8)
        }
    }

    private func openMaps(_ query: String) {
        let text = query.isEmpty ? "cerca de mí" : query
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?q=\(encoded)") { openURL(url) }
    }
}

// MARK: - Building blocks

private struct Pill: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundColor(selected ? OCColor.onAccent : OCColor.textPrimary)
            .background(Capsule().fill(selected ? OCColor.agentBuild : OCColor.bgLayer1))
            .overlay(Capsule().stroke(selected ? OCColor.agentBuild : OCColor.borderMuted, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct MessageBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 14)).foregroundColor(OCColor.textPrimary)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").foregroundColor(OCColor.textSecondary) }
                .accessibilityLabel("Cerrar")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.agentBuildSoft))
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.bottom, 6)
    }
}

private struct CardBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ocCard(radius: 18)
    }
}

private struct Muted: View {
    let text: String
    var color: Color = OCColor.textSecondary
    init(_ text: String, color: Color = OCColor.textSecondary) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.system(size: 13)).foregroundColor(color).fixedSize(horizontal: false, vertical: true) }
}

private struct TitleText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 17, weight: .semibold)).foregroundColor(OCColor.textPrimary) }
}

private struct InputField: View {
    let label: String
    @Binding var text: String
    var multiline = false

    var body: some View {
        Group {
            if multiline {
                TextField(label, text: $text, axis: .vertical).lineLimit(2...6)
            } else {
                TextField(label, text: $text)
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}

private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .foregroundColor(OCColor.onAccent)
                .background(Capsule().fill(enabled ? OCColor.agentBuild : OCColor.textFaint))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private func priorityColor(_ priority: ContextPriority) -> Color {
    switch priority {
    case .critical: return OCColor.danger
    case .high: return Color.iys(dark: "FB923C", light: "C2410C")
    case .normal: return OCColor.info
    }
}

private let violet = Color.iys(dark: "9B5DE5", light: "7A3FC7")

// MARK: - Confirm sheet

private struct ConfirmActionSheet: View {
    @EnvironmentObject private var store: AssistantStore
    let action: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.system(size: 20, weight: .bold)).foregroundColor(OCColor.textPrimary)
            Muted(action.message)
            ForEach(Array(action.details.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0.uppercased()).font(OCTypography.metaMono).foregroundColor(OCColor.textFaint)
                    Text(item.1).font(.system(size: 15)).foregroundColor(OCColor.textPrimary).lineLimit(8)
                }
            }
            if store.developerMode { Muted("Tool: \(action.toolId)", color: OCColor.textFaint) }
            Spacer()
            HStack {
                Button("Cancelar") { store.cancelPending() }.disabled(store.running)
                Spacer()
                if store.running { ProgressView() } else { PrimaryButton(title: "Confirmar") { store.confirmPending() } }
            }
        }
        .padding(20)
        .background(OCColor.bgBase.ignoresSafeArea())
        .interactiveDismissDisabled(store.running)
    }
}

// MARK: - Inicio

private struct HomeSection: View {
    @EnvironmentObject private var store: AssistantStore
    let openMaps: (String) -> Void
    @State private var prompt = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                CardBox {
                    TitleText("¿Qué necesitas?")
                    HStack(spacing: 8) {
                        InputField(label: "Ej. revisa mi agenda de hoy · busca un café cerca", text: $prompt)
                            .onSubmit(send)
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                                .foregroundColor(prompt.isEmpty ? OCColor.textFaint : OCColor.onAccent)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(prompt.isEmpty ? OCColor.bgLayer2 : OCColor.agentBuild))
                        }
                        .disabled(prompt.isEmpty)
                        .accessibilityLabel("Enviar")
                    }
                    Pill(title: store.priorityContext ? "Contexto prioritario: sí" : "Contexto prioritario", symbol: "sparkles",
                         selected: store.priorityContext) { store.priorityContext.toggle() }
                    if store.priorityContext {
                        Muted("Lo que envíes se propondrá para tu memoria con prioridad crítica, y GUS lo tendrá más en cuenta.")
                    }
                }
                sectionHeader("Acciones rápidas", "Un toque y listo")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(AssistantCatalog.quickActions) { action in
                        QuickActionTile(action: action, developer: store.developerMode) {
                            if let query = store.run(action) { openMaps(query) }
                        }
                    }
                }
                sectionHeader("Avisos", store.feed.isEmpty ? nil : "Lo más reciente primero")
                if store.feed.isEmpty {
                    CardBox { Muted("Aún no hay avisos. Aquí aparecerán las tareas que termine tu PC, los correos nuevos (si activas la vigilancia) y lo que confirmes.") }
                }
                ForEach(store.feed) { item in
                    CardBox {
                        HStack {
                            Text(item.source).font(OCTypography.metaMono).foregroundColor(OCColor.agentBuild)
                            Spacer()
                            Text(item.time, style: .time).font(.system(size: 12)).foregroundColor(OCColor.textFaint)
                        }
                        Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                        if !item.body.isEmpty { Muted(item.body) }
                    }
                }
            }
            .padding(OCSpacing.contentMargin)
        }
    }

    private func send() {
        if let query = store.ask(prompt) { openMaps(query) }
        prompt = ""
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.email.map { "Hola, \($0.split(separator: "@").first ?? "")" } ?? "Hola")
                .font(.system(size: 26, weight: .bold)).foregroundColor(OCColor.textPrimary)
            Muted("Tu correo, agenda, pendientes y lo que pasa en tu PC, en un solo lugar. Nada se envía ni se cambia sin que lo confirmes.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    StatusChip(text: store.signedIn ? "Google conectado" : "Google sin conectar", color: store.signedIn ? OCColor.success : OCColor.textFaint)
                    StatusChip(text: "PC: \(store.monitorStatus)", color: store.monitorStatus.hasPrefix("Conectado") ? OCColor.success : OCColor.textFaint)
                    StatusChip(text: "\(store.memory.count) en memoria", color: violet)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [OCColor.agentBuild.opacity(0.22), violet.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}

private func sectionHeader(_ title: String, _ subtitle: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        TitleText(title)
        if let subtitle { Muted(subtitle) }
    }
    .padding(.top, 6)
}

private struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundColor(OCColor.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(OCColor.bgBase.opacity(0.7)))
    }
}

private struct QuickActionTile: View {
    let action: QuickAction
    let developer: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundColor(OCColor.agentBuild)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(OCColor.agentBuildSoft))
                Text(action.title).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                Text(developer ? action.toolId : action.subtitle).font(.system(size: 12)).foregroundColor(OCColor.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .ocCard(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Memoria

private struct MemorySection: View {
    @EnvironmentObject private var store: AssistantStore
    @AppStorage("assistant.memorySearchHistory") private var historyRaw = ""
    @State private var query = ""
    @State private var graphView = false

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        let matches = SemanticContext.fuzzyFilter(store.memory, query: query).map(\.node)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardBox {
                    TitleText("Memoria de GUS")
                    Muted("Lo que guardas se ordena en carpetas de tres niveles. Al preguntar, GUS recorre solo la rama que viene al caso: tarda un poco más, pero acierta más, sobre todo con modelos pequeños.")
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(OCColor.textFaint)
                        TextField("Buscar (tolera errores: \"calndario\", \"swft\")", text: $query)
                            .onSubmit { remember(query) }
                        if !query.isEmpty {
                            Button { remember(query); query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(OCColor.textFaint) }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.bgLayer1))
                    if !query.isEmpty { Muted("\(matches.count) de \(store.memory.count) coinciden") }
                    if !history.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath").foregroundColor(OCColor.textFaint)
                                ForEach(history, id: \.self) { term in
                                    Pill(title: term, selected: term == query) { query = term }
                                }
                                Button("Borrar historial") { historyRaw = "" }.font(.system(size: 13))
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Pill(title: "Carpetas", symbol: "folder", selected: !graphView) { graphView = false }
                        Pill(title: "Grafo", symbol: "point.3.connected.trianglepath.dotted", selected: graphView) { graphView = true }
                    }
                }
                if store.memory.isEmpty {
                    CardBox { Muted("Todavía no hay notas. Guarda la primera abajo, o pídele a GUS que recuerde algo.") }
                } else if graphView {
                    SemanticGraphCard(nodes: matches)
                } else {
                    ForEach(SemanticContext.buildTree(matches)) { folder in
                        FolderRow(folder: folder, expandAll: !query.isEmpty)
                    }
                }
                SaveMemoryCard()
                RetrievalProbe()
            }
            .padding(OCSpacing.contentMargin)
        }
        .onAppear { store.reloadMemory() }
    }

    private func remember(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        historyRaw = ([clean] + history.filter { $0 != clean }).prefix(8).joined(separator: "\n")
    }
}

private struct FolderRow: View {
    @EnvironmentObject private var store: AssistantStore
    let folder: TreeFolder
    let expandAll: Bool
    @State private var open: Bool?

    var body: some View {
        let expanded = expandAll || (open ?? (folder.depth == 1))
        VStack(alignment: .leading, spacing: 4) {
            Button { open = !expanded } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundColor(OCColor.textSecondary).frame(width: 14)
                    Image(systemName: "folder.fill").foregroundColor(folder.depth == 1 ? violet : OCColor.agentBuild)
                    Text(folder.name).font(.system(size: folder.depth == 1 ? 16 : 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                    Spacer()
                    Text(store.developerMode ? "\(["Dominio", "Rama", "Subtema"][min(folder.depth, 3) - 1]) · \(folder.totalNodes) · ~\(folder.totalTokens) tok" : "\(folder.totalNodes)")
                        .font(OCTypography.metaMono).foregroundColor(OCColor.textFaint)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(folder.subfolders) { FolderRow(folder: $0, expandAll: expandAll) }
                ForEach(folder.nodes) { MemoryNodeRow(node: $0) }
            }
        }
        .padding(.leading, CGFloat(folder.depth - 1) * 14)
    }
}

private struct MemoryNodeRow: View {
    @EnvironmentObject private var store: AssistantStore
    let node: ContextNode
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(priorityColor(node.priority)).frame(width: 8, height: 8)
                Text(node.title).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                Spacer()
                Button { confirmDelete = true } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundColor(OCColor.textFaint) }
                    .accessibilityLabel("Borrar nota")
            }
            Muted(node.summary)
            Muted(store.developerMode ? "\(node.priority.label) · \(node.source) · ~\(node.estimatedTokens) tok" : node.priority.label, color: OCColor.textFaint)
        }
        .padding(12)
        .ocCard(radius: 14)
        .padding(.leading, 14)
        .confirmationDialog("¿Borrar esta nota?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) { store.deleteMemory(node) }
        } message: { Text("GUS dejará de usarla. No se puede deshacer.") }
    }
}

private struct SaveMemoryCard: View {
    @EnvironmentObject private var store: AssistantStore
    @State private var title = ""
    @State private var summary = ""
    @State private var level1 = ""
    @State private var level2 = ""
    @State private var level3 = ""
    @State private var priority = ContextPriority.high

    var body: some View {
        let suggested = SemanticContext.inferPath("\(title) \(summary)")
        CardBox {
            TitleText("Guardar una nota")
            InputField(label: "Título (opcional)", text: $title)
            InputField(label: "Qué debe recordar GUS", text: $summary, multiline: true)
            Muted("Carpeta sugerida: \(suggested.joined(separator: " › ")). Cámbiala si quieres:")
            InputField(label: "Dominio · \(suggested[0])", text: $level1)
            InputField(label: "Rama · \(suggested.count > 1 ? suggested[1] : "")", text: $level2)
            InputField(label: "Subtema · \(suggested.count > 2 ? suggested[2] : "")", text: $level3)
            HStack(spacing: 6) {
                ForEach(ContextPriority.allCases, id: \.self) { p in
                    Pill(title: p.label, selected: priority == p) { priority = p }
                }
            }
            PrimaryButton(title: "Guardar…", enabled: !summary.trimmingCharacters(in: .whitespaces).isEmpty) {
                let path = [level1.isEmpty ? suggested[0] : level1,
                            level2.isEmpty ? (suggested.count > 1 ? suggested[1] : "") : level2,
                            level3.isEmpty ? (suggested.count > 2 ? suggested[2] : "") : level3]
                store.proposeMemory(title: title, summary: summary, path: path, priority: priority, source: "manual")
                title = ""; summary = ""; level1 = ""; level2 = ""; level3 = ""
            }
        }
    }
}

private struct RetrievalProbe: View {
    @EnvironmentObject private var store: AssistantStore
    @State private var probe = ""
    @State private var result: Retrieval?

    var body: some View {
        CardBox {
            TitleText("Probar qué usaría GUS")
            Muted("Escribe una pregunta y verás la rama que recorre y las notas que elige.")
            HStack {
                InputField(label: "Ej. ¿cuándo es mi junta de equipo?", text: $probe)
                Button { result = store.previewRetrieval(probe) } label: {
                    Image(systemName: "magnifyingglass").foregroundColor(OCColor.agentBuild)
                }
                .disabled(probe.isEmpty || store.memory.isEmpty)
            }
            if let result {
                ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(OCTypography.metaMono).foregroundColor(OCColor.agentBuild)
                            .frame(width: 20, height: 20).background(Circle().fill(OCColor.agentBuildSoft))
                        Text(step).font(.system(size: 13)).foregroundColor(OCColor.textPrimary)
                    }
                }
                ForEach(result.nodes) { Muted("• \($0.title)", color: priorityColor($0.priority)) }
            }
        }
    }
}

// MARK: - Graph (Obsidian-style)

private struct SemanticGraphCard: View {
    let nodes: [ContextNode]
    @State private var positions: [String: CGPoint] = [:]
    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var selectedId: String?
    @State private var showLegend = true
    @State private var bridgesOnly = false
    @State private var seed = 0
    @State private var dragging: String?
    @State private var lastDrag: CGSize = .zero
    @State private var graph = SemanticGraph(nodes: [], links: [])

    var body: some View {
        CardBox {
            HStack {
                TitleText("Constelación")
                Spacer()
                Button { scale = max(0.4, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Alejar")
                Text("\(Int(scale * 100))%").font(OCTypography.metaMono).foregroundColor(OCColor.textSecondary)
                Button { scale = min(3, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Acercar")
            }
            Muted("Arrastra los círculos para acomodarlos, arrastra el fondo para moverte y toca uno para ver su detalle.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Pill(title: "Todo", selected: !bridgesOnly) { bridgesOnly = false }
                    Pill(title: "Solo puentes", selected: bridgesOnly) { bridgesOnly = true }
                    Pill(title: showLegend ? "Ocultar leyenda" : "Leyenda", selected: showLegend) { showLegend.toggle() }
                    Pill(title: "Reorganizar", selected: false) {
                        seed += 1
                        positions = SemanticContext.layout(graph, seed: seed)
                        pan = .zero; scale = 1
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvas(size: geo.size)
                    if showLegend { legend.padding(8) }
                }
            }
            .frame(height: 360)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.iys(dark: "0D0D16", light: "F1EFF7")))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(OCColor.borderMuted, lineWidth: 1))
            Muted("\(graph.nodes.filter { $0.kind == .context }.count) notas · \(graph.links.filter { $0.kind == .semantic }.count) puentes",
                  color: OCColor.textFaint)
            if let id = selectedId, let node = graph.nodes.first(where: { $0.id == id }) { detail(node) }
        }
        .onAppear(perform: rebuild)
        .onChange(of: nodes.map(\.id)) { _ in rebuild() }
    }

    private func rebuild() {
        graph = SemanticContext.buildGraph(nodes)
        positions = SemanticContext.layout(graph, seed: seed)
        if let id = selectedId, !graph.nodes.contains(where: { $0.id == id }) { selectedId = nil }
    }

    private func color(_ node: GraphNode) -> Color {
        switch node.kind {
        case .domain: return violet
        case .cluster: return OCColor.agentBuild
        case .context: return priorityColor(node.priority)
        }
    }

    private func screen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x + pan.width) * scale, y: size.height / 2 + (p.y + pan.height) * scale)
    }

    private func hit(_ location: CGPoint, _ size: CGSize) -> GraphNode? {
        graph.nodes
            .map { node -> (GraphNode, CGFloat) in
                let s = screen(positions[node.id] ?? .zero, size)
                return (node, hypot(s.x - location.x, s.y - location.y))
            }
            .filter { $0.1 <= CGFloat($0.0.radius + 10) * max(scale, 0.8) }
            .min { $0.1 < $1.1 }?.0
    }

    private func canvas(size: CGSize) -> some View {
        let neighbors: Set<String>? = selectedId.map { id in
            Set(graph.links.filter { $0.source == id || $0.target == id }.flatMap { [$0.source, $0.target] })
        }
        return Canvas { context, canvasSize in
            for hub in graph.nodes where hub.kind == .domain {
                let members = graph.nodes.filter { $0.domain == hub.domain }.compactMap { positions[$0.id] }
                guard !members.isEmpty else { continue }
                let cx = members.map(\.x).reduce(0, +) / CGFloat(members.count)
                let cy = members.map(\.y).reduce(0, +) / CGFloat(members.count)
                let reach = (members.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 0) + 40
                let c = screen(CGPoint(x: cx, y: cy), canvasSize)
                let r = reach * scale
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color(hub).opacity(0.07)))
            }
            for link in graph.links {
                if bridgesOnly && link.kind == .hierarchy { continue }
                guard let a = positions[link.source], let b = positions[link.target] else { continue }
                let lit = selectedId == nil || link.source == selectedId || link.target == selectedId
                var path = Path()
                path.move(to: screen(a, canvasSize))
                path.addLine(to: screen(b, canvasSize))
                let semantic = link.kind == .semantic
                let base = semantic ? Color.iys(dark: "FBBF24", light: "A16207") : OCColor.textFaint
                context.stroke(path, with: .color(base.opacity(lit ? 0.85 : 0.15)),
                               style: StrokeStyle(lineWidth: semantic ? 1.6 : 1.2, dash: semantic ? [6, 5] : []))
            }
            for node in graph.nodes {
                guard let p = positions[node.id] else { continue }
                let c = screen(p, canvasSize)
                let dim = neighbors.map { !$0.contains(node.id) } ?? false
                let r = CGFloat(node.radius) * scale / 2.2 * 2
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                let tint = color(node).opacity(dim ? 0.25 : 1)
                if node.kind == .context {
                    context.fill(Path(ellipseIn: rect), with: .color(tint))
                } else {
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(dim ? 0.08 : 0.18)))
                    context.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: 2)
                }
                if node.id == selectedId {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(OCColor.textPrimary), lineWidth: 1.5)
                }
                let showLabel = node.kind != .context || node.id == selectedId || scale >= 1.2 || (neighbors?.contains(node.id) ?? false)
                if showLabel && !dim {
                    let label = node.label.count > 22 ? String(node.label.prefix(20)) + "…" : node.label
                    context.draw(Text(label).font(.system(size: 10, weight: node.kind == .domain ? .bold : .regular))
                        .foregroundColor(OCColor.textPrimary), at: CGPoint(x: c.x, y: c.y + r + 9))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if lastDrag == .zero && dragging == nil { dragging = hit(value.startLocation, size)?.id }
                    let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                    lastDrag = value.translation
                    if let id = dragging {
                        let p = positions[id] ?? .zero
                        positions[id] = CGPoint(x: p.x + delta.width / scale, y: p.y + delta.height / scale)
                    } else {
                        pan = CGSize(width: pan.width + delta.width / scale, height: pan.height + delta.height / scale)
                    }
                }
                .onEnded { _ in dragging = nil; lastDrag = .zero }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in selectedId = hit(value.location, size)?.id }
        )
        .simultaneousGesture(
            MagnificationGesture().onChanged { value in scale = min(3, max(0.4, value)) }
        )
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            legendRow(priorityColor(.critical), "Crítica")
            legendRow(priorityColor(.high), "Alta")
            legendRow(priorityColor(.normal), "Normal")
            legendRow(violet, "Dominio", ring: true)
            legendRow(OCColor.agentBuild, "Rama", ring: true)
            HStack(spacing: 6) {
                Rectangle().fill(Color.iys(dark: "FBBF24", light: "A16207")).frame(width: 14, height: 2)
                Text("Puente (temas en común)").font(.system(size: 11)).foregroundColor(OCColor.textPrimary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(OCColor.bgBase.opacity(0.92)))
    }

    private func legendRow(_ color: Color, _ label: String, ring: Bool = false) -> some View {
        HStack(spacing: 6) {
            Group {
                if ring { Circle().stroke(color, lineWidth: 2) } else { Circle().fill(color) }
            }
            .frame(width: 10, height: 10)
            Text(label).font(.system(size: 11)).foregroundColor(OCColor.textPrimary)
        }
    }

    private func detail(_ node: GraphNode) -> some View {
        let related = graph.links.filter { $0.source == node.id || $0.target == node.id }
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            TitleText(node.label)
            Muted(node.path.joined(separator: " › "), color: OCColor.agentBuild)
            Muted(node.summary)
            if !related.isEmpty {
                Text("Conectado con").font(.system(size: 13, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                ForEach(Array(related.enumerated()), id: \.offset) { _, link in
                    let otherId = link.source == node.id ? link.target : link.source
                    if let other = graph.nodes.first(where: { $0.id == otherId }) {
                        Button { selectedId = other.id } label: {
                            HStack {
                                Text(other.label).font(.system(size: 14)).foregroundColor(OCColor.textPrimary).lineLimit(1)
                                Spacer()
                                Text(link.kind == .semantic ? link.label : "carpeta").font(.system(size: 12)).foregroundColor(OCColor.textFaint).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Google

private struct GoogleSection: View {
    @EnvironmentObject private var store: AssistantStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardBox {
                    TitleText(store.signedIn ? "Cuenta de Google" : "Conecta tu cuenta de Google")
                    if store.signedIn {
                        Muted(store.email ?? "Conectada")
                        Muted("Permisos: " + (GoogleService.allCases.filter(store.granted).map(\.title).joined(separator: ", ").nilIfEmpty ?? "ninguno"))
                        HStack(spacing: 12) {
                            PrimaryButton(title: "Actualizar todo") { store.refreshAll() }
                            Button("Cambiar permisos") { store.signIn() }.font(.system(size: 14))
                            Button("Desconectar", role: .destructive) { store.signOut() }.font(.system(size: 14))
                        }
                    } else {
                        Muted("Inicias sesión en la página de Google, con tu propio proyecto. El token se queda en el llavero de este iPhone y puedes desconectarlo cuando quieras.")
                        PrimaryButton(title: "Iniciar sesión con Google") { store.signIn() }
                        if !GoogleOAuth.isPlausibleClientId(store.clientId) {
                            Muted("Antes, pega tu ID de cliente en Opciones › Google.", color: Color.iys(dark: "FB923C", light: "C2410C"))
                        }
                    }
                }
                if store.signedIn {
                    ForEach(store.enabledServices) { ServiceCard(service: $0) }
                }
            }
            .padding(OCSpacing.contentMargin)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct ServiceCard: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.openURL) private var openURL
    let service: GoogleService
    @State private var a = ""
    @State private var b = ""
    @State private var c = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var minutes = 45
    @State private var composing = false

    var body: some View {
        CardBox {
            HStack {
                Image(systemName: service.symbol).foregroundColor(OCColor.agentBuild)
                VStack(alignment: .leading, spacing: 2) {
                    TitleText(service.title)
                    Muted(service.detail)
                }
                Spacer()
                if service != .docs && store.granted(service) {
                    if store.loading.contains(service) { ProgressView() } else {
                        Button { store.refresh(service) } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Actualizar \(service.title)")
                    }
                }
            }
            if !store.granted(service) {
                Muted("Sin permiso todavía. Toca \"Cambiar permisos\" arriba.", color: Color.iys(dark: "FB923C", light: "C2410C"))
            } else {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch service {
        case .gmail:
            ForEach(store.mail) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.subject).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary).lineLimit(1)
                    Muted(m.from, color: OCColor.textFaint)
                    Muted(m.snippet)
                }
            }
            if composing {
                InputField(label: "Para", text: $a).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                InputField(label: "Asunto", text: $b)
                InputField(label: "Mensaje", text: $c, multiline: true)
                HStack {
                    PrimaryButton(title: "Enviar…", enabled: !a.isEmpty) { store.proposeEmail(to: a, subject: b, body: c) }
                    Button("Cerrar") { composing = false }
                }
            } else {
                Button("Redactar correo") { composing = true }.font(.system(size: 14))
            }
        case .calendar:
            ForEach(store.events) { e in
                Button { if let url = URL(string: e.link), !e.link.isEmpty { openURL(url) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                        Muted(String(e.start.replacingOccurrences(of: "T", with: " ").prefix(16)) + (e.location.isEmpty ? "" : " · \(e.location)"))
                    }
                }
                .buttonStyle(.plain)
            }
            if composing {
                InputField(label: "Título", text: $a)
                DatePicker("Inicio", selection: $date).font(.system(size: 14))
                Stepper("Duración: \(minutes) min", value: $minutes, in: 15...480, step: 15).font(.system(size: 14))
                InputField(label: "Lugar (opcional)", text: $b)
                HStack {
                    PrimaryButton(title: "Crear…", enabled: !a.isEmpty) { store.proposeEvent(title: a, start: date, minutes: minutes, location: b) }
                    Button("Cerrar") { composing = false }
                }
            } else {
                Button("Nuevo evento") { composing = true }.font(.system(size: 14))
            }
        case .tasks:
            ForEach(store.tasks) { Text("• \($0.title)").font(.system(size: 14)).foregroundColor(OCColor.textPrimary) }
            InputField(label: "Nuevo pendiente", text: $a)
            InputField(label: "Notas (opcional)", text: $b)
            PrimaryButton(title: "Agregar…", enabled: !a.isEmpty) { store.proposeTask(title: a, notes: b); a = ""; b = "" }
        case .drive:
            ForEach(store.files) { f in
                Button { if let url = URL(string: f.link), !f.link.isEmpty { openURL(url) } } label: {
                    HStack {
                        Text(f.name).font(.system(size: 14)).foregroundColor(OCColor.textPrimary).lineLimit(1)
                        Spacer()
                        Text(f.modified.prefix(10)).font(.system(size: 12)).foregroundColor(OCColor.textFaint)
                    }
                }
                .buttonStyle(.plain)
            }
        case .docs:
            InputField(label: "Título del documento", text: $a)
            InputField(label: "Contenido", text: $b, multiline: true)
            PrimaryButton(title: "Crear…", enabled: !a.isEmpty) { store.proposeDoc(title: a, text: b); a = ""; b = "" }
        case .contacts:
            ForEach(store.contacts) { contact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name.isEmpty ? contact.email : contact.name).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                    Muted([contact.email, contact.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
        case .sheets:
            InputField(label: "Enlace o ID de la hoja", text: $store.sheetId)
            if let sheet = store.sheet {
                Muted("Pestaña: \(sheet.tab)", color: OCColor.textFaint)
                ForEach(Array(sheet.rows.prefix(10).enumerated()), id: \.offset) { _, row in
                    Text(row.joined(separator: "  |  ")).font(OCTypography.codeSmall).foregroundColor(OCColor.textPrimary)
                }
            }
            InputField(label: "Nueva fila, separada por comas", text: $a)
            PrimaryButton(title: "Agregar fila…", enabled: !a.isEmpty) {
                store.proposeRow(a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }); a = ""
            }
        case .classroom:
            ForEach(store.courses) { course in
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                    if !course.section.isEmpty { Muted(course.section) }
                    Button("Publicar anuncio aquí…") { store.proposeAnnouncement(course: course, text: a) }
                        .font(.system(size: 13)).disabled(a.isEmpty)
                }
            }
            if !store.courses.isEmpty { InputField(label: "Anuncio", text: $a, multiline: true) }
        }
    }
}

// MARK: - Registro (developer)

private struct LogSection: View {
    @EnvironmentObject private var store: AssistantStore
    @State private var filter: AssistantLogLevel?

    var body: some View {
        let entries = store.logs.filter { filter == nil || $0.level == filter }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Pill(title: "Todo", selected: filter == nil) { filter = nil }
                        ForEach(AssistantLogLevel.allCases, id: \.self) { level in
                            Pill(title: level.rawValue, selected: filter == level) { filter = level }
                        }
                        Button("Limpiar") { store.clearLogs() }.font(.system(size: 13))
                    }
                }
                if entries.isEmpty { CardBox { Muted("Sin eventos con este filtro.") } }
                ForEach(entries) { entry in LogRow(entry: entry) }
            }
            .padding(OCSpacing.contentMargin)
        }
    }
}

private struct LogRow: View {
    @EnvironmentObject private var store: AssistantStore
    let entry: AssistantLogEntry
    @State private var copied = false

    private var color: Color {
        switch entry.level {
        case .error: return OCColor.danger
        case .success: return OCColor.success
        case .tool: return violet
        case .info: return OCColor.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.level.rawValue).font(OCTypography.pillLabel).foregroundColor(color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
                Text(entry.tool).font(OCTypography.metaMono).foregroundColor(OCColor.textSecondary)
                Spacer()
                Text(entry.time, style: .time).font(.system(size: 11)).foregroundColor(OCColor.textFaint)
            }
            Text(entry.message).font(.system(size: 13)).foregroundColor(OCColor.textPrimary).textSelection(.enabled)
            HStack(spacing: 16) {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = entry.rawJSON
                    #endif
                    copied = true
                } label: { Label(copied ? "Copiado" : "Copiar", systemImage: "doc.on.doc") }
                if entry.retryable {
                    Button { store.retry(entry) } label: { Label("Reintentar", systemImage: "arrow.counterclockwise") }
                }
            }
            .font(.system(size: 13))
        }
        .padding(10)
        .ocCard(radius: 12, border: entry.level == .error ? OCColor.danger.opacity(0.5) : OCColor.borderBase)
    }
}

// MARK: - Opciones

private struct OptionsSection: View {
    @EnvironmentObject private var store: AssistantStore
    @AppStorage(IysAppearance.storageKey) private var appearance = IysAppearance.automatic.rawValue
    @State private var monitorDraft = ""
    @State private var clientDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardBox {
                    TitleText("Apariencia")
                    Muted("Automático sigue el modo claro u oscuro de tu iPhone.")
                    HStack(spacing: 6) {
                        ForEach(IysAppearance.allCases) { option in
                            Pill(title: option.title, selected: appearance == option.rawValue) { appearance = option.rawValue }
                        }
                    }
                }
                CardBox {
                    TitleText("Notificaciones")
                    Muted(store.notificationsAllowed ? "Activadas: te avisaremos de tareas de tu PC, correos nuevos y acciones confirmadas."
                          : "Desactivadas. Actívalas para recibir avisos.")
                    if !store.notificationsAllowed { PrimaryButton(title: "Permitir avisos") { store.requestNotifications() } }
                }
                CardBox {
                    HStack { Image(systemName: "bolt.fill").foregroundColor(OCColor.agentBuild); TitleText("Tu PC (iSyCode / IsyMCP)") }
                    Muted("El daemon de tu PC publica sus tareas en un archivo JSON (por ejemplo en raw.githubusercontent.com). El iPhone lo revisa cada 30 segundos mientras la app está abierta y te avisa de lo nuevo.")
                    InputField(label: "https://raw.githubusercontent.com/tu-usuario/…/tareas.json", text: $monitorDraft)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    Toggle(isOn: Binding(get: { store.monitorEnabled },
                                         set: { store.configureMonitor(url: monitorDraft, enabled: $0, watchGmail: store.watchGmail) })) {
                        VStack(alignment: .leading) { Text("Vigilar el manifiesto"); Muted("Estado: \(store.monitorStatus)") }
                    }
                    Toggle(isOn: Binding(get: { store.watchGmail },
                                         set: { store.configureMonitor(url: monitorDraft, enabled: store.monitorEnabled, watchGmail: $0) })) {
                        VStack(alignment: .leading) {
                            Text("Avisarme de correos nuevos")
                            Muted(store.granted(.gmail) ? "Revisa Gmail cada minuto" : "Requiere conectar Gmail")
                        }
                    }
                    if monitorDraft != store.monitorURL {
                        PrimaryButton(title: "Guardar dirección") {
                            store.configureMonitor(url: monitorDraft, enabled: store.monitorEnabled, watchGmail: store.watchGmail)
                        }
                    }
                }
                .tint(OCColor.agentBuild)
                CardBox {
                    TitleText("Google")
                    Muted("1. En console.cloud.google.com crea un ID de cliente OAuth de tipo iOS con el bundle dev.iyscode.movil.\n2. Habilita las APIs que quieras usar (Gmail, Calendar, Tasks…).\n3. Pega aquí el ID de cliente. La guía completa está en docs/GOOGLE_ASSISTANT.md.")
                    InputField(label: "ID de cliente (….apps.googleusercontent.com)", text: $clientDraft)
                        .textInputAutocapitalization(.never)
                    if clientDraft != store.clientId { PrimaryButton(title: "Guardar") { store.clientId = clientDraft.trimmingCharacters(in: .whitespaces) } }
                    Text("Servicios que pediremos").font(.system(size: 13, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                    ForEach(GoogleService.allCases) { service in
                        Toggle(isOn: Binding(get: { store.enabledServices.contains(service) }, set: { store.setService(service, enabled: $0) })) {
                            VStack(alignment: .leading) { Text(service.title); Muted(service.detail) }
                        }
                    }
                }
                .tint(OCColor.agentBuild)
                CardBox {
                    Toggle(isOn: Binding(get: { store.developerMode }, set: { store.setDeveloperMode($0) })) {
                        VStack(alignment: .leading) {
                            Text("Modo desarrollador")
                            Muted("Muestra el registro de eventos, el corpus de tools y los detalles técnicos.")
                        }
                    }
                    .tint(OCColor.agentBuild)
                }
                if store.developerMode {
                    sectionHeader("Corpus de tools", "Lo que GUS y cualquier modelo conectado pueden usar")
                    ForEach(AssistantCatalog.tools) { tool in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: tool.service?.symbol ?? "brain").foregroundColor(OCColor.agentBuild).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.id).font(OCTypography.toolLabel).foregroundColor(OCColor.textPrimary)
                                Muted(tool.description)
                                Muted(tool.endpoint, color: OCColor.textFaint)
                            }
                            Spacer()
                            Text(tool.mode.label).font(.system(size: 10, weight: .semibold))
                                .foregroundColor(tool.mode == .writeConfirmed ? Color.iys(dark: "FB923C", light: "C2410C") : OCColor.success)
                        }
                        .padding(10)
                        .ocCard(radius: 12)
                    }
                }
            }
            .padding(OCSpacing.contentMargin)
        }
        .onAppear {
            monitorDraft = store.monitorURL
            clientDraft = store.clientId
        }
    }
}

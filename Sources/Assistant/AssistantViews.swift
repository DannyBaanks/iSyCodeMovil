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

public struct AssistantConfirmActionSheet: View {
    @EnvironmentObject private var store: AssistantStore
    @State private var showTechnicalDetails = false
    let action: PendingAction

    public init(action: PendingAction) {
        self.action = action
    }

    public var body: some View {
        let formatted = HumanConfirmationFormatter.format(action: action)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(OCColor.warning)
                        Text("Confirmar acción")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OCColor.warning)
                    }

                    Text(formatted.headline)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(OCColor.textPrimary)
                        .accessibilityIdentifier("confirm-action-headline")

                    Muted(formatted.explanation)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(formatted.readableDetails.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0.uppercased())
                                    .font(OCTypography.metaMono)
                                    .foregroundColor(OCColor.textFaint)
                                Text(item.1)
                                    .font(.system(size: 15))
                                    .foregroundColor(OCColor.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.bgLayer1))

                    if let error = store.pendingError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(OCColor.danger)
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(OCColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(OCColor.danger.opacity(0.10)))
                        .accessibilityIdentifier("confirm-action-error")
                    }

                    DisclosureGroup("Detalles técnicos", isExpanded: $showTechnicalDetails) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(formatted.technicalDetails.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.0)
                                        .font(OCTypography.metaMono)
                                        .foregroundColor(OCColor.textFaint)
                                    Text(item.1)
                                        .font(OCTypography.codeSmall)
                                        .foregroundColor(OCColor.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(OCColor.textSecondary)
                }
                .padding(20)
            }
            .background(OCColor.bgBase.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Cancelar") { store.cancelPending() }
                        .disabled(store.running)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("confirm-action-cancel")
                    Spacer()
                    if store.running {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Ejecutando…")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(OCColor.textSecondary)
                        }
                    } else {
                        PrimaryButton(title: store.pendingError == nil ? "Confirmar" : "Reintentar") {
                            store.confirmPending()
                        }
                        .accessibilityIdentifier("confirm-action-submit")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(OCColor.bgBase)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(store.running)
        .onAppear { showTechnicalDetails = store.developerMode }
    }
}

private typealias ConfirmActionSheet = AssistantConfirmActionSheet

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
                sectionHeader("Qué puedes hacer", "Trabaja contigo, no a tus espaldas")
                HStack(spacing: 8) {
                    CapabilityCard(title: "Preguntar", detail: "Resumir y buscar con contexto", symbol: "sparkles")
                    CapabilityCard(title: "Leer", detail: "Google sin cambiar datos", symbol: "eye")
                    CapabilityCard(title: "Actuar", detail: "Siempre con confirmación", symbol: "lock")
                }
                Label("Proponer → confirmar → ejecutar", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OCColor.success)
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
                    StatusChip(text: store.signedIn ? "Google: conectado" : "Google: sin conectar", color: store.signedIn ? OCColor.success : OCColor.warning)
                    StatusChip(text: "Asistente: local", color: OCColor.success)
                    StatusChip(text: "Memoria: local · \(store.memory.count)", color: violet)
                    StatusChip(text: store.monitorStatus.hasPrefix("Conectado") ? "Equipo: conectado" : "Equipo: estado no verificado", color: store.monitorStatus.hasPrefix("Conectado") ? OCColor.success : OCColor.textFaint)
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

private struct CapabilityCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(OCColor.agentBuild)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(OCColor.textPrimary)
            Text(detail).font(.system(size: 11)).foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCard(radius: 14)
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

public struct AssistantMemorySectionView: View {
    @EnvironmentObject private var store: AssistantStore
    @AppStorage("assistant.memorySearchHistory") private var historyRaw = ""
    @State private var query = ""
    @State private var graphView = false
    @State private var focusedGraphNodeId: String?

    public init() {}

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    public var body: some View {
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
                    SemanticGraphCard(nodes: matches, requestedFocusId: $focusedGraphNodeId)
                } else {
                    ForEach(SemanticContext.buildTree(matches)) { folder in
                        FolderRow(folder: folder, expandAll: !query.isEmpty) { nodeId in
                            focusedGraphNodeId = nodeId
                            graphView = true
                        }
                    }
                }
                SaveMemoryCard()
                RetrievalProbe()
            }
            .padding(OCSpacing.contentMargin)
        }
        .onAppear {
            if store.preferGraph { graphView = true } else { store.reloadMemory() }
        }
    }

    private func remember(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        historyRaw = ([clean] + history.filter { $0 != clean }).prefix(8).joined(separator: "\n")
    }
}

private typealias MemorySection = AssistantMemorySectionView

private struct FolderRow: View {
    @EnvironmentObject private var store: AssistantStore
    let folder: TreeFolder
    let expandAll: Bool
    var onFocusInGraph: (String) -> Void = { _ in }
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
                ForEach(folder.subfolders) { FolderRow(folder: $0, expandAll: expandAll, onFocusInGraph: onFocusInGraph) }
                ForEach(folder.nodes) { MemoryNodeRow(node: $0, onFocusInGraph: onFocusInGraph) }
            }
        }
        .padding(.leading, CGFloat(folder.depth - 1) * 14)
    }
}

private struct MemoryNodeRow: View {
    @EnvironmentObject private var store: AssistantStore
    let node: ContextNode
    var onFocusInGraph: (String) -> Void = { _ in }
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(priorityColor(node.priority)).frame(width: 8, height: 8)
                Text(node.title).font(.system(size: 14, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                Spacer()
                Button { onFocusInGraph(node.id) } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 13)).foregroundColor(OCColor.textFaint)
                }
                .accessibilityLabel("Ver en grafo")
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
    @Binding var requestedFocusId: String?

    @State private var fullGraph = SemanticGraph(nodes: [], links: [])
    @State private var bridgeGraph = SemanticGraph(nodes: [], links: [])
    @State private var fullPositions: [String: CGPoint] = [:]
    @State private var bridgePositions: [String: CGPoint] = [:]
    @State private var scale: CGFloat = 1
    @State private var pinchStartScale: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var selectedId: String?
    @State private var showLegend = true
    @State private var showHelp = false
    @State private var bridgesOnly = false
    @State private var seed = 0
    @State private var dragging: String?
    @State private var lastDrag: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var userAdjustedCamera = false

    private var activeGraph: SemanticGraph { bridgesOnly ? bridgeGraph : fullGraph }
    private var activePositions: [String: CGPoint] { bridgesOnly ? bridgePositions : fullPositions }
    private var semanticLinkCount: Int { fullGraph.links.filter { $0.kind == .semantic }.count }
    private var contextCount: Int { fullGraph.nodes.filter { $0.kind == .context }.count }

    private let canvasBg = Color.iys(dark: "0B0C14", light: "F4F2FA")
    private let pillBg = Color.iys(dark: "131522", light: "FFFFFF").opacity(0.92)
    private let bridgeGold = Color.iys(dark: "FBBF24", light: "B45309")

    var body: some View {
        CardBox {
            headerBar
            filterBar
            if showHelp {
                Muted("Toca un nodo para enfocar sus conexiones · Arrastra círculos o fondo · Pellizca para zoom.", color: OCColor.textFaint)
            }
            graphViewport
            if let id = selectedId, let node = fullGraph.nodes.first(where: { $0.id == id }) {
                detail(node)
            }
            if showLegend { legend }
        }
        .onAppear {
            rebuild(preserveExisting: false)
            consumeRequestedFocus()
        }
        .onChange(of: nodes.map(\.id)) { _ in
            rebuild(preserveExisting: false)
            consumeRequestedFocus()
        }
        .onChange(of: requestedFocusId) { _ in
            consumeRequestedFocus()
        }
        .onChange(of: bridgesOnly) { _ in
            userAdjustedCamera = false
            withAnimation(.easeOut(duration: 0.2)) {
                if let id = selectedId, !activeGraph.nodes.contains(where: { $0.id == id }) {
                    selectedId = nil
                }
                fitGraph(to: canvasSize)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                TitleText("Constelación")
                Text("\(contextCount) \(contextCount == 1 ? "nota" : "notas") · \(semanticLinkCount) \(semanticLinkCount == 1 ? "puente" : "puentes")")
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass").font(.system(size: 13)) }
                    .accessibilityLabel("Alejar")
                Button {
                    userAdjustedCamera = false
                    withAnimation(.easeOut(duration: 0.2)) { fitGraph(to: canvasSize) }
                } label: {
                    Text("\(Int(scale * 100))%").font(OCTypography.metaMono).foregroundColor(OCColor.textSecondary)
                        .frame(minWidth: 38)
                }
                .accessibilityLabel("Ajustar vista")
                Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass").font(.system(size: 13)) }
                    .accessibilityLabel("Acercar")
                Button {
                    userAdjustedCamera = false
                    withAnimation(.easeOut(duration: 0.2)) { fitGraph(to: canvasSize) }
                } label: { Image(systemName: "scope").font(.system(size: 13)) }
                    .accessibilityLabel("Centrar grafo")
                Button {
                    seed += 1
                    userAdjustedCamera = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        if bridgesOnly {
                            bridgePositions = SemanticContext.layout(bridgeGraph, seed: seed)
                        } else {
                            fullPositions = SemanticContext.layout(fullGraph, seed: seed)
                        }
                        fitGraph(to: canvasSize)
                    }
                } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)) }
                    .accessibilityLabel("Reorganizar")
                Button { withAnimation(.easeInOut(duration: 0.15)) { showHelp.toggle() } } label: {
                    Image(systemName: showHelp ? "questionmark.circle.fill" : "questionmark.circle").font(.system(size: 13))
                }
                .accessibilityLabel("Ayuda de gestos")
            }
            .foregroundColor(OCColor.agentBuild)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Pill(title: "Todo", selected: !bridgesOnly) { bridgesOnly = false }
                Pill(title: "Puentes (\(semanticLinkCount))", selected: bridgesOnly) { bridgesOnly = true }
                Pill(title: "Leyenda", selected: showLegend) { showLegend.toggle() }
            }
        }
    }

    private var graphViewport: some View {
        GeometryReader { geo in
            ZStack {
                canvas(size: geo.size)
                if bridgesOnly && bridgeGraph.links.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 24))
                            .foregroundColor(bridgeGold)
                        Text("Aún no hay puentes entre ramas")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                        Muted("Guarda dos notas con conceptos clave compartidos en distintas ramas para enlazarlas.")
                            .multilineTextAlignment(.center)
                        Pill(title: "Ver constelación", selected: true) { bridgesOnly = false }
                    }
                    .padding(18)
                }
            }
            .onAppear {
                canvasSize = geo.size
                if !userAdjustedCamera && geo.size.width > 64 {
                    fitGraph(to: geo.size)
                }
            }
            .onChange(of: geo.size) { newSize in
                canvasSize = newSize
                if !userAdjustedCamera && newSize.width > 64 {
                    fitGraph(to: newSize)
                }
            }
        }
        .frame(height: 360)
        .background(RoundedRectangle(cornerRadius: 16).fill(canvasBg))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OCColor.borderMuted, lineWidth: 1))
    }

    private func rebuild(preserveExisting: Bool) {
        let built = SemanticContext.buildGraph(nodes)
        let bridged = SemanticContext.bridgeSubgraph(from: built)
        fullGraph = built
        bridgeGraph = bridged
        if !preserveExisting {
            fullPositions = SemanticContext.layout(built, seed: seed)
            bridgePositions = SemanticContext.layout(bridged, seed: seed)
            userAdjustedCamera = false
        }
        if let id = selectedId, !built.nodes.contains(where: { $0.id == id }) { selectedId = nil }
        if !userAdjustedCamera && canvasSize.width > 64 {
            fitGraph(to: canvasSize)
        }
    }

    private func consumeRequestedFocus() {
        guard let target = requestedFocusId else { return }
        requestedFocusId = nil
        guard fullGraph.nodes.contains(where: { $0.id == target }) else { return }
        if bridgesOnly && !bridgeGraph.nodes.contains(where: { $0.id == target }) {
            bridgesOnly = false
        }
        withAnimation(.easeOut(duration: 0.22)) {
            focusNode(target)
        }
    }

    private func focusNode(_ id: String) {
        userAdjustedCamera = true
        selectedId = id
        if let p = activePositions[id] {
            pan = CGSize(width: -p.x, height: -p.y)
            if scale < 1.05 { scale = 1.05 }
        }
    }

    private func zoom(by factor: CGFloat) {
        userAdjustedCamera = true
        withAnimation(.easeOut(duration: 0.15)) {
            scale = min(3.0, max(0.45, scale * factor))
        }
    }

    private func fitGraph(to size: CGSize) {
        let visiblePos = activeGraph.nodes.compactMap { activePositions[$0.id] }
        guard !visiblePos.isEmpty else {
            pan = .zero
            scale = 1
            return
        }
        let minX = visiblePos.map(\.x).min() ?? 0
        let maxX = visiblePos.map(\.x).max() ?? 0
        let minY = visiblePos.map(\.y).min() ?? 0
        let maxY = visiblePos.map(\.y).max() ?? 0
        pan = CGSize(width: -(minX + maxX) / 2, height: -(minY + maxY) / 2)
        guard size.width > 96, size.height > 96 else {
            scale = 1
            return
        }
        let spanX = max(80, maxX - minX)
        let spanY = max(80, maxY - minY)
        let fitX = (size.width - 80) / spanX
        let fitY = (size.height - 70) / spanY
        scale = min(1.15, max(0.65, min(fitX, fitY)))
    }

    private func color(_ node: GraphNode) -> Color {
        switch node.kind {
        case .domain: return violet
        case .cluster: return OCColor.agentBuild
        case .context: return priorityColor(node.priority)
        }
    }

    private func visualRadius(_ node: GraphNode) -> CGFloat {
        switch node.kind {
        case .domain: return 17 * scale
        case .cluster: return 10 * scale
        case .context:
            let base: CGFloat = node.priority == .critical ? 9.5 : node.priority == .high ? 8.2 : 7.2
            return base * scale
        }
    }

    private func screen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x + pan.width) * scale, y: size.height / 2 + (p.y + pan.height) * scale)
    }

    private func hit(_ location: CGPoint, _ size: CGSize) -> GraphNode? {
        let priorityOrder: [GraphNode] = activeGraph.nodes.sorted { lhs, rhs in
            let rank: (GraphNodeKind) -> Int = { kind in
                switch kind {
                case .context: return 0
                case .cluster: return 1
                case .domain: return 2
                }
            }
            return rank(lhs.kind) < rank(rhs.kind)
        }
        var bestMatch: (node: GraphNode, rank: Int, dist: CGFloat)?
        for node in priorityOrder {
            guard let world = activePositions[node.id] else { continue }
            let s = screen(world, size)
            let d = hypot(s.x - location.x, s.y - location.y)
            let threshold = max(24, visualRadius(node) + 12)
            guard d <= threshold else { continue }
            let r = node.kind == .context ? 0 : node.kind == .cluster ? 1 : 2
            if let current = bestMatch {
                if r < current.rank || (r == current.rank && d < current.dist) {
                    bestMatch = (node, r, d)
                }
            } else {
                bestMatch = (node, r, d)
            }
        }
        return bestMatch?.node
    }

    private func bridgeGeometry(from a: CGPoint, to b: CGPoint, center: CGPoint) -> (control: CGPoint, midpoint: CGPoint, normal: CGPoint) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max(1, hypot(dx, dy))
        var nx = -dy / dist, ny = dx / dist
        if (mid.x - center.x) * nx + (mid.y - center.y) * ny < 0 {
            nx = -nx; ny = -ny
        }
        let arch = min(28 * scale, dist * 0.2)
        let ctrl = CGPoint(x: mid.x + nx * arch, y: mid.y + ny * arch)
        let curveMid = CGPoint(x: 0.25 * a.x + 0.5 * ctrl.x + 0.25 * b.x, y: 0.25 * a.y + 0.5 * ctrl.y + 0.25 * b.y)
        return (ctrl, curveMid, CGPoint(x: nx, y: ny))
    }

    private func canvas(size: CGSize) -> some View {
        let graph = activeGraph
        let positions = activePositions
        let neighbors: Set<String>? = selectedId.map { id in
            Set(graph.links.filter { $0.source == id || $0.target == id }.flatMap { [$0.source, $0.target] })
        }
        let noteCount = graph.nodes.filter { $0.kind == .context }.count
        let semanticTotal = graph.links.filter { $0.kind == .semantic }.count

        return Canvas { context, canvasSize in
            let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            var domainCentroids: [String: CGPoint] = [:]

            // 1. Subtle framed domain halos (only in "Todo" mode).
            if !bridgesOnly {
                for hub in graph.nodes where hub.kind == .domain {
                    let members = graph.nodes.filter { $0.domain == hub.domain }.compactMap { positions[$0.id] }
                    guard !members.isEmpty else { continue }
                    let cx = members.map(\.x).reduce(0, +) / CGFloat(members.count)
                    let cy = members.map(\.y).reduce(0, +) / CGFloat(members.count)
                    let center = screen(CGPoint(x: cx, y: cy), canvasSize)
                    domainCentroids[hub.domain] = center
                    let maxReach = members.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 0
                    let r = min(canvasSize.width * 0.44, (maxReach + 22) * scale)
                    let focusedDomain = selectedId.flatMap { id in graph.nodes.first(where: { $0.id == id })?.domain } == hub.domain
                    let haloRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    let haloPath = Path(ellipseIn: haloRect)
                    context.fill(haloPath, with: .color(color(hub).opacity(focusedDomain ? 0.085 : 0.035)))
                    context.stroke(haloPath, with: .color(color(hub).opacity(focusedDomain ? 0.36 : 0.14)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }
            }

            // 2. Hierarchy links first, then curved semantic bridges on top.
            var bridgeBadges: [(point: CGPoint, normal: CGPoint, text: String, priority: Bool)] = []
            for link in graph.links where link.kind == .hierarchy {
                guard let a = positions[link.source], let b = positions[link.target] else { continue }
                let lit = selectedId == nil || link.source == selectedId || link.target == selectedId
                var path = Path()
                path.move(to: screen(a, canvasSize))
                path.addLine(to: screen(b, canvasSize))
                context.stroke(path, with: .color(OCColor.textFaint.opacity(lit ? 0.45 : 0.10)), lineWidth: lit ? 1.25 : 0.9)
            }
            for link in graph.links where link.kind == .semantic {
                guard let a = positions[link.source], let b = positions[link.target] else { continue }
                let pA = screen(a, canvasSize), pB = screen(b, canvasSize)
                let lit = selectedId == nil || link.source == selectedId || link.target == selectedId
                let (ctrl, curveMid, normal) = bridgeGeometry(from: pA, to: pB, center: canvasCenter)
                var path = Path()
                path.move(to: pA)
                path.addQuadCurve(to: pB, control: ctrl)
                let width = CGFloat(lit ? 1.8 + min(1.0, Double(max(0, link.strength - 1)) * 0.4) : 1.1)
                if lit {
                    context.stroke(path, with: .color(bridgeGold.opacity(0.18)), lineWidth: width + 3.5)
                }
                context.stroke(path, with: .color(bridgeGold.opacity(lit ? 0.92 : 0.15)),
                               style: StrokeStyle(lineWidth: width, dash: [6, 4]))

                let isSelectedEdge = selectedId != nil && (link.source == selectedId || link.target == selectedId)
                if lit && (bridgesOnly || isSelectedEdge || semanticTotal <= 3) {
                    let clean = link.label.replacingOccurrences(of: "Comparten: ", with: "")
                    let badge = clean.count > 22 ? String(clean.prefix(20)) + "…" : clean
                    bridgeBadges.append((curveMid, normal, badge, isSelectedEdge || bridgesOnly))
                }
            }

            // 3. Reserve node circles in 2D occupied-rect table so labels never collide with dots.
            var occupiedRects: [CGRect] = []
            for node in graph.nodes {
                guard let p = positions[node.id] else { continue }
                let c = screen(p, canvasSize)
                let r = visualRadius(node)
                let dim = neighbors.map { !$0.contains(node.id) } ?? false
                occupiedRects.append(CGRect(x: c.x - r - 3, y: c.y - r - 3, width: r * 2 + 6, height: r * 2 + 6))

                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                let tint = color(node).opacity(dim ? 0.25 : 1)
                if node.kind == .context {
                    if !dim && (node.priority == .critical || node.id == selectedId) {
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(tint.opacity(0.24)))
                    }
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -1.8, dy: -1.8)), with: .color(canvasBg))
                    context.fill(Path(ellipseIn: rect), with: .color(tint))
                } else {
                    // Solid canvas fill erases underlying edge lines inside hollow domain/branch rings.
                    context.fill(Path(ellipseIn: rect), with: .color(canvasBg))
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(dim ? 0.08 : 0.16)))
                    context.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: node.kind == .domain ? 2.2 : 1.6)
                    if node.kind == .domain {
                        let countText = context.resolve(
                            Text("\(node.childCount)")
                                .font(.system(size: max(9, 10 * min(1.2, scale)), weight: .bold, design: .monospaced))
                                .foregroundColor(tint)
                        )
                        context.draw(countText, at: c, anchor: .center)
                    } else {
                        let core = CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8)
                        context.fill(Path(ellipseIn: core), with: .color(tint))
                    }
                }
                if node.id == selectedId {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(OCColor.textPrimary), lineWidth: 1.8)
                }
            }

            // 4. Node labels ordered by visual priority with 2D non-overlapping capsule pills.
            let orderedForLabels = graph.nodes.sorted { a, b in
                let rank: (GraphNode) -> Int = { n in
                    if n.id == selectedId { return 0 }
                    if neighbors?.contains(n.id) == true { return 1 }
                    switch n.kind {
                    case .domain: return 2
                    case .context: return 3 + (n.priority == .critical ? 0 : n.priority == .high ? 1 : 2)
                    case .cluster: return 6
                    }
                }
                return rank(a) < rank(b)
            }

            for node in orderedForLabels {
                guard let p = positions[node.id] else { continue }
                let dim = neighbors.map { !$0.contains(node.id) } ?? false
                if dim { continue }

                let isSelected = node.id == selectedId
                let isNeighbor = neighbors?.contains(node.id) ?? false
                let shouldShow: Bool
                switch node.kind {
                case .domain:
                    shouldShow = true
                case .context:
                    shouldShow = noteCount <= 14 || scale >= 1.05 || isSelected || isNeighbor
                case .cluster:
                    shouldShow = isSelected || isNeighbor || scale >= 1.25
                }
                guard shouldShow else { continue }

                let c = screen(p, canvasSize)
                let r = visualRadius(node)
                let maxChars = node.kind == .domain ? 24 : 22
                let label = node.label.count > maxChars ? String(node.label.prefix(maxChars - 2)) + "…" : node.label
                let fontSize: CGFloat = node.kind == .domain ? 10.5 : node.kind == .context ? 9.8 : 9.0
                let weight: Font.Weight = node.kind == .domain ? .bold : node.kind == .context ? .semibold : .medium
                let labelColor = node.kind == .cluster && !isSelected ? OCColor.textSecondary : OCColor.textPrimary

                let resolved = context.resolve(Text(label).font(.system(size: fontSize, weight: weight)).foregroundColor(labelColor))
                let textSize = resolved.measure(in: CGSize(width: 170, height: 28))
                let boxW = textSize.width + 10
                let boxH = textSize.height + 4
                let domainCenter = domainCentroids[node.domain] ?? canvasCenter
                let preferAbove = c.y < domainCenter.y - 6

                guard let chosen = placeLabelRect(
                    center: c, radius: r, size: CGSize(width: boxW, height: boxH),
                    canvasSize: canvasSize, preferAbove: preferAbove,
                    allowFallback: isSelected || node.kind == .domain || (node.kind == .context && noteCount <= 6),
                    occupied: occupiedRects
                ) else { continue }

                occupiedRects.append(chosen)
                let pillPath = Path(roundedRect: chosen, cornerRadius: 6)
                context.fill(pillPath, with: .color(pillBg))
                let border = isSelected ? OCColor.textPrimary : (node.kind == .domain ? color(node).opacity(0.55) : OCColor.borderMuted.opacity(0.8))
                context.stroke(pillPath, with: .color(border), lineWidth: isSelected ? 1.2 : 0.8)
                context.draw(resolved, at: CGPoint(x: chosen.midX, y: chosen.midY), anchor: .center)
            }

            // 5. Bridge keyword pills placed along curve midpoint with normal nudges to avoid collisions.
            for badge in bridgeBadges {
                let resolved = context.resolve(
                    Text(badge.text)
                        .font(.system(size: 8.8, weight: .semibold, design: .monospaced))
                        .foregroundColor(bridgeGold)
                )
                let textSize = resolved.measure(in: CGSize(width: 150, height: 24))
                let boxW = textSize.width + 10
                let boxH = textSize.height + 4
                let shifts: [CGFloat] = [0, 14, -14, 24, -24, 34, -34]
                let candidates = shifts.map { s -> CGRect in
                    let p = CGPoint(x: badge.point.x + badge.normal.x * s, y: badge.point.y + badge.normal.y * s)
                    return CGRect(
                        x: min(max(6, p.x - boxW / 2), canvasSize.width - 6 - boxW),
                        y: min(max(6, p.y - boxH / 2), canvasSize.height - 6 - boxH),
                        width: boxW, height: boxH
                    )
                }
                let chosenBadge = candidates.first(where: { r in
                    !occupiedRects.contains(where: { $0.intersects(r.insetBy(dx: -2, dy: -2)) })
                }) ?? (badge.priority ? candidates.first : nil)
                guard let raw = chosenBadge else { continue }
                occupiedRects.append(raw)
                let pill = Path(roundedRect: raw, cornerRadius: 5)
                context.fill(pill, with: .color(pillBg))
                context.stroke(pill, with: .color(bridgeGold.opacity(0.6)), lineWidth: 0.8)
                context.draw(resolved, at: CGPoint(x: raw.midX, y: raw.midY), anchor: .center)
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
                        let current = activePositions[id] ?? .zero
                        let moved = CGPoint(x: current.x + delta.width / scale, y: current.y + delta.height / scale)
                        if bridgesOnly { bridgePositions[id] = moved } else { fullPositions[id] = moved }
                    } else {
                        userAdjustedCamera = true
                        pan = CGSize(width: pan.width + delta.width / scale, height: pan.height + delta.height / scale)
                    }
                }
                .onEnded { _ in dragging = nil; lastDrag = .zero }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                withAnimation(.easeOut(duration: 0.18)) {
                    if let tapped = hit(value.location, size) {
                        selectedId = (selectedId == tapped.id) ? nil : tapped.id
                    } else {
                        selectedId = nil
                    }
                }
            }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    userAdjustedCamera = true
                    if pinchStartScale == nil { pinchStartScale = scale }
                    scale = min(3.0, max(0.45, (pinchStartScale ?? scale) * value))
                }
                .onEnded { _ in pinchStartScale = nil }
        )
    }

    private func placeLabelRect(center: CGPoint, radius: CGFloat, size: CGSize, canvasSize: CGSize,
                                preferAbove: Bool, allowFallback: Bool, occupied: [CGRect]) -> CGRect? {
        let w = size.width, h = size.height
        var ringCandidates: [CGRect] = []
        for gap in [CGFloat(5), CGFloat(11)] {
            let below = CGPoint(x: center.x - w / 2, y: center.y + radius + gap)
            let above = CGPoint(x: center.x - w / 2, y: center.y - radius - gap - h)
            let right = CGPoint(x: center.x + radius + gap, y: center.y - h / 2)
            let left = CGPoint(x: center.x - radius - gap - w, y: center.y - h / 2)
            let belowRight = CGPoint(x: center.x - 4, y: center.y + radius + gap)
            let belowLeft = CGPoint(x: center.x + 4 - w, y: center.y + radius + gap)
            let aboveRight = CGPoint(x: center.x - 4, y: center.y - radius - gap - h)
            let aboveLeft = CGPoint(x: center.x + 4 - w, y: center.y - radius - gap - h)
            let ordered = preferAbove
                ? [above, below, right, left, aboveRight, aboveLeft, belowRight, belowLeft]
                : [below, above, right, left, belowRight, belowLeft, aboveRight, aboveLeft]
            let clamped = ordered.map { origin in
                CGRect(
                    x: min(max(6, origin.x), max(6, canvasSize.width - 6 - w)),
                    y: min(max(6, origin.y), max(6, canvasSize.height - 6 - h)),
                    width: w, height: h
                )
            }
            if let clear = clamped.first(where: { candidate in
                !occupied.contains(where: { $0.intersects(candidate.insetBy(dx: -2, dy: -2)) })
            }) {
                return clear
            }
            if ringCandidates.isEmpty { ringCandidates = clamped } else { ringCandidates.append(contentsOf: clamped) }
        }
        guard allowFallback else { return nil }
        return ringCandidates.min { lhs, rhs in
            let overlapArea: (CGRect) -> CGFloat = { candidate in
                occupied.reduce(0) { sum, other in
                    let inter = candidate.intersection(other)
                    return sum + (inter.isNull ? 0 : inter.width * inter.height)
                }
            }
            return overlapArea(lhs) < overlapArea(rhs)
        }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
            legendRow(priorityColor(.critical), "Crítica")
            legendRow(priorityColor(.high), "Alta")
            legendRow(priorityColor(.normal), "Normal")
            legendRow(violet, "Dominio", ring: true)
            legendRow(OCColor.agentBuild, "Rama", ring: true)
            HStack(spacing: 6) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 5))
                    p.addLine(to: CGPoint(x: 14, y: 5))
                }
                .stroke(bridgeGold, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                .frame(width: 14, height: 10)
                Text("Puente").font(.system(size: 11)).foregroundColor(OCColor.textPrimary)
            }
        }
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
        let related = fullGraph.links.filter { $0.source == node.id || $0.target == node.id }
            .sorted { ($0.kind == .semantic ? 0 : 1) < ($1.kind == .semantic ? 0 : 1) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if node.kind == .context {
                    Circle().fill(color(node)).frame(width: 10, height: 10)
                } else {
                    Circle().stroke(color(node), lineWidth: 2).frame(width: 10, height: 10)
                }
                Text(node.label).font(.system(size: 15, weight: .semibold)).foregroundColor(OCColor.textPrimary)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selectedId = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(OCColor.textFaint)
                }
                .accessibilityLabel("Cerrar detalle")
            }
            Muted(node.path.joined(separator: " › "), color: OCColor.agentBuild)
            Muted(node.summary)
            if !related.isEmpty {
                Text("Conectado con").font(.system(size: 12, weight: .semibold)).foregroundColor(OCColor.textSecondary)
                ForEach(Array(related.enumerated()), id: \.offset) { _, link in
                    let otherId = link.source == node.id ? link.target : link.source
                    if let other = fullGraph.nodes.first(where: { $0.id == otherId }) {
                        let isSemantic = link.kind == .semantic
                        Button {
                            withAnimation(.easeOut(duration: 0.22)) {
                                if bridgesOnly && !bridgeGraph.nodes.contains(where: { $0.id == other.id }) {
                                    bridgesOnly = false
                                }
                                focusNode(other.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSemantic ? "sparkles" : "folder")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isSemantic ? bridgeGold : OCColor.textFaint)
                                Text(other.label).font(.system(size: 13, weight: .medium)).foregroundColor(OCColor.textPrimary).lineLimit(1)
                                Spacer()
                                Text(isSemantic ? link.label.replacingOccurrences(of: "Comparten: ", with: "") : "carpeta")
                                    .font(.system(size: 11, design: isSemantic ? .monospaced : .default))
                                    .foregroundColor(isSemantic ? bridgeGold : OCColor.textFaint)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(OCColor.bgLayer1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.bgLayer1.opacity(0.65)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OCColor.borderMuted, lineWidth: 1))
    }
}

// MARK: - Google

public struct AssistantGoogleSectionView: View {
    @EnvironmentObject private var store: AssistantStore
    var onOpenOAuthSetup: (() -> Void)? = nil

    public init(onOpenOAuthSetup: (() -> Void)? = nil) {
        self.onOpenOAuthSetup = onOpenOAuthSetup
    }

    public var body: some View {
        let googleState = store.googleConnectionState
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardBox {
                    HStack(spacing: 8) {
                        Image(systemName: googleState.symbol)
                            .foregroundColor(googleState.tone.semanticColor)
                        Text(googleState.badgeText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(googleState.tone.semanticColor)
                        Spacer()
                    }
                    TitleText(store.signedIn ? "Cuenta de Google" : "Conecta tu cuenta de Google")
                    if case .expired = googleState {
                        Muted("Tu sesión de Google caducó o fue revocada. Vuelve a iniciar sesión para restaurar las herramientas.", color: OCColor.warning)
                        PrimaryButton(title: "Volver a conectar") { store.signIn() }
                            .accessibilityIdentifier("google-reconnect-button")
                    } else if store.signedIn {
                        Muted(store.email ?? "Conectada")
                        Muted("Permisos: " + (GoogleService.allCases.filter(store.granted).map(\.title).joined(separator: ", ").nilIfEmpty ?? "ninguno"))
                        HStack(spacing: 12) {
                            PrimaryButton(title: "Actualizar todo") { store.refreshAll() }
                            Button("Reconectar") { store.signIn() }.font(.system(size: 14, weight: .semibold))
                            Button("Desconectar", role: .destructive) { store.signOut() }.font(.system(size: 14))
                        }
                    } else {
                        Muted("Inicias sesión en la página de Google, con tu propio proyecto. El token se queda en el llavero de este iPhone y puedes desconectarlo cuando quieras.")
                        if GoogleOAuth.isPlausibleClientId(store.clientId) {
                            PrimaryButton(title: "Iniciar sesión con Google") { store.signIn() }
                                .accessibilityIdentifier("google-connect-button")
                        } else {
                            Muted(store.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Antes de conectar, pega tu ID de cliente OAuth de tipo iOS."
                                : "El ID no tiene el formato esperado. Pega solo el ID que termina en .apps.googleusercontent.com, sin http:// ni una URL.",
                                  color: Color.iys(dark: "FB923C", light: "C2410C"))
                            if let onOpenOAuthSetup {
                                PrimaryButton(title: "Configurar ID de cliente OAuth") { onOpenOAuthSetup() }
                                    .accessibilityIdentifier("google-oauth-setup-button")
                            } else {
                                PrimaryButton(title: "Configurar en Opciones › Google") { store.section = .options }
                                    .accessibilityIdentifier("google-oauth-setup-button")
                            }
                        }
                    }
                    Muted("Nota: esta conexión OAuth da acceso a Google Workspace (Gmail, Calendar, Tasks, Drive). Para usar modelos de Gemini, configura una API key en Motor de IA.", color: OCColor.textFaint)
                }
                if store.signedIn {
                    ForEach(store.enabledServices) { ServiceCard(service: $0) }
                }
            }
            .padding(OCSpacing.contentMargin)
        }
    }
}

private typealias GoogleSection = AssistantGoogleSectionView

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
                VStack(alignment: .leading, spacing: 8) {
                    Muted("Falta autorización para \(service.title).", color: Color.iys(dark: "FB923C", light: "C2410C"))
                    PrimaryButton(title: "Autorizar \(service.title)") {
                        store.authorizeService(service)
                    }
                    .accessibilityIdentifier("google-authorize-\(service.rawValue.lowercased())")
                }
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

public struct AssistantLogSectionView: View {
    @EnvironmentObject private var store: AssistantStore
    @State private var filter: AssistantLogLevel?

    public init() {}

    public var body: some View {
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

private typealias LogSection = AssistantLogSectionView

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

public struct AssistantOptionsSectionView: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.openURL) private var openURL
    @AppStorage(IysAppearance.storageKey) private var appearance = IysAppearance.automatic.rawValue
    @State private var monitorDraft = ""
    @State private var clientDraft = ""
    @State private var copiedBundleIdentifier = false

    public init() {}

    private var appBundleIdentifier: String { Bundle.main.bundleIdentifier ?? "dev.iyscode.movil" }

    public var body: some View {
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
                    Muted("Abre Google Cloud y crea un cliente OAuth de tipo iOS. Usa el ID de paquete de abajo; al terminar, pega aquí el ID de cliente que te dé Google.")
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Muted("ID del paquete iOS")
                            Text(appBundleIdentifier)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(OCColor.textPrimary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 4)
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = appBundleIdentifier
                            copiedBundleIdentifier = true
                            #endif
                        } label: {
                            Label(copiedBundleIdentifier ? "Copiado" : "Copiar",
                                  systemImage: copiedBundleIdentifier ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(OCColor.agentBuild)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(OCColor.agentBuildSoft))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(copiedBundleIdentifier ? "Identificador de paquete copiado" : "Copiar identificador de paquete")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(OCColor.bgLayer1))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(OCColor.borderMuted, lineWidth: 1))
                    PrimaryButton(title: "Abrir Google Cloud Console") {
                        guard let url = URL(string: "https://console.cloud.google.com/auth/clients") else { return }
                        openURL(url) { accepted in
                            store.message = accepted
                                ? "Google Cloud se abrió. Crea un cliente OAuth de tipo iOS y pega aquí el ID que te dé."
                                : "No pude abrir Google Cloud Console. Comprueba tu conexión e inténtalo otra vez."
                        }
                    }
                    Muted("Después, habilita las APIs de los servicios que quieras usar y toca Iniciar sesión con Google. Guía: docs/GOOGLE_ASSISTANT.md.")
                    InputField(label: "ID de cliente (….apps.googleusercontent.com)", text: $clientDraft)
                        .textInputAutocapitalization(.never)
                    if !clientDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !GoogleOAuth.isPlausibleClientId(clientDraft) {
                        Muted("Formato no válido. Usa solo el ID OAuth de tipo iOS, sin http://, espacios ni una URL completa.",
                              color: Color.iys(dark: "FB923C", light: "C2410C"))
                    }
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

private typealias OptionsSection = AssistantOptionsSectionView

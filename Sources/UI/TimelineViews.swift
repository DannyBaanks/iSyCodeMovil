import SwiftUI

// MARK: - Timeline Event Container

public struct TimelineEventContainer: View {
    let event: TimelineEvent
    let showsSpeaker: Bool
    let isLiveTail: Bool
    /// Set on the last answer of a finished turn: the prompt "Reintentar" sends again.
    let turnPrompt: String?
    @EnvironmentObject private var store: WorkbenchStore

    public init(event: TimelineEvent, showsSpeaker: Bool = true, turnPrompt: String? = nil, isLiveTail: Bool = false) {
        self.event = event
        self.isLiveTail = isLiveTail
        self.showsSpeaker = showsSpeaker
        self.turnPrompt = turnPrompt
    }

    private var agentColor: Color {
        event.agentMode?.color ?? OCColor.agentBuild
    }

    // NOTA: en iOS 26 SDK `Group { switch ... }` colisiona con el overload
    // `Group.init<R, C>(@TableColumnBuilder)` y no compila. El switch se
    // extrae a un @ViewBuilder (buildEither) y el padding se aplica fuera.
    @ViewBuilder private var eventContent: some View {
        switch event.kind {
        case .userPrompt:
            UserPromptView(event: event, agentColor: agentColor)
        case .assistantText:
            AssistantTextView(event: event, showsSpeaker: showsSpeaker, turnPrompt: turnPrompt, isLiveTail: isLiveTail)
        case .toolCall, .toolResult:
            ToolCallView(event: event, agentColor: agentColor)
        case .diff:
            DiffView(event: event)
        case .codeBlock:
            CodeBlockView(event: event)
        case .thinking:
            ThinkingView(event: event, agentColor: agentColor)
        case .todo:
            TodoView(event: event, agentColor: agentColor)
        case .permission:
            PermissionView(
                event: event,
                onAllow: { store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowOnce) },
                onDeny: { store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: event.permissionTool?.hasPrefix("Codex") == true ? .decline : .deny) },
                onPersistent: { store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowAlways) },
                onCodexCancel: { store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .cancel) },
                onSequence: { store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowSequence) }
            )
        case .question:
            QuestionView(
                event: event,
                onSelect: { choice in store.respondToPermission(requestId: event.id, decision: .allowOnce) },
                onFreeform: { text in store.sendPrompt(text) }
            )
        case .system:
            SystemMessageView(event: event)
        }
    }

    public var body: some View {
        eventContent
            .padding(.vertical, OCSpacing.xs)
    }
}

// MARK: - User Prompt View

public struct UserPromptView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    /// The person's turn is a single trailing bubble, as in Messages: no avatar, no
    /// "Tú" label and no clock on every message. Alignment already says who wrote it.
    public var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Bubble at most ~80% of the column (294 of 358 pt on a 390 pt iPhone), between
            // ChatGPT's 275 and Claude's 318 measured on the same phone.
            Spacer(minLength: 64)

            VStack(alignment: .trailing, spacing: OCSpacing.base) {
                if let text = event.promptText {
                    MarkdownText(
                        content: text,
                        emphasisColor: agentColor,
                        emphasisKey: "prompt-\(event.agentMode?.rawValue ?? "build")"
                    )
                    .equatable()
                    .font(OCTypography.userPrompt)
                    .foregroundColor(OCColor.textPrimary)
                }

                if let attachments = event.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: OCSpacing.xs) {
                            ForEach(attachments) { attachment in
                                AttachmentToken(attachment: attachment)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .padding(.horizontal, OCSpacing.lg + 2)
            .padding(.vertical, OCSpacing.md)
            .background(OCColor.bgLayer2)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r22, style: .continuous))
            .contextMenu {
                if let text = event.promptText, !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        OCHaptics.light()
                    } label: {
                        Label("Copiar mensaje", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: text) { Label("Compartir", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, OCSpacing.xl)
        .padding(.bottom, OCSpacing.xs)
    }
}

// MARK: - Assistant Text View

public struct AssistantTextView: View {
    let event: TimelineEvent
    /// Only the first assistant message of a turn carries the speaker row; the rest of
    /// the turn reads as one continuous answer.
    let showsSpeaker: Bool
    let isLiveTail: Bool
    let turnPrompt: String?
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @State private var copied = false

    public init(event: TimelineEvent, showsSpeaker: Bool = true, turnPrompt: String? = nil, isLiveTail: Bool = false) {
        self.event = event
        self.isLiveTail = isLiveTail
        self.showsSpeaker = showsSpeaker
        self.turnPrompt = turnPrompt
    }

    private var speakerLabel: String {
        switch sessionState.selectedModel?.route {
        case "codex": return "Codex"
        case "grok": return "Grok"
        default: return "iSyCode"
        }
    }

    private var speakerSymbol: String {
        let route = sessionState.selectedModel?.route
        return route == "codex" || route == "grok" ? "chevron.left.forwardslash.chevron.right" : "sparkle"
    }

    /// The answer sits on the page with no bubble or border, like ChatGPT and Claude:
    /// the person's bubbles and the tool rows are the only framed things in the chat.
    public var body: some View {
        let text = event.assistantText ?? ""
        VStack(alignment: .leading, spacing: OCSpacing.base) {
            if !text.isEmpty || isLiveTail {
                if showsSpeaker {
                    HStack(spacing: 6) {
                        Image(systemName: speakerSymbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(OCColor.agentBuild)
                            .accessibilityHidden(true)
                        Text(speakerLabel)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(OCColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }

                MarkdownText(
                    content: isLiveTail ? text + "▍" : text,
                    emphasisColor: OCColor.syntaxType,
                    emphasisKey: "assistant"
                )
                .equatable()
                .font(OCTypography.body)
                .foregroundColor(OCColor.textPrimary)

                if turnPrompt != nil, !isLiveTail, !text.isEmpty {
                    actionBar(text: text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, showsSpeaker ? OCSpacing.md : OCSpacing.xs)
        .padding(.bottom, OCSpacing.xs)
    }

    /// Copy, share and retry under the last answer of a finished turn, as in Claude
    /// (6 × 32×44) and ChatGPT (5 × 30×32): small icons, 44 pt tall targets.
    private func actionBar(text: String) -> some View {
        HStack(spacing: 0) {
            Button {
                UIPasteboard.general.string = text
                OCHaptics.light()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                actionIcon(copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? "Copiado" : "Copiar respuesta")

            ShareLink(item: text) {
                actionIcon("square.and.arrow.up")
            }
            .accessibilityLabel("Compartir respuesta")

            if let turnPrompt, !turnPrompt.isEmpty {
                Button {
                    OCHaptics.light()
                    store.sendPrompt(turnPrompt)
                } label: {
                    actionIcon("arrow.clockwise")
                }
                .disabled(sessionState.isProcessing || !sessionState.composerAttachments.isEmpty)
                .accessibilityLabel("Reintentar")
                .accessibilityHint("Vuelve a enviar tu mensaje")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, -8)
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.medium))
            .foregroundColor(OCColor.iconMuted)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private final class CachedAttributedMarkdownBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private enum InlineMarkdownCache {
    static let cache: NSCache<NSString, CachedAttributedMarkdownBox> = {
        let cache = NSCache<NSString, CachedAttributedMarkdownBox>()
        cache.countLimit = 1024
        return cache
    }()
}

/// Draws an assistant message block by block (see `ChatMarkdownParser`): SwiftUI's `Text` keeps inline styling but
/// drops paragraph and list structure, which glued lines together. Strong emphasis gets an explicit accent so literal
/// `**markers**` never appear in the conversation.
private struct MarkdownText: View, Equatable {
    let content: String
    let emphasisColor: Color
    let emphasisKey: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.emphasisKey == rhs.emphasisKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdownParser.cachedParse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(.system(size: level <= 1 ? 20 : (level == 2 ? 18 : 16), weight: .semibold))
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            inline(text)
                .foregroundColor(OCColor.textSecondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OCColor.borderBase).frame(width: 3)
                }
        case .code(let language, let text):
            MarkdownCodeBlockView(language: language, code: text)
        case .table(let rows):
            MarkdownTableView(rows: rows, renderInline: renderedInline)
        case .rule:
            Divider().overlay(OCColor.borderBase)
        }
    }

    private func inline(_ text: String) -> some View {
        Text(renderedInline(text))
            .lineSpacing(3)
            .textSelection(.enabled)
    }

    /// Inline Markdown only (bold, italics, code, links), keeping every newline the model wrote.
    private func renderedInline(_ text: String) -> AttributedString {
        let cacheKey = "\(emphasisKey)\u{0}\(text)" as NSString
        if let hit = InlineMarkdownCache.cache.object(forKey: cacheKey) {
            return hit.value
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var value = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let emphasizedRanges = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
            return run.range
        }
        for range in emphasizedRanges {
            value[range].foregroundColor = emphasisColor
        }
        if text.utf8.count <= 16_384 {
            InlineMarkdownCache.cache.setObject(CachedAttributedMarkdownBox(value), forKey: cacheKey)
        }
        return value
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "código" : language)
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
                Spacer()
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = code
                    #endif
                    OCHaptics.light()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(copied ? OCColor.success : OCColor.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .background(Color.black.opacity(0.28))

            Divider().overlay(OCColor.borderMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(OCColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.22))
        .clipShape(OCRoundedRect(OCRadius.r12))
        .overlay(
            OCRoundedRect(OCRadius.r12)
                .stroke(OCColor.borderMuted, lineWidth: 0.75)
        )
    }
}

private struct MarkdownTableView: View {
    let rows: [String]
    let renderInline: (String) -> AttributedString

    private var parsed: (headers: [String]?, bodyRows: [[String]]) {
        var rawCells: [[String]] = []
        var separatorIndex: Int?
        for row in rows {
            let cells = Self.splitRow(row)
            guard !cells.isEmpty else { continue }
            if separatorIndex == nil, Self.isSeparatorRow(cells) {
                separatorIndex = rawCells.count
                continue
            }
            rawCells.append(cells)
        }
        guard !rawCells.isEmpty else { return (nil, []) }
        let colCount = rawCells.map(\.count).max() ?? 1
        let normalized = rawCells.map { row in
            row.count < colCount ? row + Array(repeating: "", count: colCount - row.count) : row
        }
        if let sepIdx = separatorIndex, sepIdx > 0 {
            return (normalized[0], Array(normalized.dropFirst()))
        }
        return (nil, normalized)
    }

    private static func splitRow(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
            return !cell.isEmpty && stripped.isEmpty && cell.contains("-")
        }
    }

    var body: some View {
        let table = parsed
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                if let headers = table.headers {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                            Text(renderInline(cell))
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(OCColor.textPrimary)
                                .padding(.vertical, 8)
                                .textSelection(.enabled)
                        }
                    }
                    Divider().overlay(OCColor.borderBase)
                }
                ForEach(Array(table.bodyRows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(renderInline(cell))
                                .font(.footnote)
                                .foregroundColor(OCColor.textSecondary)
                                .padding(.vertical, 7)
                                .textSelection(.enabled)
                        }
                    }
                    if rowIndex < table.bodyRows.count - 1 {
                        Divider().overlay(OCColor.borderMuted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(OCColor.bgBase)
        .clipShape(OCRoundedRect(OCRadius.r12))
        .overlay(
            OCRoundedRect(OCRadius.r12)
                .stroke(OCColor.borderMuted, lineWidth: 0.75)
        )
    }
}

// MARK: - Attachment Token

public struct AttachmentToken: View {
    let attachment: Attachment
    let onRemove: (() -> Void)?

    public init(attachment: Attachment, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: OCSpacing.xs) {
            #if canImport(UIKit)
            if attachment.type == .image, let path = attachment.path, let img = UIImage(contentsOfFile: path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r4))
            } else {
                Image(systemName: attachment.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)
            }
            #else
            Image(systemName: attachment.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OCColor.iconPrimary)
            #endif

            Text(attachment.name)
                .font(OCTypography.modelPillLabel)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)

            if let size = attachment.formattedByteSize {
                Text(size)
                    .font(.system(size: 10))
                    .foregroundColor(OCColor.textFaint)
            }

            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, OCSpacing.base)
        .frame(height: 28)
        .background(OCColor.bgLayer1)
        .clipShape(OCRoundedRect(OCRadius.r8))
        .overlay(
            OCRoundedRect(OCRadius.r8)
                .stroke(OCColor.borderBase, lineWidth: 1)
        )
    }
}

// MARK: - Tool Call View (Collapsed)

public struct ToolCallCollapsedView: View {
    let event: TimelineEvent
    let agentColor: Color
    let onExpand: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(event: TimelineEvent, agentColor: Color, onExpand: @escaping () -> Void) {
        self.event = event
        self.agentColor = agentColor
        self.onExpand = onExpand
    }

    /// One line: tool icon, what it did, the target (file, URL, command) and its state.
    /// Success is a quiet check; only running, failed and permission draw color.
    public var body: some View {
        // Toda la fila es el botón que despliega el detalle, no solo la flecha.
        Button(action: onExpand) { rowContent }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([toolTitle, statusTitle, toolDetail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(event.isExpanded ? "Ocultar detalles" : "Ver detalles")
            .accessibilityAddTraits(.isButton)
    }

    private var rowContent: some View {
        HStack(spacing: OCSpacing.base) {
            Image(systemName: toolIcon(for: event.toolName))
                .font(.footnote.weight(.medium))
                .foregroundColor(OCColor.iconMuted)
                .frame(width: 20)
                .accessibilityHidden(true)

            // At accessibility text sizes one line cannot hold title + path: stack them
            // and let the title wrap instead of truncating to "Editando archi…".
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    titleText.lineLimit(3)
                    detailText
                }
                .padding(.vertical, OCSpacing.base)
            } else {
                HStack(spacing: 5) {
                    titleText.lineLimit(1).layoutPriority(1)
                    detailText
                }
            }

            Spacer(minLength: OCSpacing.xs)

            if let duration = event.toolDuration, event.toolState != .running {
                Text(formatDuration(duration))
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }

            statusMark
                .frame(width: 18)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(OCColor.iconMuted)
                .rotationEffect(.degrees(event.isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.18), value: event.isExpanded)
                .accessibilityHidden(true)
        }
        // Aligned with the answer's text and unframed, like Claude's tool rows; 44 pt stays
        // the touch target even though nothing is drawn around it.
        .padding(.horizontal, event.toolState == .permission ? OCSpacing.md : 2)
        .frame(minHeight: 44)
        .background(event.toolState == .permission ? OCColor.warning.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(toolTitle)
            .font(OCTypography.toolLabel)
            .foregroundColor(OCColor.textPrimary)
    }

    @ViewBuilder private var detailText: some View {
        if let detail = toolDetail {
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(OCColor.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private var statusMark: some View {
        switch event.toolState {
        case .some(.running):
            ProgressView()
                .controlSize(.mini)
                .tint(statusColor)
        case .some(.failed), .some(.permission), .some(.success):
            Image(systemName: event.toolState == .success ? "checkmark" : (event.toolState == .failed ? "xmark.circle.fill" : "exclamationmark.shield.fill"))
                .font(.caption.weight(.semibold))
                .foregroundColor(event.toolState == .success ? OCColor.success : statusColor)
        case .none:
            EmptyView()
        }
    }

    private var statusColor: Color {
        event.toolState?.color ?? agentColor
    }

    private var statusTitle: String {
        switch event.toolState {
        case .some(.running): return "En curso"
        case .some(.success): return "Completado"
        case .some(.failed): return "Falló"
        case .some(.permission): return "Requiere permiso"
        case .none: return "Herramienta"
        }
    }

    private var toolTitle: String {
        Self.displayTitle(for: event.toolName)
    }

    static func displayTitle(for rawName: String?) -> String {
        let name = (rawName ?? "").lowercased()
        switch name {
        case "iphone_status": return "Estado del iPhone"
        case "iphone_list_elements": return "Leyendo pantalla del iPhone"
        case "iphone_screenshot": return "Captura del iPhone"
        case "iphone_tap", "iphone_tap_element": return "Tocando en el iPhone"
        case "iphone_long_press": return "Manteniendo pulsado en el iPhone"
        case "iphone_swipe": return "Deslizando en el iPhone"
        case "iphone_type_text": return "Escribiendo en el iPhone"
        case "iphone_press_button": return "Botón del iPhone"
        case "iphone_launch_app": return "Abriendo app en el iPhone"
        case "iphone_terminate_app": return "Cerrando app en el iPhone"
        case "iphone_list_apps": return "Apps del iPhone"
        case "iphone_open_url": return "Abriendo enlace en el iPhone"
        case "iphone_wait_for": return "Esperando elemento en el iPhone"
        default: break
        }
        if name.hasPrefix("iphone_") {
            return "Control del iPhone"
        }
        if name == "python_eval" { return "Procesando con Python local" }
        if name == "http_request" { return "Consultando servicio web" }
        if name == "isymcp_status" { return "Consultando ISyMCP (PC)" }
        if name == "isymcp_tasks" { return "Consultando tareas de ISyMCP" }
        if name == "isymcp_respond_task" { return "Respondiendo tarea en ISyMCP" }
        if name == "secret_vault_list" { return "Consultando aliases del Llavero" }
        if name == "secret_vault_request_entry" { return "Preparando ficha del Llavero" }
        if name == "learn_action_prepare" { return "Preparando grabador 'Aprender acción'" }
        if name == "learn_action_status" { return "Consultando estado de grabación" }
        if name == "l1_create_tool" { return "Creando capacidad compuesta (L1)" }
        if name == "l1_list_tools" { return "Listando capacidades L1" }
        if name == "l1_delete_tool" { return "Eliminando capacidad L1" }
        if name == "importar_catalogo_csv" { return "Importando catálogo CSV (L1)" }
        if name.hasPrefix("l1_") { return "Ejecutando acción aprendida (L1)" }
        if name == "browser_navigate" { return "Navegando en la web" }
        if name == "browser_get_page" { return "Leyendo página web" }
        if name == "browser_click" { return "Tocando en la web" }
        if name == "browser_input" { return "Escribiendo en la web" }
        if name == "browser_scroll" { return "Desplazando página web" }
        if name.hasPrefix("browser_") { return "Navegador" }
        if name == "gmail.read.inbox" { return "Leyendo Gmail" }
        if name == "gmail.write.send" { return "Enviando correo" }
        if name.hasPrefix("gmail.") { return "Gmail" }
        if name.hasPrefix("googlecalendar.") { return "Agenda de Google" }
        if name.hasPrefix("googletasks.") { return "Tareas de Google" }
        if name.hasPrefix("googledrive.") || name.hasPrefix("googledocs.") || name.hasPrefix("googlesheets.") { return "Google Drive" }
        if name.hasPrefix("googlecontacts.") { return "Contactos de Google" }
        if name.hasPrefix("shortcuts.") { return "Atajos del iPhone" }
        if name.contains("read") || name.contains("glob") || name.contains("search") || name.contains("list") {
            return "Consultando archivos"
        }
        if name.contains("write") || name.contains("edit") || name.contains("patch") {
            return "Editando archivos"
        }
        if name.contains("bash") || name.contains("shell") || name.contains("command") || name.contains("exec") {
            return "Ejecutando comando"
        }
        return rawName?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Herramienta"
    }

    static func displayDetail(for arguments: [String: String]?) -> String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        let preferredKeys = [
            "path", "file", "file_path", "filepath", "pattern", "command", "url",
            "text", "filter", "element", "app", "bundle_id", "button", "direction", "query"
        ]
        if let preferred = preferredKeys.compactMap({ key in
            arguments.first(where: { $0.key.lowercased() == key })?.value
        }).first(where: { !$0.isEmpty }) {
            return preferred
        }
        return arguments.keys.sorted().compactMap { key -> String? in
            guard let value = arguments[key], !value.isEmpty else { return nil }
            let lower = value.lowercased()
            if lower == "true" || lower == "false" { return nil }
            return value
        }.first
    }

    private var toolDetail: String? {
        Self.displayDetail(for: event.toolArguments)
    }

    static func iconName(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "wrench" }
        if name == "python_eval" { return "terminal.fill" }
        if name.hasPrefix("secret_vault_") { return "key.fill" }
        if name.hasPrefix("learn_action_") { return "record.circle" }
        if name.hasPrefix("isymcp_") { return "desktopcomputer" }
        if name.hasPrefix("l1_") || name == "importar_catalogo_csv" { return "square.stack.3d.up.fill" }
        if name == "http_request" { return "network" }
        if name.hasPrefix("iphone_") { return "iphone" }
        if name.hasPrefix("browser_") { return "safari" }
        if name.hasPrefix("gmail.") { return "envelope" }
        if name.hasPrefix("googlecalendar.") { return "calendar" }
        if name.hasPrefix("googletasks.") { return "checkmark.circle" }
        if name.hasPrefix("googledrive.") || name.hasPrefix("googledocs.") || name.hasPrefix("googlesheets.") { return "externaldrive" }
        if name.hasPrefix("shortcuts.") { return "bolt" }
        if name.contains("read") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "pencil" }
        if name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("glob") || name.contains("search") { return "magnifyingglass" }
        if name.contains("list") { return "list.bullet" }
        if name.contains("patch") || name.contains("diff") { return "arrow.left.arrow.right" }
        return "wrench"
    }

    private func toolIcon(for name: String?) -> String {
        Self.iconName(for: name)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "\(Int(duration * 1000))ms" }
        if duration < 60 { return "\(Int(duration))s" }
        return "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}

// MARK: - Tool Call View (Expanded)

public struct ToolCallExpandedView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: toolIcon(for: event.toolName))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)

                Text(ToolCallCollapsedView.displayTitle(for: event.toolName))
                    .font(OCTypography.toolLabel)
                    .foregroundColor(OCColor.textPrimary)

                Spacer()

                if let duration = event.toolDuration {
                    Text(formatDuration(duration))
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                }

                if let state = event.toolState {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.color)
                            .frame(width: 6, height: 6)
                        Text(state.title)
                            .font(OCTypography.controlMono)
                            .foregroundColor(state.color)
                    }
                }
            }
            .padding(.horizontal, OCSpacing.base)
            .padding(.vertical, OCSpacing.sm)
            .frame(height: 34)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Arguments summary (human-readable parameters)
            if let args = event.toolArguments, !args.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PARÁMETROS")
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                    ForEach(args.keys.sorted().prefix(4), id: \.self) { key in
                        if let val = args[key], !val.isEmpty {
                            Text("\(key): \(String(val.prefix(240)))")
                                .font(OCTypography.codeSmall)
                                .foregroundColor(OCColor.textSecondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.horizontal, OCSpacing.base)
                .padding(.top, OCSpacing.sm)
            }

            // Output
            if let output = event.toolOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("RESULTADO")
                            .font(OCTypography.metaMono)
                            .foregroundColor(OCColor.textFaint)
                        Spacer()
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = output
                            #endif
                            OCHaptics.light()
                        } label: {
                            Label("Copiar", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(IysThemePreferences.active.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, OCSpacing.base)
                    .padding(.top, OCSpacing.sm)

                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        Text(output)
                            .font(OCTypography.codeSmall)
                            .foregroundColor(OCColor.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, OCSpacing.base)
                            .padding(.vertical, OCSpacing.xs)
                    }
                    .frame(maxHeight: 260)
                }
            } else if event.toolState == .running {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: agentColor))
                    Text("\(ToolCallCollapsedView.displayTitle(for: event.toolName)) en progreso…")
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textSecondary)
                }
                .padding(.horizontal, OCSpacing.base)
                .padding(.vertical, OCSpacing.md)
            }
        }
        .ocCard(radius: OCRadius.r10, border: OCColor.borderBase, background: OCColor.bgBase)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func toolIcon(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "wrench" }
        if name.hasPrefix("iphone_") { return "iphone" }
        if name.hasPrefix("browser_") { return "safari" }
        if name.hasPrefix("gmail.") { return "envelope" }
        if name.hasPrefix("googlecalendar.") { return "calendar" }
        if name.hasPrefix("googletasks.") { return "checkmark.circle" }
        if name.hasPrefix("googledrive.") || name.hasPrefix("googledocs.") || name.hasPrefix("googlesheets.") { return "externaldrive" }
        if name.hasPrefix("shortcuts.") { return "bolt" }
        if name.contains("read") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "pencil" }
        if name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("glob") || name.contains("search") { return "magnifyingglass" }
        if name.contains("list") { return "list.bullet" }
        if name.contains("patch") || name.contains("diff") { return "arrow.left.arrow.right" }
        return "wrench"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "\(Int(duration * 1000))ms" }
        if duration < 60 { return "\(Int(duration))s" }
        return "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}

// MARK: - Tool Call Container

public struct ToolCallView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolCallCollapsedView(
                event: event,
                agentColor: agentColor,
                onExpand: { sessionState.toggleToolExpansion(id: event.id) }
            )
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12, style: .continuous))

            if event.isExpanded {
                ToolCallExpandedView(event: event, agentColor: agentColor)
                    .padding(.top, OCSpacing.xs)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.2)),
                        removal: .opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.15))
                    ))
            }
        }
        .padding(.vertical, OCSpacing.xs)
        .animation(.easeInOut(duration: 0.18), value: event.isExpanded)
    }
}

// MARK: - Diff View

public struct DiffView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let files = event.diffFiles {
                ForEach(files) { file in
                    DiffFileView(file: file)
                        .padding(.bottom, OCSpacing.lg)
                }
            }
        }
    }
}

public struct DiffFileView: View {
    let file: DiffFile
    @State private var expandedHunks: Set<String> = []

    public init(file: DiffFile) {
        self.file = file
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)

                Text(file.path)
                    .font(OCTypography.diffHeader)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("+\(file.additions) −\(file.deletions)")
                    .font(OCTypography.diffHeader)
                    .foregroundColor(OCColor.textSecondary)
            }
            .padding(.horizontal, OCSpacing.base)
            .padding(.vertical, OCSpacing.sm)
            .frame(height: 36)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Hunks
            ForEach(file.hunks) { hunk in
                DiffHunkView(hunk: hunk, isExpanded: expandedHunks.contains(hunk.id)) {
                    if expandedHunks.contains(hunk.id) {
                        expandedHunks.remove(hunk.id)
                    } else {
                        expandedHunks.insert(hunk.id)
                    }
                }
            }
        }
        .ocCard(radius: OCRadius.r12, border: OCColor.borderBase, background: OCColor.bgDeep)
    }
}

public struct DiffHunkView: View {
    let hunk: DiffHunk
    let isExpanded: Bool
    let onToggle: () -> Void

    public init(hunk: DiffHunk, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.hunk = hunk
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header
            Button(action: onToggle) {
                HStack {
                    Text(hunk.header)
                        .font(OCTypography.diffHeader)
                        .foregroundColor(OCColor.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, OCSpacing.base)
                .frame(height: 24)
                .background(OCColor.agentBuild.opacity(0.08))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(hunk.lines) { line in
                    DiffLineView(line: line)
                }
            }
        }
    }
}

public struct DiffLineView: View {
    let line: DiffLine

    public init(line: DiffLine) {
        self.line = line
    }

    public var body: some View {
        HStack(alignment: .top, spacing: OCSpacing.xs) {
            // Line number gutter
            Text(line.number != nil ? "\(line.number!)" : "  ")
                .font(OCTypography.diffLineNum)
                .foregroundColor(OCColor.textFaint)
                .frame(width: 34, alignment: .trailing)

            Rectangle()
                .fill(OCColor.borderMuted)
                .frame(width: 0.5)

            // Content
            Text(line.content)
                .font(OCTypography.diffCode)
                .foregroundColor(lineColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OCSpacing.xs)
                .padding(.vertical, 1)
        }
        .background(lineBackground)
    }

    private var lineColor: Color {
        switch line.kind {
        case .add: return OCColor.diffAddFg
        case .delete: return OCColor.diffDeleteFg
        case .hunk: return OCColor.textSecondary
        case .context: return OCColor.textPrimary
        }
    }

    private var lineBackground: Color {
        switch line.kind {
        case .add: return OCColor.diffAddBg
        case .delete: return OCColor.diffDeleteBg
        case .hunk: return OCColor.agentBuild.opacity(0.08)
        case .context: return Color.clear
        }
    }
}

// MARK: - Code Block View

public struct CodeBlockView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if let lang = event.codeLanguage {
                    Text(lang)
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textSecondary)
                }
                if let fileName = event.codeFileName {
                    Text(fileName)
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textFaint)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = event.codeContent
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copiar código")
            }
            .padding(.leading, OCSpacing.lg)
            .frame(minHeight: 36)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Code content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(event.codeContent ?? "")
                    .font(OCTypography.code)
                    .foregroundColor(OCColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OCSpacing.base)
                    .padding(.vertical, OCSpacing.xs)
            }
        }
        .ocCard(radius: OCRadius.r10, border: OCColor.borderBase, background: OCColor.bgBase)
    }
}

// MARK: - Thinking/Status View

public struct ThinkingView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        HStack(spacing: OCSpacing.base) {
            Image(systemName: "text.bubble")
                .foregroundColor(agentColor)
                .accessibilityHidden(true)

            Text(event.statusLabel == "Thinking" ? "Razonamiento" : event.statusLabel ?? "Actividad")
                .font(OCTypography.control)
                .foregroundColor(OCColor.textSecondary)

            Spacer()

            if let elapsed = event.statusElapsed {
                Text(formatElapsed(elapsed))
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 28)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let secs = Int(interval)
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

// MARK: - Todo View

public struct TodoView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.xs) {
            if let items = event.todoItems {
                ForEach(items) { item in
                    TodoItemRow(item: item, agentColor: agentColor, indent: 0)
                }
            }
        }
        .padding(.vertical, OCSpacing.xs)
    }
}

public struct TodoItemRow: View {
    let item: TodoItem
    let agentColor: Color
    let indent: Int

    public init(item: TodoItem, agentColor: Color, indent: Int = 0) {
        self.item = item
        self.agentColor = agentColor
        self.indent = indent
    }

    public var body: some View {
        HStack(alignment: .top, spacing: OCSpacing.base) {
            // State glyph
            ZStack {
                if item.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(OCColor.textFaint)
                } else if item.isRunning {
                    Circle()
                        .stroke(agentColor, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(agentColor)
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .stroke(OCColor.borderBase, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(OCTypography.todoText)
                    .foregroundColor(item.isCompleted ? OCColor.textFaint : OCColor.textPrimary)

                if let meta = item.metadata {
                    Text(meta)
                        .font(OCTypography.todoMeta)
                        .foregroundColor(OCColor.textFaint)
                }
            }

            Spacer()
        }
        .padding(.leading, CGFloat(indent) * 16)
        .frame(minHeight: 36)
    }
}

// MARK: - Permission View

public struct PermissionView: View {
    let event: TimelineEvent
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onPersistent: () -> Void
    let onCodexCancel: (() -> Void)?
    /// Una sola aprobación de alcance para el turno (solo herramientas iphone_*).
    /// Nil cuando el llamador no la ofrece.
    let onSequence: (() -> Void)?
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showTechnicalDetails = false

    private var storeUsesFreshApproval: Bool { store.backendMode == .native }

    public init(event: TimelineEvent, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void, onPersistent: @escaping () -> Void, onCodexCancel: (() -> Void)? = nil, onSequence: (() -> Void)? = nil) {
        self.event = event
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onPersistent = onPersistent
        self.onCodexCancel = onCodexCancel
        self.onSequence = onSequence
    }

    public var body: some View {
        let isCodex = event.permissionTool?.hasPrefix("Codex") == true
        let isGrok = event.permissionTool?.hasPrefix("Grok") == true
        let isLimitedRemote = isCodex || isGrok
        let formatted = HumanConfirmationFormatter.format(permission: event)
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            // Header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(OCColor.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirmar acción")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.warning)
                    Text(formatted.headline)
                        .font(OCTypography.permissionTitle)
                        .foregroundColor(OCColor.textPrimary)
                }
            }

            // Explanation
            Text(formatted.explanation)
                .font(OCTypography.permissionBody)
                .foregroundColor(OCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !formatted.readableDetails.isEmpty {
                VStack(alignment: .leading, spacing: OCSpacing.sm) {
                    ForEach(Array(formatted.readableDetails.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0.uppercased())
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                            Text(item.1)
                                .font(OCTypography.permissionBody)
                                .foregroundColor(OCColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(OCSpacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OCColor.bgDeep)
                .clipShape(OCRoundedRect(OCRadius.r8))
            }

            DisclosureGroup("Detalles técnicos", isExpanded: $showTechnicalDetails) {
                VStack(alignment: .leading, spacing: OCSpacing.xs) {
                    ForEach(Array(formatted.technicalDetails.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0.uppercased())
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                            Text(item.1)
                                .font(OCTypography.codeSmall)
                                .foregroundColor(OCColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, OCSpacing.xs)
            }
            .font(OCTypography.control)
            .foregroundColor(OCColor.textSecondary)

            // Actions
            VStack(spacing: OCSpacing.base) {
                HStack(spacing: OCSpacing.base) {
                    Button(action: onAllow) {
                        Text("Permitir una vez")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(OCColor.agentBuild)
                            .clipShape(OCRoundedRect(OCRadius.r10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("permission-allow-once")

                    Button(action: onDeny) {
                        Text(isLimitedRemote ? "Rechazar" : "Denegar")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(OCColor.bgLayer1)
                            .clipShape(OCRoundedRect(OCRadius.r10))
                            .overlay(
                                OCRoundedRect(OCRadius.r10)
                                    .stroke(OCColor.borderBase, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("permission-deny")
                }

                // Una sola aprobación de alcance para el turno: solo para herramientas
                // WDA (iphone_*). Cubre abrir, tocar, escribir y enviar en esta tarea;
                // al terminar el turno vuelve a pedir permiso. No es "siempre".
                if let onSequence, event.permissionTool?.hasPrefix("iphone_") == true {
                    Button(action: onSequence) {
                        Text("Permitir secuencia WDA por esta tarea")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(OCColor.bgLayer1)
                            .clipShape(OCRoundedRect(OCRadius.r10))
                            .overlay(
                                OCRoundedRect(OCRadius.r10)
                                    .stroke(OCColor.borderBase, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("permission-allow-sequence")

                    Text("Autoriza una secuencia acotada (hasta 12 acciones o 3 minutos) solo para herramientas WDA en esta tarea. Puedes revocarla en cualquier momento desde la barra superior.")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isLimitedRemote {
                    Button(action: onCodexCancel ?? onDeny) {
                        Text("Cancelar turno")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                }

                if !isLimitedRemote && storeUsesFreshApproval {
                    Text("En este iPhone, el siguiente cambio vuelve a pedir permiso.")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Menu {
                    Button(isLimitedRemote ? "Permitir en esta sesión" : "Permitir siempre", action: onPersistent)
                } label: {
                    Label(isLimitedRemote ? "Aprobación de sesión…" : "Más opciones de permiso…", systemImage: "ellipsis.circle")
                        .font(OCTypography.control)
                        .foregroundColor(OCColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r12, border: OCColor.warning.opacity(0.35), background: OCColor.bgBase)
    }
}

// MARK: - Question View

public struct QuestionView: View {
    let event: TimelineEvent
    let onSelect: (String) -> Void
    let onFreeform: (String) -> Void
    @State private var freeformText = ""
    @State private var selectedChoiceID: String?

    public init(event: TimelineEvent, onSelect: @escaping (String) -> Void, onFreeform: @escaping (String) -> Void) {
        self.event = event
        self.onSelect = onSelect
        self.onFreeform = onFreeform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            Text(event.questionText ?? "Pregunta")
                .font(OCTypography.permissionTitle)
                .foregroundColor(OCColor.textPrimary)

            if let choices = event.questionChoices {
                ForEach(choices) { choice in
                    Button {
                        selectedChoiceID = choice.id
                        onSelect(choice.id)
                    } label: {
                        HStack(spacing: OCSpacing.base) {
                            ZStack {
                                Circle()
                                    .stroke(selectedChoiceID == choice.id ? OCColor.agentBuild : OCColor.borderBase, lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                                if selectedChoiceID == choice.id {
                                    Circle()
                                        .fill(OCColor.agentBuild)
                                        .frame(width: 10, height: 10)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label)
                                    .font(OCTypography.questionChoice)
                                    .foregroundColor(OCColor.textPrimary)
                                if let desc = choice.description {
                                    Text(desc)
                                        .font(OCTypography.meta)
                                        .foregroundColor(OCColor.textFaint)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, OCSpacing.base)
                        .frame(minHeight: 48)
                        .background(OCColor.bgLayer1.opacity(0.5))
                        .clipShape(OCRoundedRect(OCRadius.r10))
                        .overlay(
                            OCRoundedRect(OCRadius.r10)
                                .stroke(OCColor.borderBase, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if event.questionAllowFreeform == true {
                VStack(alignment: .leading, spacing: OCSpacing.xs) {
                    Text("O escribe tu respuesta:")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)

                    TextField("Tu respuesta…", text: $freeformText, axis: .vertical)
                        .font(OCTypography.body)
                        .textFieldStyle(.plain)
                        .padding(OCSpacing.base)
                        .background(OCColor.bgLayer1)
                        .clipShape(OCRoundedRect(OCRadius.r10))
                        .overlay(
                            OCRoundedRect(OCRadius.r10)
                                .stroke(OCColor.borderBase, lineWidth: 1)
                        )
                        .lineLimit(3...6)

                    Button("Enviar") {
                        onFreeform(freeformText)
                        freeformText = ""
                    }
                    .font(OCTypography.control)
                    .foregroundColor(freeformText.isEmpty ? OCColor.textFaint : OCColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(freeformText.isEmpty ? OCColor.bgLayer2 : OCColor.agentBuild)
                    .clipShape(OCRoundedRect(OCRadius.r10))
                    .disabled(freeformText.isEmpty)
                }
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r12, border: OCColor.borderBase, background: OCColor.bgBase)
    }
}

// MARK: - System Message View

public struct SystemMessageView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        if let text = event.assistantText {
            if text.hasPrefix("Error:") {
                let raw = String(text.dropFirst("Error:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let issue = ConversationIssue(raw)
                OCUnifiedStateCard(
                    kind: issue == .offline ? .offline : (issue == .cancelled ? .cancelled : .error),
                    title: issue.title,
                    message: issue.message,
                    technicalDetail: raw
                )
                .padding(.vertical, OCSpacing.xs)
            } else {
                Text(text)
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, OCSpacing.xs)
            }
        }
    }


}

// MARK: - Tool Steps Carousel

/// Groups consecutive tool calls into a compact horizontal step strip (inspired by iphone-use-app),
/// with tap-to-inspect output below.
public struct ToolStepsCarouselView: View {
    let steps: [TimelineEvent]
    let agentColor: Color
    @State private var selectedStepID: String?

    public init(steps: [TimelineEvent], agentColor: Color) {
        self.steps = steps
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.sm) {
            HStack(spacing: OCSpacing.xs) {
                Text("Pasos")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OCColor.textSecondary)
                Text("· \(steps.count)")
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: OCSpacing.sm) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepCard(step, index: index + 1)
                    }
                }
            }

            if let selected = steps.first(where: { $0.id == selectedStepID }) {
                ToolCallExpandedView(event: selected, agentColor: agentColor)
            }
        }
        .padding(.vertical, OCSpacing.xs)
    }

    private func stepCard(_ step: TimelineEvent, index: Int) -> some View {
        let isSelected = selectedStepID == step.id
        let stateColor = step.toolState?.color ?? OCColor.textFaint
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedStepID = isSelected ? nil : step.id
            }
        } label: {
            VStack(alignment: .leading, spacing: OCSpacing.xs) {
                HStack(spacing: 6) {
                    Text("\(index).")
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                    Image(systemName: ToolCallCollapsedView.iconName(for: step.toolName))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(stateColor)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                }

                Text(ToolCallCollapsedView.displayTitle(for: step.toolName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)

                if let detail = ToolCallCollapsedView.displayDetail(for: step.toolArguments) {
                    Text(detail)
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(step.toolState?.title ?? "Paso")
                        .font(OCTypography.meta)
                        .foregroundColor(stateColor)
                }
            }
            .padding(OCSpacing.md)
            .frame(width: 168, alignment: .leading)
            .background(isSelected ? stateColor.opacity(0.10) : OCColor.bgBase)
            .clipShape(OCRoundedRect(OCRadius.r12))
            .overlay(
                OCRoundedRect(OCRadius.r12)
                    .stroke(isSelected ? stateColor.opacity(0.55) : OCColor.borderBase, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

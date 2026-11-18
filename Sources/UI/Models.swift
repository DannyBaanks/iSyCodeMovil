import Foundation
import SwiftUI

// MARK: - Project

public struct Project: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let avatarColor: Color?
    public let lastActiveSessionId: String?
    public let sessionCount: Int

    public init(id: String = UUID().uuidString, name: String, path: String, avatarColor: Color? = nil, lastActiveSessionId: String? = nil, sessionCount: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.avatarColor = avatarColor
        self.lastActiveSessionId = lastActiveSessionId
        self.sessionCount = sessionCount
    }
}

// MARK: - Session

public struct Session: Identifiable, Hashable, Sendable {
    public let id: String
    public let projectId: String
    public let title: String
    public let lastEventSummary: String?
    public let timestamp: Date
    public let agentMode: AgentMode
    public let isRunning: Bool
    public let isDirty: Bool

    public init(id: String = UUID().uuidString, projectId: String, title: String, lastEventSummary: String? = nil, timestamp: Date = Date(), agentMode: AgentMode = .build, isRunning: Bool = false, isDirty: Bool = false) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.lastEventSummary = lastEventSummary
        self.timestamp = timestamp
        self.agentMode = agentMode
        self.isRunning = isRunning
        self.isDirty = isDirty
    }
}

// MARK: - Timeline Event

public struct TimelineEvent: Identifiable, Sendable {
    public let id: String
    public let kind: TimelineEventKind
    public let timestamp: Date
    public let agentMode: AgentMode?

    // User Prompt
    public var promptText: String?
    public var attachments: [Attachment]?

    // Assistant Text
    public var assistantText: String?

    // Tool Call
    public var toolName: String?
    public var toolArguments: [String: String]?
    public var toolState: ToolCallState?
    public var toolDuration: TimeInterval?
    public var toolOutput: String?
    public var isExpanded: Bool = false

    // Diff
    public var diffFiles: [DiffFile]?

    // Code Block
    public var codeLanguage: String?
    public var codeContent: String?
    public var codeFileName: String?

    // Permission
    public var permissionRequestId: String?
    public var permissionTool: String?
    public var permissionCommand: String?
    public var permissionExplanation: String?
    public var permissionScope: String?

    // Question
    public var questionText: String?
    public var questionChoices: [QuestionChoice]?
    public var questionAllowFreeform: Bool?

    // Thinking/Status
    public var statusLabel: String?
    public var statusElapsed: TimeInterval?

    // Todo
    public var todoItems: [TodoItem]?

    public init(
        id: String = UUID().uuidString,
        kind: TimelineEventKind,
        timestamp: Date = Date(),
        agentMode: AgentMode? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.agentMode = agentMode
    }

    // Factory methods
    public static func userPrompt(_ text: String, attachments: [Attachment] = [], agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .userPrompt, agentMode: agentMode)
        event.promptText = text
        event.attachments = attachments
        return event
    }

    public static func assistantText(_ text: String, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .assistantText, agentMode: agentMode)
        event.assistantText = text
        return event
    }

    public static func toolCall(id: String = UUID().uuidString, name: String, arguments: [String: String], state: ToolCallState = .running, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(id: id, kind: .toolCall, agentMode: agentMode)
        event.toolName = name
        event.toolArguments = arguments
        event.toolState = state
        return event
    }

    public static func toolResult(name: String, output: String, duration: TimeInterval, state: ToolCallState = .success, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .toolResult, agentMode: agentMode)
        event.toolName = name
        event.toolOutput = output
        event.toolDuration = duration
        event.toolState = state
        return event
    }

    public static func diff(files: [DiffFile], agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .diff, agentMode: agentMode)
        event.diffFiles = files
        return event
    }

    public static func codeBlock(language: String, content: String, fileName: String? = nil, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .codeBlock, agentMode: agentMode)
        event.codeLanguage = language
        event.codeContent = content
        event.codeFileName = fileName
        return event
    }

    public static func permission(requestId: String, tool: String, command: String, explanation: String, scope: String, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(id: requestId, kind: .permission, agentMode: agentMode)
        event.permissionRequestId = requestId
        event.permissionTool = tool
        event.permissionCommand = command
        event.permissionExplanation = explanation
        event.permissionScope = scope
        return event
    }

    public static func question(text: String, choices: [QuestionChoice], allowFreeform: Bool = false, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .question, agentMode: agentMode)
        event.questionText = text
        event.questionChoices = choices
        event.questionAllowFreeform = allowFreeform
        return event
    }

    public static func thinking(label: String, elapsed: TimeInterval, agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .thinking, agentMode: agentMode)
        event.statusLabel = label
        event.statusElapsed = elapsed
        return event
    }

    public static func todo(items: [TodoItem], agentMode: AgentMode) -> TimelineEvent {
        var event = TimelineEvent(kind: .todo, agentMode: agentMode)
        event.todoItems = items
        return event
    }

    public static func system(_ text: String) -> TimelineEvent {
        var event = TimelineEvent(kind: .system)
        event.assistantText = text
        return event
    }
}

// MARK: - Attachment (shared multimodal attachment model)

public enum AttachmentSource: String, Codable, Hashable, Sendable {
    case photosLibrary
    case camera
    case filesImporter
    case audioPicker
    case workspace
    case manual

    public var displayName: String {
        switch self {
        case .photosLibrary: return "Fototeca"
        case .camera: return "Cámara"
        case .filesImporter: return "Archivos"
        case .audioPicker: return "Audio"
        case .workspace: return "Proyecto"
        case .manual: return "Manual"
        }
    }
}

public enum AttachmentPreparationState: Codable, Hashable, Sendable {
    case selected
    case preparing
    case ready
    case uploading
    case sent
    case failed(String)
    case cancelled
    case unsupported(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        if case .sent = self { return true }
        return false
    }

    public var badgeLabel: String {
        switch self {
        case .selected: return "Seleccionado"
        case .preparing: return "Preparando…"
        case .ready: return "Listo"
        case .uploading: return "Enviando…"
        case .sent: return "Enviado"
        case .failed: return "Error"
        case .cancelled: return "Cancelado"
        case .unsupported: return "Solo referencia"
        }
    }
}

public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let type: AttachmentType
    public let source: AttachmentSource
    public var state: AttachmentPreparationState
    public let name: String
    public let path: String?
    public let icon: String
    public let mimeType: String?
    public let utTypeIdentifier: String?
    public let byteCount: Int64?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public var extractedText: String?
    public var warningMessage: String?

    public enum AttachmentType: String, Codable, Hashable, Sendable {
        case file, folder, image, video, audio, context
    }

    public init(
        id: String = UUID().uuidString,
        type: AttachmentType,
        source: AttachmentSource = .workspace,
        state: AttachmentPreparationState = .ready,
        name: String,
        path: String? = nil,
        icon: String = "doc",
        mimeType: String? = nil,
        utTypeIdentifier: String? = nil,
        byteCount: Int64? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        extractedText: String? = nil,
        warningMessage: String? = nil
    ) {
        self.id = id
        self.type = type
        self.source = source
        self.state = state
        self.name = name
        self.path = path
        self.icon = icon
        self.mimeType = mimeType
        self.utTypeIdentifier = utTypeIdentifier
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.extractedText = extractedText
        self.warningMessage = warningMessage
    }

    public var formattedByteSize: String? {
        guard let byteCount, byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

public typealias ChatAttachment = Attachment

// MARK: - Diff

public struct DiffFile: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiffHunk]

    public init(id: String = UUID().uuidString, path: String, additions: Int, deletions: Int, hunks: [DiffHunk]) {
        self.id = id
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }
}

public struct DiffHunk: Identifiable, Sendable {
    public let id: String
    public let header: String
    public let lines: [DiffLine]

    public init(id: String = UUID().uuidString, header: String, lines: [DiffLine]) {
        self.id = id
        self.header = header
        self.lines = lines
    }
}

public struct DiffLine: Identifiable, Sendable {
    public let id: String
    public let kind: DiffLineKind
    public let number: Int?
    public let content: String

    public enum DiffLineKind: String, Sendable {
        case context, add, delete, hunk
    }

    public init(id: String = UUID().uuidString, kind: DiffLineKind, number: Int? = nil, content: String) {
        self.id = id
        self.kind = kind
        self.number = number
        self.content = content
    }
}

// MARK: - Question

public struct QuestionChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let icon: String?

    public init(id: String = UUID().uuidString, label: String, description: String? = nil, icon: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.icon = icon
    }
}

// MARK: - Todo

public struct TodoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let isCompleted: Bool
    public let isRunning: Bool
    public let metadata: String?
    public let children: [TodoItem]

    public init(id: String = UUID().uuidString, text: String, isCompleted: Bool = false, isRunning: Bool = false, metadata: String? = nil, children: [TodoItem] = []) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.isRunning = isRunning
        self.metadata = metadata
        self.children = children
    }
}

// MARK: - Model Provider Info

public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let providerIcon: String?
    public let contextWindow: Int?
    public let supportsReasoning: Bool
    public let supportsImages: Bool
    public let isLocal: Bool
    /// Exact model identifier sent to the provider API. Display names stay UI-only.
    public let apiModelId: String?
    public let route: String?

    public init(id: String = UUID().uuidString, name: String, provider: String, providerIcon: String? = nil, contextWindow: Int? = nil, supportsReasoning: Bool = false, supportsImages: Bool = false, isLocal: Bool = false, apiModelId: String? = nil, route: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.providerIcon = providerIcon
        self.contextWindow = contextWindow
        self.supportsReasoning = supportsReasoning
        self.supportsImages = supportsImages
        self.isLocal = isLocal
        self.apiModelId = apiModelId
        self.route = route
    }
}

// MARK: - Active Session State

/// A composer observes only its own in-memory draft. Typing must not invalidate the timeline.
@MainActor
final class ConversationDraft: ObservableObject {
    @Published var text = ""
    var submittedText: String?

    func receivedPrompt(_ prompt: String?) {
        guard let submittedText,
              submittedText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt else { return }
        if text == submittedText { text = "" }
        self.submittedText = nil
    }
}

@MainActor
public final class ActiveSessionState: ObservableObject {
    private var conversationDrafts: [String: ConversationDraft] = [:]

    func draft(for session: Session) -> ConversationDraft {
        if let existing = conversationDrafts[session.id] { return existing }
        let draft = ConversationDraft()
        conversationDrafts[session.id] = draft
        return draft
    }

    @Published public var currentProject: Project? {
        didSet {
            if currentProject == nil { conversationDrafts.removeAll() }
        }
    }
    @Published public var currentSession: Session?
    @Published public var timelineEvents: [TimelineEvent] = []
    @Published public var activeSurface: WorkSurface = .chat
    @Published public var agentMode: AgentMode = .build
    @Published public var selectedModel: ModelInfo?
    @Published public var isProcessing: Bool = false
    @Published public var composerText: String = ""
    @Published public var composerAttachments: [Attachment] = []
    @Published public var showAgentPicker: Bool = false
    @Published public var showModelPicker: Bool = false
    @Published public var showAttachments: Bool = false
    @Published public var flowMode: Bool = false
    @Published public var pendingPermission: TimelineEvent?
    @Published public var pendingQuestion: TimelineEvent?

    public init() {}

    public func addEvent(_ event: TimelineEvent) {
        if event.kind == .userPrompt, let id = currentSession?.id {
            conversationDrafts[id]?.receivedPrompt(event.promptText)
        }
        timelineEvents.append(event)
    }

    public func updateToolCall(id: String, state: ToolCallState, output: String? = nil, duration: TimeInterval? = nil) {
        guard let index = timelineEvents.firstIndex(where: { $0.id == id }) else { return }
        timelineEvents[index].toolState = state
        if let output = output { timelineEvents[index].toolOutput = output }
        if let duration = duration { timelineEvents[index].toolDuration = duration }
    }

    public func toggleToolExpansion(id: String) {
        guard let index = timelineEvents.firstIndex(where: { $0.id == id }) else { return }
        timelineEvents[index].isExpanded.toggle()
    }

    public func clearTimeline() {
        timelineEvents.removeAll()
    }
}

// MARK: - Demo Data (ONLY for SwiftUI previews and tests — NOT for production)

public extension Project {
    static let demoProjects: [Project] = [
        Project(name: "IysCodeMovil", path: "~/Development/ISyCo Git/IysCodeMovil", avatarColor: .blue, sessionCount: 3),
        Project(name: "iyscode (upstream)", path: "~/Development/iyscode", avatarColor: .green, sessionCount: 12),
        Project(name: "side-project", path: "~/Development/side-project", avatarColor: .orange, sessionCount: 1),
    ]
}

public extension Session {
    static func demoSessions(for project: Project) -> [Session] {
        [
            Session(projectId: project.id, title: "Fix native provider picker", lastEventSummary: "Edited ProviderPickerView.swift", timestamp: Date().addingTimeInterval(-3600), agentMode: .build, isRunning: false),
            Session(projectId: project.id, title: "Add diff review affordance", lastEventSummary: "Running tests…", timestamp: Date().addingTimeInterval(-7200), agentMode: .plan, isRunning: true),
            Session(projectId: project.id, title: "Refactor composer layout", lastEventSummary: "Completed diff review", timestamp: Date().addingTimeInterval(-86400), agentMode: .build, isRunning: false, isDirty: true),
            Session(projectId: project.id, title: "Initial project setup", lastEventSummary: "Created project structure", timestamp: Date().addingTimeInterval(-172800), agentMode: .plan, isRunning: false),
        ]
    }
}

public extension ModelInfo {
    static let demoModels: [ModelInfo] = [
        ModelInfo(name: "Demo Scripted", provider: "Local", providerIcon: "cpu", isLocal: true, apiModelId: "scripted-1", route: "scripted"),
        ModelInfo(name: "GPT-4o", provider: "OpenAI", providerIcon: "cpu", contextWindow: 128000, supportsReasoning: false, supportsImages: true, apiModelId: "gpt-4o", route: "openai"),
        ModelInfo(name: "GPT-4o mini", provider: "OpenAI", providerIcon: "cpu", contextWindow: 128000, supportsReasoning: false, supportsImages: true, apiModelId: "gpt-4o-mini", route: "openai"),
        // Visible as future adapters; direct routing rejected until native adapter/proxy exists.
        ModelInfo(name: "Claude 3.5 Sonnet", provider: "Anthropic", providerIcon: "cpu", contextWindow: 200000, supportsReasoning: true, supportsImages: true, route: "anthropic"),
        ModelInfo(name: "Claude 3 Opus", provider: "Anthropic", providerIcon: "cpu", contextWindow: 200000, supportsReasoning: true, supportsImages: true, route: "anthropic"),
        ModelInfo(name: "Gemini 1.5 Pro", provider: "Google", providerIcon: "cpu", contextWindow: 1000000, supportsReasoning: true, supportsImages: true, route: "google"),
        ModelInfo(name: "Llama 3.1 405B", provider: "Meta", providerIcon: "cpu", contextWindow: 128000, supportsReasoning: false, supportsImages: false, isLocal: true, route: "local"),
    ]
}

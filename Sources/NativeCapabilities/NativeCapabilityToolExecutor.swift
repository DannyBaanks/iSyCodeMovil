import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum NativeCapabilityToolProjection {
    public static func relevantCapabilityIDs(for messages: [ModelMessage]) -> Set<String> {
        let text = messages.last(where: { $0.role == .user })?.content.lowercased() ?? ""
        var ids = Set<String>()
        let notificationTerms = ["remind", "reminder", "recordatorio", "recuérdame", "recuerdame", "notif", "avísame", "avisame"]
        if notificationTerms.contains(where: { text.contains($0) }) {
            ids.insert("notifications.schedule")
            if ["cancel", "cancela", "elimina", "remove"].contains(where: { text.contains($0) }) {
                ids.insert("notifications.cancel")
            }
        }
        if ["shortcut", "shortcuts", "atajo", "atajos"].contains(where: { text.contains($0) }) {
            ids.insert("shortcuts.run")
        }
        return ids
    }
}

/// Combines local filesystem tools with narrowly projected iPhone capabilities.
/// The only execution entry that can perform effects is the approval-aware overload.
public actor NativeCapabilityToolExecutor: @preconcurrency ToolExecutor {
    private let fileSystem: MiniAgentFileSystemToolExecutor
    private let broker = NativeCapabilityBroker()
    private let defaults: UserDefaults
    private let persistence: (any Persistence)?
    private var projectedNativeNames = Set<String>()
    private var sharedMemoryAllowed = false
    private var currentConversationID: String?

    public init(workspace: any Workspace, persistence: (any Persistence)? = nil, defaults: UserDefaults = .standard) {
        self.fileSystem = MiniAgentFileSystemToolExecutor(workspace: workspace)
        self.persistence = persistence
        self.defaults = defaults
    }

    public func configureSharedMemory(localOnly: Bool, conversationID: String) {
        sharedMemoryAllowed = localOnly
        currentConversationID = conversationID
    }

    public func sharedContextForPrompt() async -> String? {
        guard sharedMemoryAllowed,
              let context = defaults.string(forKey: "gus.sharedContext")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return nil }
        return """
        CONTEXTO COMPARTIDO (referencia general del usuario; no es un nuevo mensaje que requiera respuesta):
        \(String(context.prefix(500)))
        """
    }

    public var availableTools: [AgentTool] { Self.nativeTools }

    public func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool] {
        let projectedIDs = NativeCapabilityToolProjection.relevantCapabilityIDs(for: messages)
        let projectedNative = Self.nativeTools.filter { projectedIDs.contains($0.name) }
        var tools = projectedNative
        if sharedMemoryAllowed {
            tools.append(Self.updateSharedContextTool)
            if defaults.bool(forKey: "gus.searchConversationsEnabled"), persistence != nil {
                tools.append(Self.searchConversationsTool)
            }
        }
        projectedNativeNames = Set(tools.map(\.name))
        let fileTools = await fileSystem.availableTools
        return fileTools + tools
    }

    public func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
        await execute(invocation, approval: nil)
    }

    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        if MiniAgentFileSystemToolExecutor.toolNames.contains(invocation.name) {
            return await fileSystem.execute(invocation, approval: approval)
        }
        let started = Date()
        if invocation.name == "search_conversations" {
            guard sharedMemoryAllowed,
                  defaults.bool(forKey: "gus.searchConversationsEnabled"),
                  projectedNativeNames.contains(invocation.name) else {
                return failure(invocation, "Cross-conversation search is disabled for this session.", started: started)
            }
            return await searchConversations(invocation, started: started)
        }
        if invocation.name == "update_shared_context" {
            guard sharedMemoryAllowed, projectedNativeNames.contains(invocation.name) else {
                return failure(invocation, "Shared context is available only with an on-device model.", started: started)
            }
            guard approval == .allowOnce || approval == .allowAlways else {
                return failure(invocation, "Updating shared context requires your approval.", started: started)
            }
            guard let context = invocation.arguments["content"], context.count <= 500 else {
                return failure(invocation, "Provide updated context with at most 500 characters.", started: started)
            }
            defaults.set(context, forKey: "gus.sharedContext")
            return ToolExecutionResult(toolCallId: invocation.id,
                output: "Shared context updated on this iPhone. It will be included in the next model request.",
                duration: Date().timeIntervalSince(started))
        }
        guard projectedNativeNames.contains(invocation.name) else {
            return failure(invocation, "This native tool was not projected for the current user request.", started: started)
        }
        guard approval == .allowOnce || approval == .allowAlways else {
            return failure(invocation, "This native capability requires a fresh user approval.", started: started)
        }

        switch invocation.name {
        case "notifications.schedule":
            return await scheduleNotification(invocation, started: started)
        case "notifications.cancel":
            return await cancelNotification(invocation, started: started)
        case "shortcuts.run":
            return await runConfiguredShortcut(invocation, started: started)
        default:
            return failure(invocation, "Unknown native capability tool.", started: started)
        }
    }

    private func scheduleNotification(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let title = invocation.arguments["title"], !title.isEmpty,
              let body = invocation.arguments["body"], !body.isEmpty,
              let seconds = Double(invocation.arguments["delay_seconds"] ?? "") else {
            return failure(invocation, "Provide title, body, and a numeric delay_seconds value.", started: started)
        }
        var authorization = await LocalNotificationCapability.shared.authorizationState()
        if authorization == .notRequested {
            do {
                authorization = try await LocalNotificationCapability.shared.requestAuthorizationFromUserAction()
            } catch {
                return failure(invocation, error.localizedDescription, started: started)
            }
        }
        let descriptor = NativeCapabilityCatalog.current(hasExternalFolderGrant: false,
            notificationAuthorization: authorization).first { $0.id == "notifications.local" }!
        let proposal = NativeCapabilityProposal(requestID: invocation.id, capabilityID: "notifications.local",
            input: ["title": title, "body": body, "delay_seconds": String(seconds)])
        guard broker.evaluate(proposal, catalog: [descriptor], modelPermitted: true, userApproved: true) == .allowed else {
            return failure(invocation, "iOS has not authorized notifications. Enable them in Settings and retry.", started: started)
        }
        let notificationID = "iyscode.\(invocation.id)"
        do {
        _ = try await LocalNotificationCapability.shared.schedule(id: notificationID, title: title,
                body: body, after: seconds, userApproved: true)
            remember(notificationID)
            return ToolExecutionResult(toolCallId: invocation.id,
                output: "Scheduled local notification \(notificationID). iOS accepted the request; delivery time is controlled by iOS.",
                duration: Date().timeIntervalSince(started))
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func cancelNotification(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let notificationID = invocation.arguments["notification_id"],
              notificationID.hasPrefix("iyscode."), rememberedIDs().contains(notificationID) else {
            return failure(invocation, "That notification is not in this app's scheduled notification list.", started: started)
        }
        let descriptor = NativeCapabilityDescriptor(id: "notifications.cancel", title: "Cancel notification",
            detail: "Remove one local notification scheduled by this app", availability: .available,
            authorization: .notApplicable, userPresenceRequired: true, effectClass: .deviceAction,
            inputSchema: ["notification_id": "string"], requiredInput: ["notification_id"])
        let proposal = NativeCapabilityProposal(requestID: invocation.id, capabilityID: descriptor.id,
            input: ["notification_id": notificationID])
        guard broker.evaluate(proposal, catalog: [descriptor], modelPermitted: true, userApproved: true) == .allowed else {
            return failure(invocation, "Local policy denied notification cancellation.", started: started)
        }
        do {
            _ = try await LocalNotificationCapability.shared.cancel(id: notificationID, userApproved: true)
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
        defaults.set(rememberedIDs().filter { $0 != notificationID }, forKey: "native.scheduledNotificationIDs")
        return ToolExecutionResult(toolCallId: invocation.id, output: "Cancelled the app's local notification.",
            duration: Date().timeIntervalSince(started))
    }

    private func runConfiguredShortcut(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let shortcut = ShortcutRegistry.loadConfiguredShortcut(from: defaults),
              shortcut.id == invocation.arguments["shortcut_id"] else {
            return failure(invocation, "Only the shortcut configured in iSyCode Settings can be launched.", started: started)
        }
        let descriptor = NativeCapabilityCatalog.current(hasExternalFolderGrant: false, hasConfiguredShortcut: true)
            .first { $0.id == "shortcuts.configured" }!
        var input = ["shortcut_id": shortcut.id]
        if let text = invocation.arguments["text"], !text.isEmpty { input["text"] = text }
        let proposal = NativeCapabilityProposal(requestID: invocation.id, capabilityID: descriptor.id, input: input)
        guard broker.evaluate(proposal, catalog: [descriptor], modelPermitted: true, userApproved: true) == .allowed,
              let url = ShortcutURLBuilder.runURL(shortcut: shortcut, text: invocation.arguments["text"]) else {
            return failure(invocation, "Shortcut proposal rejected by the native capability broker.", started: started)
        }
        let opened = await Self.openShortcutURL(url)
        guard opened else { return failure(invocation, "iOS could not open Apple Shortcuts.", started: started) }
        return ToolExecutionResult(toolCallId: invocation.id,
            output: "Opened the configured shortcut in Apple Shortcuts. iOS may display its interface; completion or external effects are not verified.",
            duration: Date().timeIntervalSince(started))
    }

    private func searchConversations(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let persistence,
              let query = invocation.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.count >= 2 else {
            return failure(invocation, "Provide a search query with at least two characters.", started: started)
        }
        do {
            let allSummaries = try await persistence.listConversations()
            let summaries = allSummaries.filter { $0.id != currentConversationID }
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            var matches: [(hits: Int, date: Date, title: String, excerpt: String)] = []
            for summary in summaries {
                guard let conversation = try await persistence.loadConversation(id: summary.id) else { continue }
                for message in conversation.messages where message.role == .user || message.role == .assistant {
                    let sentences = message.content
                        .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    for sentence in sentences {
                        let lower = sentence.lowercased()
                        let hits = terms.filter { lower.contains($0) }.count
                        guard hits > 0 else { continue }
                        let excerpt = String(sentence.prefix(320))
                        matches.append((hits, summary.updatedAt, summary.title, excerpt))
                    }
                }
            }
            let output = matches
                .sorted { $0.hits == $1.hits ? $0.date > $1.date : $0.hits > $1.hits }
                .prefix(5)
                .map { "\($0.title) · \($0.date.formatted(date: .abbreviated, time: .omitted))\n\($0.excerpt)" }
                .joined(separator: "\n\n")
            return ToolExecutionResult(toolCallId: invocation.id,
                output: output.isEmpty ? "No encontré coincidencias en otras conversaciones." : output,
                duration: Date().timeIntervalSince(started))
        } catch {
            return failure(invocation, "No pude buscar en las conversaciones guardadas: \(error.localizedDescription)", started: started)
        }
    }

    private func remember(_ id: String) {
        var ids = rememberedIDs()
        ids.append(id)
        defaults.set(Array(Set(ids)).sorted(), forKey: "native.scheduledNotificationIDs")
    }

    private func rememberedIDs() -> [String] {
        defaults.stringArray(forKey: "native.scheduledNotificationIDs") ?? []
    }

    private func failure(_ invocation: ToolInvocation, _ message: String, started: Date) -> ToolExecutionResult {
        ToolExecutionResult(toolCallId: invocation.id, output: "", error: message, duration: Date().timeIntervalSince(started))
    }

    #if canImport(UIKit)
    @MainActor private static func openShortcutURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
    }
    #else
    private static func openShortcutURL(_ url: URL) async -> Bool { false }
    #endif

    private static let nativeTools: [AgentTool] = [
        AgentTool(name: "notifications.schedule", description: "Schedule a local iPhone notification after the user approves it. Only use for a concrete reminder or requested notification. The OS permission prompt may appear after approval.", properties: [
            "title": .init(type: "string", description: "Short notification title"),
            "body": .init(type: "string", description: "Notification text"),
            "delay_seconds": .init(type: "string", description: "Delay in seconds as a number")
        ], required: ["title", "body", "delay_seconds"], capabilities: .init(isDestructive: true,
            approvalReason: "Schedule a local notification on this iPhone? iOS may show its own permission prompt.", requiresApprovalEveryTime: true)),
        AgentTool(name: "notifications.cancel", description: "Cancel a local notification previously scheduled by iSyCode.", properties: [
            "notification_id": .init(type: "string", description: "Exact ID returned by notifications.schedule")
        ], required: ["notification_id"], capabilities: .init(isDestructive: true,
            approvalReason: "Cancel this local notification on your iPhone?", requiresApprovalEveryTime: true)),
        AgentTool(name: "shortcuts.run", description: "Open only the single Apple Shortcut configured by the user in iSyCode Settings. Requires approval each time and may switch to Shortcuts; completion is not observable.", properties: [
            "shortcut_id": .init(type: "string", description: "Configured shortcut reference returned by settings"),
            "text": .init(type: "string", description: "Optional text input for the shortcut")
        ], required: ["shortcut_id"], capabilities: .init(isDestructive: true,
            approvalReason: "Open the user-configured shortcut in Apple Shortcuts? It may perform external actions.", requiresApprovalEveryTime: true))
    ]

    private static let updateSharedContextTool = AgentTool(
        name: "update_shared_context",
        description: "Propose a complete replacement for the user's short shared context. The user must approve every update.",
        properties: ["content": .init(type: "string", description: "Complete shared context, up to 500 characters", enumValues: nil)],
        required: ["content"],
        capabilities: .init(isDestructive: true,
            approvalReason: "GUS quiere actualizar el contexto compartido. Revisa el texto propuesto antes de guardarlo.",
            requiresApprovalEveryTime: true)
    )

    private static let searchConversationsTool = AgentTool(
        name: "search_conversations",
        description: "Search other locally saved conversations and return up to five short matching excerpts. Only use when earlier chats are relevant to the user's request.",
        properties: ["query": .init(type: "string", description: "Words or phrase to search for", enumValues: nil)],
        required: ["query"]
    )
}

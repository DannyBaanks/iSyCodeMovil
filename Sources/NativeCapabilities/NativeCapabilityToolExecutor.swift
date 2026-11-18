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
    /// Seven flat tools for on-device models, plus `clone` for everyone.
    private let simple: SimpleWorkspaceToolExecutor
    /// On-device models get the simple surface; cloud models keep the full catalog.
    private var simpleToolsEnabled = false
    private let broker = NativeCapabilityBroker()
    /// Google and memory tools from the Asistente (Sources/Assistant).
    private let assistant: AssistantToolExecutor
    private let defaults: UserDefaults
    private let persistence: (any Persistence)?
    private var projectedNativeNames = Set<String>()
    private var sharedMemoryAllowed = false
    private var currentConversationID: String?
    /// Set for on-device GUS: tools the person switched off in Ajustes are never offered or run.
    private var enforceGUSPermissionToggles = false
    private let localIphone: LocalIphoneController
    private static let localIphoneTools = IphoneControlCatalog.tools(allowed: Array(LocalIphoneController.supportedToolNames))
    private let l1Registry: DynamicToolRegistry
    private let secretResolver: SecretVaultRuntimeResolver
    private var activeL1CallStack: Set<String> = []
    private var activeContract: AgentContract?

    public init(
        workspace: any Workspace,
        persistence: (any Persistence)? = nil,
        defaults: UserDefaults = .standard,
        l1Registry: DynamicToolRegistry = .shared,
        secretResolver: SecretVaultRuntimeResolver = .shared,
        localIphone: LocalIphoneController = LocalIphoneController(wda: WdaClientDriver(client: WdaClient()), elementReader: WdaElementReader()),
        activeProjectKey: String = SimpleWorkspaceToolExecutor.activeProjectKey
    ) {
        self.fileSystem = MiniAgentFileSystemToolExecutor(workspace: workspace)
        self.simple = SimpleWorkspaceToolExecutor(workspace: workspace, defaults: defaults, activeProjectKey: activeProjectKey)
        self.persistence = persistence
        self.defaults = defaults
        self.assistant = AssistantToolExecutor()
        self.l1Registry = l1Registry
        self.secretResolver = secretResolver
        self.localIphone = localIphone
    }

    public func setActiveContract(_ contract: AgentContract?) async {
        self.activeContract = contract
        if let contract {
            for l1 in contract.l1Tools {
                try? await l1Registry.upsert(l1)
            }
        }
    }

    /// Shared context plus the memory notes that fit the latest user message.
    public func promptContext(for messages: [ModelMessage]) async -> String? {
        let parts = [await sharedContextForPrompt(), await assistant.memoryContext(for: messages)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public func configureSharedMemory(localOnly: Bool, conversationID: String) {
        sharedMemoryAllowed = localOnly
        simpleToolsEnabled = localOnly
        currentConversationID = conversationID
    }

    public func sharedContextForPrompt() async -> String? {
        var notes: [String] = []
        if simpleToolsEnabled, let project = await simple.projectNote() {
            notes.append(project)
        }
        if sharedMemoryAllowed,
           let context = defaults.string(forKey: "gus.sharedContext")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty {
            notes.append("""
            CONTEXTO COMPARTIDO (referencia general del usuario; no es un nuevo mensaje que requiera respuesta):
            \(String(context.prefix(500)))
            """)
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    // MARK: - Disposable clones

    /// Downloads a public GitHub repository and makes it the active project.
    public func cloneRepository(_ repository: String) async throws -> RepositoryCloner.Report {
        try await simple.cloneRepository(repository)
    }

    public func activeProject() async -> String? {
        await simple.activeProject()
    }

    public func closeActiveProject() async {
        await simple.setActiveProject(nil)
    }

    public func canUndoLastChange() async -> Bool {
        await simple.canUndo
    }

    public func undoLastChange() async throws -> String {
        try await simple.undoLastChange()
    }

    public var availableTools: [AgentTool] {
        Self.nativeTools + [Self.httpRequestTool, Self.pythonEvalTool] + Self.isymcpTools + Self.localIphoneTools + Self.secretVaultAndLearnTools + DynamicToolRegistry.metaTools
    }

    public func setGUSPermissionMode(_ enabled: Bool) {
        enforceGUSPermissionToggles = enabled
    }

    /// A tool is blocked when it maps to a catalogued GUS permission the person turned off.
    private func blockedByGUSPermission(_ toolName: String) -> Bool {
        guard enforceGUSPermissionToggles else { return false }
        if toolName == "undo" {
            return !GUSToolPermissionCatalog.isEnabled("edit_file", defaults: defaults)
                && !GUSToolPermissionCatalog.isEnabled("write_file", defaults: defaults)
        }
        let permissionID = Self.gusPermissionID(for: toolName)
        return GUSToolPermissionCatalog.permissions.contains { $0.id == permissionID }
            && !GUSToolPermissionCatalog.isEnabled(permissionID, defaults: defaults)
    }

    private static func gusPermissionID(for toolName: String) -> String {
        switch toolName {
        case "list": return "list_directory"
        case "read", "read_file_range": return "read_file"
        case "find", "search_text": return "search_files"
        case "edit", "replace_lines": return "edit_file"
        case "write", "append_file", "copy_file": return "write_file"
        default: return toolName
        }
    }

    public func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool] {
        let projectedIDs = NativeCapabilityToolProjection.relevantCapabilityIDs(for: messages)
        let projectedNative = Self.nativeTools.filter { projectedIDs.contains($0.name) }
        var tools = projectedNative
        tools.append(Self.httpRequestTool)
        tools.append(Self.pythonEvalTool)
        tools.append(contentsOf: Self.isymcpTools)
        tools.append(contentsOf: Self.localIphoneTools)
        tools.append(contentsOf: Self.secretVaultAndLearnTools)
        tools.append(contentsOf: DynamicToolRegistry.metaTools)
        tools.append(contentsOf: await assistant.tools(relevantTo: messages))
        if sharedMemoryAllowed {
            tools.append(Self.updateSharedContextTool)
            if defaults.bool(forKey: "gus.searchConversationsEnabled"), persistence != nil {
                tools.append(Self.searchConversationsTool)
            }
        }
        let fileTools = (await fileSystem.availableTools).filter { !blockedByGUSPermission($0.name) }
        let simpleTools = (await simple.tools()).filter { !blockedByGUSPermission($0.name) }
        var l0Catalog: [String: AgentTool] = [:]
        for t in (fileTools + simpleTools + tools) {
            l0Catalog[t.name] = t
        }
        let l1Tools = await l1Registry.allAgentTools(l0Catalog: l0Catalog)
        tools.append(contentsOf: l1Tools)
        tools = tools.filter { !blockedByGUSPermission($0.name) }
        if simpleToolsEnabled {
            let combined = simpleTools + tools
            projectedNativeNames = Set(combined.map(\.name))
            return combined
        }
        let combined = fileTools + [SimpleWorkspaceToolExecutor.cloneTool] + tools
        projectedNativeNames = Set(combined.map(\.name))
        return combined
    }

    public func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
        await execute(invocation, approval: nil)
    }

    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        guard !blockedByGUSPermission(invocation.name) else {
            return failure(invocation, "La persona desactivó este permiso de GUS en Ajustes.", started: Date())
        }
        if simpleToolsEnabled, SimpleWorkspaceToolExecutor.toolNames.contains(invocation.name) {
            return await simple.execute(invocation, approval: approval)
        }
        if invocation.name == SimpleWorkspaceToolExecutor.cloneTool.name {
            // Cloud models use the full catalog, whose paths stay relative to the workspace.
            return await simple.execute(invocation, approval: approval, scopeToProject: false)
        }
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
        guard projectedNativeNames.contains(invocation.name) || !activeL1CallStack.isEmpty else {
            return failure(invocation, "This native tool was not projected for the current user request.", started: started)
        }
        if AssistantToolExecutor.handles(invocation.name) {
            return await assistant.execute(invocation, approval: approval)
        }
        if invocation.name == "secret_vault_list" {
            let output = await MainActor.run { SecretVaultStore.shared.safeCatalogLines() }
            return ToolExecutionResult(toolCallId: invocation.id, output: output, duration: Date().timeIntervalSince(started))
        }
        if invocation.name == "secret_vault_request_entry" {
            let alias = invocation.arguments["alias"] ?? "credencial"
            let label = invocation.arguments["label"] ?? alias
            let domain = invocation.arguments["domain"] ?? ""
            await MainActor.run {
                SecretVaultStore.shared.requestNewEntryFromAgent(alias: alias, label: label, domain: domain)
            }
            return ToolExecutionResult(
                toolCallId: invocation.id,
                output: "Se preparó la ficha del Llavero para '\(label)' (alias: {{secret:\(SecretVaultEntryMetadata.normalizeAlias(alias))}}). Pídele a la persona que toque el botón 'Abrir Llavero' para guardar su usuario y contraseña de forma cifrada sin escribirlos aquí.",
                duration: Date().timeIntervalSince(started)
            )
        }
        if invocation.name == "learn_action_prepare" {
            let title = invocation.arguments["title"] ?? "Acción personalizada"
            let goal = invocation.arguments["goal"] ?? title
            let paramsRaw = invocation.arguments["parameters"] ?? ""
            let secretsRaw = invocation.arguments["secret_aliases"] ?? ""
            let params = paramsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let secrets = secretsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            await MainActor.run {
                ActionRecorderService.shared.prepareSession(
                    goalTitle: title,
                    goalDescription: goal,
                    parameters: params,
                    linkedSecretAliases: secrets,
                    fromAgent: true
                )
            }
            let slug = ActionRecorderDiffEngine.suggestToolSlug(from: title)
            return ToolExecutionResult(
                toolCallId: invocation.id,
                output: "Grabador 'Aprender acción' preparado para '\(title)' (nombre sugerido: \(slug), parámetros: \(params.isEmpty ? "ninguno" : params.joined(separator: ", ")), secretos vinculados: \(secrets.isEmpty ? "ninguno" : secrets.joined(separator: ", "))). Indica a la persona que toque 'Iniciar grabación' en la tarjeta superior y haga el flujo normal en la app destino.",
                duration: Date().timeIntervalSince(started)
            )
        }
        if invocation.name == "learn_action_status" {
            let summary = await MainActor.run { ActionRecorderService.shared.statusSummaryForAgent() }
            return ToolExecutionResult(toolCallId: invocation.id, output: summary, duration: Date().timeIntervalSince(started))
        }
        if LocalIphoneController.supportedToolNames.contains(invocation.name) {
            let usesSecrets = SecretVaultStore.containsSecretReference(in: invocation.arguments)
            var resolvedArguments = invocation.arguments
            var secretsToRedact: [String] = []
            var usedAliases: [String] = []
            if usesSecrets {
                guard approval == .allowOnce else {
                    return failure(invocation, "Inyectar un secreto del Llavero ({{secret:...}}) exige aprobación individual explícita cada vez.", started: started)
                }
                do {
                    let resolved = try await secretResolver.resolvePlaceholders(in: invocation.arguments)
                    resolvedArguments = resolved.arguments
                    secretsToRedact = resolved.resolvedSecrets
                    usedAliases = resolved.usedAliases
                } catch {
                    return failure(invocation, error.localizedDescription, started: started)
                }
            }
            do {
                let parsed = try IphoneControlCatalog.arguments(for: invocation.name, from: resolvedArguments)
                let rawOutput = try await localIphone.call(tool: invocation.name, arguments: parsed)
                let cleanOutput: String
                if usesSecrets && invocation.name == "iphone_type_text" {
                    cleanOutput = "[Llavero] Credencial (\(usedAliases.joined(separator: ", "))) escrita de forma protegida en pantalla (valor oculto al modelo)."
                } else {
                    cleanOutput = SecretVaultStore.redact(rawOutput, secrets: secretsToRedact)
                }
                return ToolExecutionResult(
                    toolCallId: invocation.id,
                    output: cleanOutput,
                    duration: Date().timeIntervalSince(started)
                )
            } catch {
                let redactedError = SecretVaultStore.redact(error.localizedDescription, secrets: secretsToRedact)
                return failure(invocation, redactedError, started: started)
            }
        }
        if invocation.name == "http_request" {
            return await runHTTPRequest(invocation, started: started)
        }
        if invocation.name == "python_eval" {
            return await runPythonEval(invocation, started: started)
        }
        if invocation.name.hasPrefix("isymcp_") {
            return await runISyMCPTool(invocation, approval: approval, started: started)
        }
        if DynamicToolRegistry.metaToolNames.contains(invocation.name) {
            return await runL1MetaTool(invocation, started: started)
        }
        if let l1Def = await l1Registry.definition(named: invocation.name) {
            return await runL1Definition(l1Def, invocation: invocation, approval: approval, started: started)
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
        case "browser_navigate":
            return await runBrowserNavigate(invocation, started: started)
        case "browser_get_page":
            return await runBrowserGetPage(invocation, started: started)
        case "browser_click":
            return await runBrowserClick(invocation, started: started)
        case "browser_input":
            return await runBrowserInput(invocation, approval: approval, started: started)
        case "browser_scroll":
            return await runBrowserScroll(invocation, started: started)
        default:
            return failure(invocation, "Unknown native capability tool.", started: started)
        }
    }

    private func browserResult(_ result: Result<String, InAppBrowserError>, for invocation: ToolInvocation, started: Date) -> ToolExecutionResult {
        switch result {
        case .success(let message):
            return ToolExecutionResult(toolCallId: invocation.id, output: message, duration: Date().timeIntervalSince(started))
        case .failure(let error):
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func runBrowserNavigate(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let url = invocation.arguments["url"], !url.isEmpty else {
            return failure(invocation, "Falta el argumento url.", started: started)
        }
        return browserResult(await InAppBrowserService.shared.navigate(to: url, byAgent: true), for: invocation, started: started)
    }

    private func runBrowserGetPage(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        browserResult(await InAppBrowserService.shared.getPageInfo(includeContent: true), for: invocation, started: started)
    }

    private func runBrowserClick(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        let elementId = invocation.arguments["element_id"]
        let selector = invocation.arguments["selector"]
        return browserResult(await InAppBrowserService.shared.click(elementId: elementId, selector: selector), for: invocation, started: started)
    }

    private func runBrowserInput(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?, started: Date) async -> ToolExecutionResult {
        guard let rawText = invocation.arguments["text"] else {
            return failure(invocation, "Falta el argumento text.", started: started)
        }
        let elementId = invocation.arguments["element_id"]
        let selector = invocation.arguments["selector"]
        let usesSecrets = SecretVaultStore.containsSecretReference(in: ["text": rawText])
        var finalText = rawText
        var secretsToRedact: [String] = []
        if usesSecrets {
            guard approval == .allowOnce else {
                return failure(invocation, "Escribir una credencial del Llavero en el navegador exige aprobación individual.", started: started)
            }
            do {
                let res = try await secretResolver.resolvePlaceholders(in: ["text": rawText])
                finalText = res.arguments["text"] ?? rawText
                secretsToRedact = res.resolvedSecrets
            } catch {
                return failure(invocation, error.localizedDescription, started: started)
            }
        }
        let outcome = await InAppBrowserService.shared.input(elementId: elementId, selector: selector, text: finalText)
        switch outcome {
        case .success(let message):
            let clean = usesSecrets
                ? "[Llavero] Credencial escrita de forma protegida en el campo web (valor oculto)."
                : SecretVaultStore.redact(message, secrets: secretsToRedact)
            return ToolExecutionResult(toolCallId: invocation.id, output: clean, duration: Date().timeIntervalSince(started))
        case .failure(let error):
            return failure(invocation, SecretVaultStore.redact(error.localizedDescription, secrets: secretsToRedact), started: started)
        }
    }

    private func runBrowserScroll(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        let direction = invocation.arguments["direction"] ?? "down"
        return browserResult(await InAppBrowserService.shared.scroll(direction: direction), for: invocation, started: started)
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

    private func runHTTPRequest(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let rawURL = invocation.arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return failure(invocation, "URL inválida (usa http:// o https://).", started: started)
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = (invocation.arguments["method"] ?? "GET").uppercased()
        if let headersJSON = invocation.arguments["headers_json"]?.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersJSON) as? [String: String] {
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        }
        if let body = invocation.arguments["body"], !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(12_000), encoding: .utf8) ?? "<\(data.count) bytes>"
            return ToolExecutionResult(toolCallId: invocation.id, output: "HTTP \(status)\n\(text)", duration: Date().timeIntervalSince(started))
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func runL1MetaTool(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        do {
            let output: String
            switch invocation.name {
            case "l1_create_tool":
                output = try await l1Registry.createTool(arguments: invocation.arguments)
            case "l1_list_tools":
                output = await l1Registry.listToolsText()
            case "l1_delete_tool":
                let name = invocation.arguments["name"] ?? ""
                output = try await l1Registry.deleteTool(named: name)
            default:
                output = "Tool L1 desconocida."
            }
            return ToolExecutionResult(toolCallId: invocation.id, output: output, duration: Date().timeIntervalSince(started))
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func runPythonEval(_ invocation: ToolInvocation, started: Date) async -> ToolExecutionResult {
        guard let script = invocation.arguments["script"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            return failure(invocation, "Falta el argumento 'script' con el código Python a ejecutar.", started: started)
        }
        let inputText = invocation.arguments["input_text"] ?? ""
        let timeoutMs = Int32(invocation.arguments["timeout_ms"] ?? "") ?? PythonRuntimeService.defaultTimeoutMs
        let receipt = await PythonRuntimeService.shared.evaluate(
            script: script,
            inputText: inputText,
            timeoutMs: timeoutMs
        )
        if !receipt.succeeded {
            return failure(invocation, receipt.error ?? "Falló la ejecución en Python local.", started: started)
        }
        let cleanOutput = receipt.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: cleanOutput.isEmpty ? "(ejecutado en \(receipt.durationMs)ms sin salida en print)" : cleanOutput,
            duration: Date().timeIntervalSince(started)
        )
    }

    private func runISyMCPTool(
        _ invocation: ToolInvocation,
        approval: PermissionResponse.Decision?,
        started: Date
    ) async -> ToolExecutionResult {
        guard let client = ISyMCPStore.currentClient else {
            return failure(
                invocation,
                "ISyMCP (PC) no está emparejado en este momento. Para ejecutar compiladores, shell o revisar consolas remotas, empareja tu computadora en Conexiones → ISyMCP (Tailscale :8797). Si solo necesitas procesar datos, CSV o JSON, puedes usar 'python_eval' localmente en este iPhone.",
                started: started
            )
        }
        do {
            switch invocation.name {
            case "isymcp_status":
                let status = try await client.request("GET", "/v1/status")
                let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
                return ToolExecutionResult(
                    toolCallId: invocation.id,
                    output: String(data: data, encoding: .utf8) ?? "{}",
                    duration: Date().timeIntervalSince(started)
                )
            case "isymcp_tasks":
                let limit = Int(invocation.arguments["limit"] ?? "10") ?? 10
                let res = try await client.request("GET", "/v1/tasks?limit=\(max(1, min(limit, 50)))")
                let data = try JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys])
                return ToolExecutionResult(
                    toolCallId: invocation.id,
                    output: String(data: data, encoding: .utf8) ?? "{}",
                    duration: Date().timeIntervalSince(started)
                )
            case "isymcp_respond_task":
                guard approval == .allowOnce || approval == .allowAlways else {
                    return failure(invocation, "Responder una tarea de ISyMCP requiere tu confirmación explícita.", started: started)
                }
                guard let taskID = invocation.arguments["task_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !taskID.isEmpty,
                      let summary = invocation.arguments["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !summary.isEmpty else {
                    return failure(invocation, "Proporciona 'task_id' y 'summary'.", started: started)
                }
                let res = try await client.request(
                    "POST",
                    "/v1/tasks/\(taskID)/respond",
                    body: ["summary": summary],
                    key: .approve,
                    reason: "Enviar recibo a tarea \(taskID) en ISyMCP"
                )
                let data = try JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys])
                return ToolExecutionResult(
                    toolCallId: invocation.id,
                    output: String(data: data, encoding: .utf8) ?? "{}",
                    duration: Date().timeIntervalSince(started)
                )
            default:
                return failure(invocation, "Herramienta ISyMCP desconocida.", started: started)
            }
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func runL1Definition(
        _ def: L1ToolDefinition,
        invocation: ToolInvocation,
        approval: PermissionResponse.Decision?,
        started: Date
    ) async -> ToolExecutionResult {
        guard !activeL1CallStack.contains(def.name) else {
            return failure(invocation, "Ciclo detectado al ejecutar la herramienta L1 '\(def.name)'.", started: started)
        }
        guard activeL1CallStack.count < 4 else {
            return failure(invocation, "Profundidad máxima de herramientas L1 excedida (máx. 4).", started: started)
        }
        let effectiveCaps = DynamicToolRegistry.effectiveCapabilities(for: def)
        if effectiveCaps.isDestructive {
            let validApproval = approval == .allowOnce || approval == .allowAlways || approval == .allowSequence
            guard validApproval else {
                return failure(
                    invocation,
                    effectiveCaps.approvalReason ?? "La herramienta L1 '\(def.name)' requiere autorización para sus pasos sensibles.",
                    started: started
                )
            }
        }
        activeL1CallStack.insert(def.name)
        defer { activeL1CallStack.remove(def.name) }

        let everyTimeTools: Set<String> = [
            "iphone_type_text", "iphone_open_url", "notifications.schedule",
            "notifications.cancel", "shortcuts.run", "open_pull_request",
            "isymcp_respond_task", "update_shared_context"
        ]
        var consumedEveryTimeApproval = false
        var prevOutput = ""
        var trace: [String] = []
        for (index, step) in def.steps.enumerated() {
            if step.tool == def.name || DynamicToolRegistry.metaToolNames.contains(step.tool) {
                return failure(invocation, "Paso \(index + 1) inválido en L1 '\(def.name)': no se permiten llamadas recursivas ni meta-herramientas.", started: started)
            }
            if blockedByGUSPermission(step.tool) {
                return failure(invocation, "Paso \(index + 1) (\(step.tool)) bloqueado: permiso desactivado en Ajustes.", started: started)
            }
            let stepHasSecret = SecretVaultStore.containsSecretReference(in: step.args)
            let stepNeedsEveryTime = everyTimeTools.contains(step.tool.lowercased()) || stepHasSecret
            if stepNeedsEveryTime {
                let coveredBySequence = approval == .allowSequence && step.tool.hasPrefix("iphone_") && !stepHasSecret
                if !coveredBySequence {
                    if approval == .allowAlways || consumedEveryTimeApproval {
                        return failure(
                            invocation,
                            "El paso \(index + 1) (\(step.tool)) exige confirmación individual cada vez y no puede combinarse con una autorización múltiple o 'siempre' dentro de una tool L1.",
                            started: started
                        )
                    }
                    guard approval == .allowOnce else {
                        return failure(invocation, "El paso \(index + 1) (\(step.tool)) requiere autorización explícita.", started: started)
                    }
                    consumedEveryTimeApproval = true
                }
            }
            var resolvedArgs: [String: String] = [:]
            for (k, template) in step.args {
                var val = template.replacingOccurrences(of: "{{prev_output}}", with: prevOutput)
                for (argKey, argVal) in invocation.arguments {
                    val = val.replacingOccurrences(of: "{{\(argKey)}}", with: argVal)
                }
                resolvedArgs[k] = val
            }
            let subInvocation = ToolInvocation(
                id: "\(invocation.id)-l1-\(index)",
                name: step.tool,
                arguments: resolvedArgs
            )
            // Never escalate: pass only the user's real approval. Sequence approval only covers iphone_* steps without secrets.
            let stepApproval: PermissionResponse.Decision?
            if approval == .allowSequence && !stepHasSecret {
                stepApproval = step.tool.hasPrefix("iphone_") ? .allowOnce : nil
            } else {
                stepApproval = approval
            }
            let stepResult = await execute(subInvocation, approval: stepApproval)
            if let err = stepResult.error, !err.isEmpty {
                return failure(invocation, "Paso \(index + 1) (\(step.tool)) falló: \(err)", started: started)
            }
            prevOutput = stepResult.output
            trace.append("[\(index + 1)] \(step.tool): \(String(stepResult.output.prefix(600)))")
        }
        return ToolExecutionResult(
            toolCallId: invocation.id,
            output: trace.joined(separator: "\n---\n"),
            duration: Date().timeIntervalSince(started)
        )
    }

    private static let pythonEvalTool = AgentTool(
        name: "python_eval",
        description: "Primitiva L0 de Python local (pocketpy 2.2.0 embebido, sin OS/red): ejecuta scripts ligeros de Python 3 en memoria con watchdog de tiempo para procesar datos, CSV (`import csv; rows = csv.parse(INPUT_TEXT)`), JSON (`import json`), cálculos (`import math`) y validaciones. Usa listas por comprensión `sum([x for x in items])`. No tiene acceso a archivos ni red por su cuenta.",
        properties: [
            "script": .init(type: "string", description: "Código Python 3 a ejecutar. Imprime el resultado con print()."),
            "input_text": .init(type: "string", description: "Texto o JSON opcional que estará disponible como variable global INPUT_TEXT (y INPUT si es JSON)."),
            "timeout_ms": .init(type: "string", description: "Tiempo máximo en milisegundos (50..15000, por defecto 3000).")
        ],
        required: ["script"],
        capabilities: .init(
            restrictions: [
                "Ejecución en memoria con PK_ENABLE_OS=0 (sin os, open, subprocesos ni sockets) y watchdog de instrucciones.",
                "No constituye aislamiento de proceso del sistema operativo; para código nativo o no confiable usa ISyMCP remoto."
            ]
        )
    )

    private static let secretVaultAndLearnTools: [AgentTool] = [
        AgentTool(
            name: "secret_vault_list",
            description: "Lista ÚNICAMENTE los aliases, dominios y campos disponibles en el Llavero de este iPhone (por ejemplo {{secret:fel_mx.username}}, {{secret:fel_mx.password}}). Jamás devuelve contraseñas en texto plano.",
            properties: [:],
            required: []
        ),
        AgentTool(
            name: "secret_vault_request_entry",
            description: "Prepara una tarjeta para que la persona guarde de forma segura un usuario y contraseña en el Llavero (Keychain con Face ID) para usar en automatizaciones como portales web o FEL.",
            properties: [
                "alias": .init(type: "string", description: "Alias corto en snake_case, por ejemplo 'fel_mx'."),
                "label": .init(type: "string", description: "Nombre amigable, por ejemplo 'Portal FEL.mx'."),
                "domain": .init(type: "string", description: "Dominio o app asociada, por ejemplo 'fel.mx'.")
            ],
            required: ["alias", "label"]
        ),
        AgentTool(
            name: "learn_action_prepare",
            description: "Prepara el modo 'Aprender acción' (polling visual por WDA en segundo plano) para que el usuario salga de ISyCode, realice manualmente el flujo (ej. WhatsApp o hacer factura en FEL.mx) y se compile en una herramienta L1 reutilizable. Antes de llamarla, pregunta al usuario si hace falta qué parámetros cambian cada vez y si usará una llave del Llavero.",
            properties: [
                "title": .init(type: "string", description: "Nombre corto de la acción, por ejemplo 'Enviar mensaje por WhatsApp' o 'Facturar en FEL.mx'."),
                "goal": .init(type: "string", description: "Descripción clara de qué debe lograr la automatización."),
                "parameters": .init(type: "string", description: "Lista separada por comas de variables dinámicas que cambiarán en cada uso (ej. 'contacto, mensaje' o 'nit, monto, concepto')."),
                "secret_aliases": .init(type: "string", description: "Lista opcional separada por comas de aliases del Llavero vinculados (ej. 'fel_mx').")
            ],
            required: ["title", "goal"]
        ),
        AgentTool(
            name: "learn_action_status",
            description: "Consulta el estado actual del grabador de acciones por WDA (en curso, pausado, listo para compilar o si WDA no está conectado).",
            properties: [:],
            required: []
        )
    ]

    private static let isymcpTools: [AgentTool] = [
        AgentTool(
            name: "isymcp_status",
            description: "Primitiva L0 remota (ISyMCP por Tailscale :8797): consulta el estado del centro de control en tu PC, compuertas de permisos (shell/agents), marca de contenido externo (taint) y consolas activas.",
            properties: [:],
            capabilities: .init(requiresNetwork: true)
        ),
        AgentTool(
            name: "isymcp_tasks",
            description: "Primitiva L0 remota (ISyMCP por Tailscale :8797): lista las tareas recientes del bus SQLite WAL del monitor de tu PC y sus recibos.",
            properties: [
                "limit": .init(type: "string", description: "Número máximo de tareas (1..50, por defecto 10).")
            ],
            capabilities: .init(requiresNetwork: true)
        ),
        AgentTool(
            name: "isymcp_respond_task",
            description: "Primitiva L0 remota (ISyMCP por Tailscale :8797): envía un resumen/recibo firmado con Face ID a una tarea del monitor de tu PC.",
            properties: [
                "task_id": .init(type: "string", description: "ID de la tarea en el monitor de ISyMCP."),
                "summary": .init(type: "string", description: "Resumen verificable del resultado.")
            ],
            required: ["task_id", "summary"],
            capabilities: .init(
                requiresNetwork: true,
                isDestructive: true,
                approvalReason: "Enviar un recibo firmado a una tarea de ISyMCP en tu computadora (requiere tu confirmación y Face ID).",
                requiresApprovalEveryTime: true
            )
        )
    ]

    private static let httpRequestTool = AgentTool(
        name: "http_request",
        description: "Primitiva L0 de red: realiza una petición HTTP/HTTPS (GET, POST, PUT, DELETE) a APIs externas o endpoints locales (ej. http://127.0.0.1:8100/status).",
        properties: [
            "url": .init(type: "string", description: "URL completa http:// o https://"),
            "method": .init(type: "string", description: "Método HTTP (GET, POST, PUT, DELETE). Por defecto GET."),
            "headers_json": .init(type: "string", description: "JSON objeto opcional de cabeceras."),
            "body": .init(type: "string", description: "Cuerpo opcional de la petición.")
        ],
        required: ["url"],
        capabilities: .init(requiresNetwork: true)
    )

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
            approvalReason: "Open the user-configured shortcut in Apple Shortcuts? It may perform external actions.", requiresApprovalEveryTime: true)),
        AgentTool(name: "browser_navigate", description: "Abre una página web en el navegador integrado de iSyCode (sin salir de la app).", properties: [
            "url": .init(type: "string", description: "Dirección web (https://...)")
        ], required: ["url"], capabilities: .init(requiresNetwork: true)),
        AgentTool(name: "browser_get_page", description: "Lee el título, URL y contenido simplificado (enlaces, botones y campos con [#id]) de la página actual del navegador integrado.", properties: [:], required: [], capabilities: .init(requiresNetwork: true)),
        AgentTool(name: "browser_click", description: "Toca un enlace o botón en el navegador integrado usando element_id (el #id devuelto por browser_get_page) o un selector CSS.", properties: [
            "element_id": .init(type: "string", description: "ID corto devuelto por browser_get_page, sin #"),
            "selector": .init(type: "string", description: "Selector CSS alternativo")
        ], required: [], capabilities: .init(requiresNetwork: true)),
        AgentTool(name: "browser_input", description: "Escribe texto en un campo del navegador integrado usando element_id o selector CSS.", properties: [
            "element_id": .init(type: "string", description: "ID corto devuelto por browser_get_page, sin #"),
            "selector": .init(type: "string", description: "Selector CSS alternativo"),
            "text": .init(type: "string", description: "Texto a escribir")
        ], required: ["text"], capabilities: .init(requiresNetwork: true)),
        AgentTool(name: "browser_scroll", description: "Desplaza la página del navegador integrado hacia arriba o abajo.", properties: [
            "direction": .init(type: "string", description: "down o up", enumValues: ["down", "up"])
        ], required: [], capabilities: .init(requiresNetwork: true))
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

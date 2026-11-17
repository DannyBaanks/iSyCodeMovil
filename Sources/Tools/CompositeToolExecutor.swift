import Foundation

/// Joins the tools of the sandbox (files, commands, the computer's iPhone control) with the iPhone's own
/// companion tools: Google (Gmail, Calendar, Tasks, Drive...), notifications and Shortcuts.
///
/// Why it exists: with a sandbox linked the agent used ONLY the sandbox executor, so it lost everything native
/// and could not read the person's mail even though the Google connection was working.
///
/// Rules, all enforced here:
/// - The primary executor (the sandbox) wins any name clash, and the secondary's own file tools never come
///   through: `read_file`, `write_file`... exist in both and act on different files, which would confuse the model.
///   Only the names `isCompanionTool` accepts are taken from the secondary.
/// - Reading personal data asks first. Google reads were silent, but with a cloud model that content travels to the
///   model's provider, which the app promises never to do without the person's confirmation. The first read asks
///   (with the "approve always" choice); writes keep the approval they already had.
/// - A call goes to whoever offers the tool. Approvals pass through unchanged.
public final class CompositeToolExecutor: ToolExecutor, @unchecked Sendable {
    private let primary: any ToolExecutor
    private let secondary: any ToolExecutor
    private let allows: @Sendable (String) -> Bool
    private let consentForReads: Bool

    public init(
        primary: any ToolExecutor,
        secondary: any ToolExecutor,
        allows: @escaping @Sendable (String) -> Bool = CompositeToolExecutor.isCompanionTool,
        consentForReads: Bool = true
    ) {
        self.primary = primary
        self.secondary = secondary
        self.allows = allows
        self.consentForReads = consentForReads
    }

    // MARK: - What counts as a companion tool

    /// Prefixes of the secondary tools worth bringing into the sandbox agent. Native file tools and the on-device
    /// memory tools are deliberately left out.
    private static let companionPrefixes = [
        "gmail.", "googlecalendar.", "googletasks.", "googledrive.", "googledocs.", "googlecontacts.",
        "googlesheets.", "googleclassroom.", "notifications.", "shortcuts.", "browser_"
    ]

    public static func isCompanionTool(_ name: String) -> Bool {
        companionPrefixes.contains { name.hasPrefix($0) }
    }

    /// Reads of the person's own data: the ones that ask before the content goes to the model.
    static func readsPersonalData(_ name: String) -> Bool {
        name.hasPrefix("gmail.read.") || name.hasPrefix("google") && name.contains(".read.")
    }

    /// What the agent is told about the layers, so it prefers the one that does not interrupt the person.
    public static let layersNote = """
    Para correo, agenda, tareas, Drive y contactos usa las herramientas de Google (gmail.*, googlecalendar.*, googletasks.*, googledrive.*...): \
    funcionan en segundo plano y no sacan al usuario de la app. Primero intenta esas.
    Usa el control del iPhone (iphone_*) solo para apps que no tienen una herramienta propia: la app tiene que pasar a primer plano \
    y iSyCode queda en segundo plano mientras actúas.
    shortcuts.run abre un instante la app Atajos. Leer datos personales pide confirmación al usuario.
    """

    // MARK: - ToolExecutor

    public var availableTools: [AgentTool] {
        let base = primary.availableTools
        return base + companions(from: secondary.availableTools, excluding: Set(base.map(\.name)))
    }

    public func tools(relevantTo messages: [ModelMessage]) async -> [AgentTool] {
        let base = await primary.tools(relevantTo: messages)
        let taken = Set(base.map(\.name)).union(primary.availableTools.map(\.name))
        return base + companions(from: await secondary.tools(relevantTo: messages), excluding: taken)
    }

    public func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
        await execute(invocation, approval: nil)
    }

    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        if goesToSecondary(invocation.name) {
            return await secondary.execute(invocation, approval: approval)
        }
        return await primary.execute(invocation, approval: approval)
    }

    public func sharedContextForPrompt() async -> String? {
        await primary.sharedContextForPrompt()
    }

    public func promptContext(for messages: [ModelMessage]) async -> String? {
        await primary.promptContext(for: messages)
    }

    // MARK: - Helpers

    private func goesToSecondary(_ name: String) -> Bool {
        allows(name) && !primary.availableTools.contains { $0.name == name }
    }

    private func companions(from tools: [AgentTool], excluding taken: Set<String>) -> [AgentTool] {
        var seen = taken
        var result: [AgentTool] = []
        for tool in tools where allows(tool.name) && !seen.contains(tool.name) {
            seen.insert(tool.name)
            result.append(consentForReads && Self.readsPersonalData(tool.name) ? askingBeforeReading(tool) : tool)
        }
        return result
    }

    private func askingBeforeReading(_ tool: AgentTool) -> AgentTool {
        var capabilities = tool.capabilities
        guard !capabilities.isDestructive else { return tool }
        capabilities.isDestructive = true
        capabilities.approvalReason = "El asistente quiere leer datos tuyos (\(tool.name)). Lo que lea se enviará al modelo que elegiste. Puedes aprobar solo esta vez o siempre."
        return AgentTool(
            name: tool.name,
            description: tool.description,
            properties: tool.parameters.properties,
            required: tool.parameters.required,
            capabilities: capabilities
        )
    }
}

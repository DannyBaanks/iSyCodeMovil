import Foundation
import SwiftUI

public enum BackendMode: String, Sendable {
    case unconfigured
    case native
    case remote
}

public enum BackendPairing: Sendable {
    case openCode(OpenCodePairing)
    case codex(CodexPairing)
    case grok(GrokPairing)
    case remote(RemotePairing)
}

public struct WorkbenchFileNode: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date
    public let status: String?
    
    public init(id: String = UUID().uuidString, name: String, path: String, isDirectory: Bool, size: Int64 = 0, modifiedAt: Date = Date(), status: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.status = status
    }
}

public struct WorkbenchFileContent: Sendable {
    public let path: String
    public let content: String
    public let mimeType: String?
    public let encoding: String?
}

public struct SessionDiffFile: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let before: String?
    public let after: String?
    
    public init(id: String = UUID().uuidString, path: String, additions: Int, deletions: Int, before: String? = nil, after: String? = nil) {
        self.id = id
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.before = before
        self.after = after
    }
}






public enum WorkbenchEvent: Sendable {
    case connected
    case disconnected(String?)
    case partUpdated(partID: String, kind: String, text: String?, tool: String?, callID: String?, status: String?, input: [String: String], output: String?, error: String?)
    case partDelta(partID: String, delta: String)
    case permissionAsked(requestID: String, sessionID: String, tool: String, command: String, explanation: String)
    case sessionIdle(sessionID: String)
    case sessionError(String)
    case sessionsChanged
    case filesChanged
    case agentModeChanged(AgentMode)
    case modelChanged(ModelInfo?)
    case auxiliaryModelStatus(GUSDualModelStatus)
}

public protocol WorkbenchBackend: Sendable {
    var mode: BackendMode { get }
    var usesLiveModel: Bool { get }
    var connectionStatus: String { get async }
    var currentSessionID: String? { get async }
    var eventStream: AsyncStream<WorkbenchEvent> { get }
    
    func connectRemote(pairing: BackendPairing) async throws
    func disconnect() async
    func useNativeRuntime() async throws
    
    func listProjects() async throws -> [Project]
    func listSessions(projectID: String) async throws -> [Session]
    func createSession(projectID: String, title: String) async throws -> Session
    func renameSession(sessionID: String, title: String) async throws
    func deleteSession(sessionID: String) async throws
    func selectSession(_ sessionID: String) async throws
    
    func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws
    func abort() async throws
    
    func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws
    
    func loadHistory(sessionID: String) async throws -> [TimelineEvent]
    func startEventStream() async throws
    func stopEventStream() async
    
    func listFiles(path: String) async throws -> [WorkbenchFileNode]
    func fileContent(path: String) async throws -> WorkbenchFileContent
    func sessionDiff(sessionID: String) async throws -> [SessionDiffFile]
    func runShell(command: String, agent: String?) async throws -> ShellResult
    
    func availableProviders() async throws -> ProviderListResult
    func config() async throws -> ConfigInfo
    func availableCommands() async throws -> [CommandInfo]
    
    func sendWorkbenchEvent(_ event: WorkbenchEvent)
}

public extension WorkbenchBackend {
    var usesLiveModel: Bool { false }
}

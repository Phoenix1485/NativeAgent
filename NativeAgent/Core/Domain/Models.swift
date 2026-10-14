import Foundation

struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var canonicalPath: String
    var createdAt: Date
    var lastOpenedAt: Date

    init(id: UUID = UUID(), name: String, canonicalPath: String, createdAt: Date = .now, lastOpenedAt: Date = .now) {
        self.id = id
        self.name = name
        self.canonicalPath = canonicalPath
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var projectID: UUID?
    var groupID: UUID?
    var remoteThreadID: String?
    var providerID: ProviderKind = .codex
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var archiveExpiresAt: Date? { archivedAt?.addingTimeInterval(30 * 24 * 60 * 60) }

    init(id: UUID = UUID(), projectID: UUID? = nil, groupID: UUID? = nil, remoteThreadID: String? = nil, title: String = "New chat", createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.projectID = projectID
        self.groupID = groupID
        self.remoteThreadID = remoteThreadID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChatGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var parentID: UUID?
    var projectID: UUID?
    var name: String
    var createdAt: Date = .now
}

enum TurnStatus: String, Codable, Sendable {
    case idle, starting, running, awaitingApproval, awaitingUserInput
    case interrupting, completed, interrupted, failed, stateUnknown

    var label: String {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting"
        case .running: "Working"
        case .awaitingApproval: "Approval needed"
        case .awaitingUserInput: "Input needed"
        case .interrupting: "Stopping"
        case .completed: "Completed"
        case .interrupted: "Stopped"
        case .failed: "Failed"
        case .stateUnknown: "Checking state"
        }
    }
}

enum TimelineKind: String, Codable, Sendable {
    case userMessage, agentMessage, command, fileChange, approval, question, error, notice, fact
}

struct TimelineEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var turnID: String?
    var kind: TimelineKind
    var title: String
    var text: String
    var detail: String?
    var createdAt: Date
    var isStreaming: Bool
    var receivedOrder: Int?
    var textIsPreview = false

    init(id: UUID = UUID(), turnID: String? = nil, kind: TimelineKind, title: String, text: String, detail: String? = nil, createdAt: Date = .now, isStreaming: Bool = false) {
        self.id = id
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}

enum ApprovalDecision: String, Codable, CaseIterable, Sendable {
    case accept, acceptForSession, decline, cancel

    var label: String {
        switch self {
        case .accept: "Allow once"
        case .acceptForSession: "Allow for session"
        case .decline: "Deny"
        case .cancel: "Cancel turn"
        }
    }
}

struct ApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let turnID: String?
    let method: String
    let title: String
    let command: String?
    let workingDirectory: String?
    let choices: [ApprovalDecision]
    var resolved: Bool = false
}

struct ProviderModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    var description: String?
    var isDefault: Bool = false
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String?
}

struct ProviderCapabilities: Codable, Equatable, Sendable {
    var subscriptionAuth = true
    var apiKeyAuth = false
    var structuredStreaming = true
    var resume = true
    var interrupt = true
    var nativeApprovals = true
    var fileChangeEvents = true
    var usageReporting = false
    var imageInput = false
    var modelDiscovery = true
    var terminalSession = false

    static var claudeTerminal: Self {
        .init(subscriptionAuth: true, apiKeyAuth: true, structuredStreaming: false, resume: false,
              interrupt: false, nativeApprovals: false, fileChangeEvents: false,
              usageReporting: false, imageInput: false, modelDiscovery: false, terminalSession: true)
    }
}

enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case ready(account: String?)
    case notAuthenticated
    case signingIn
    case missingInstallation
    case unsupportedVersion(String)
    case usageLimitReached
    case unavailable(String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .notAuthenticated: "Sign-in required"
        case .signingIn: "Signing in"
        case .missingInstallation: "Installation missing"
        case .unsupportedVersion: "Unsupported version"
        case .usageLimitReached: "Usage limit reached"
        case .unavailable: "Unavailable"
        case .failed: "Connection failed"
        }
    }
}

enum ProviderEvent: Sendable {
    case question(ProviderQuestionRequest)
    case questionResolved(String)
    case conversationFact(turnID: String?, fact: ConversationFact)
    case connected(account: String?)
    case authenticationRequired
    case authenticationFailed(String)
    case loginURL(String)
    case inspection(ProviderInspection)
    case accountDetails(ProviderAccount)
    case usage([ProviderUsageWindow])
    case usageLimitReached
    case connectionFailed(String)
    case approvalResolved(String)
    case models([ProviderModel])
    case threadCreated(String)
    case turnStarted(String)
    case agentDelta(turnID: String?, text: String)
    case agentMessage(turnID: String?, text: String)
    case command(turnID: String?, title: String, output: String, exitCode: Int?)
    case fileChange(turnID: String?, path: String, summary: String)
    case approval(ApprovalRequest)
    case turnCompleted(turnID: String?, status: TurnStatus, error: String?)
    case diagnostic(String)
}

struct ProviderQuestionRequest: Identifiable, Sendable {
    struct Question: Identifiable, Sendable {
        struct Option: Identifiable, Sendable { var id: String { label }; var label: String; var description: String }
        var id: String
        var header: String
        var text: String
        var secret: Bool
        var allowsOther: Bool
        var options: [Option]
    }
    var id: String
    var turnID: String?
    var questions: [Question]
}

enum NativeAgentError: LocalizedError, Equatable {
    case noProject
    case alreadyRunning
    case providerUnavailable(String)
    case protocolError(String)
    case frameTooLarge(limit: Int)
    case bufferOverflow(limit: Int)
    case invalidUTF8
    case requestTimedOut
    case processEnded(Int32)
    case unsupported(String)
    case unsupportedVersion(String)
    case missingInstallation(String)

    var errorDescription: String? {
        switch self {
        case .noProject: "Open a project first."
        case .alreadyRunning: "A turn is already running."
        case .providerUnavailable(let reason): reason
        case .protocolError(let reason): "Protocol error: \(reason)"
        case .frameTooLarge(let limit): "A provider message exceeded the \(limit)-byte limit."
        case .bufferOverflow(let limit): "The provider input buffer exceeded the \(limit)-byte limit."
        case .invalidUTF8: "The provider sent invalid UTF-8."
        case .requestTimedOut: "The provider did not respond in time."
        case .processEnded(let code): "The provider process ended with status \(code)."
        case .unsupported(let feature): "Not supported: \(feature)"
        case .unsupportedVersion(let message): message
        case .missingInstallation(let message): message
        }
    }
}

struct ProviderAccount: Equatable, Sendable {
    var email: String?
    var plan: String?
    var method: AuthenticationMethod
    var configuration: String?
}

struct ProviderUsageWindow: Equatable, Sendable, Identifiable {
    let id: String
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?
}

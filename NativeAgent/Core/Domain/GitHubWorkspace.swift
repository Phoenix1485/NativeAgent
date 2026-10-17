import Foundation

struct GitHubAuthState: Equatable, Sendable {
    var executablePath: String?
    var login: String?
    var usesKeychain = false
    var message = "Connect GitHub to browse and publish repositories."
    var isInstalled: Bool { executablePath != nil }
    var isAuthenticated: Bool { login != nil }
}

struct GitHubRepository: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let url: String
    let cloneURL: String
    let defaultBranch: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case fullName = "full_name", isPrivate = "private", url = "html_url"
        case cloneURL = "clone_url", defaultBranch = "default_branch"
    }
}

struct GitBranch: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
    let upstream: String?
    let sha: String
}

struct GitCommit: Identifiable, Hashable, Sendable {
    var id: String { sha }
    let sha: String
    let subject: String
    let author: String
    let date: String
    var shortSHA: String { String(sha.prefix(8)) }
}

struct GitDesktopSnapshot: Sendable {
    let root: String
    var branch: String
    var changes: [GitFileChange]
    var ahead: Int
    var behind: Int
    var upstream: String?
    var remoteURL: String?
    var repository: String?
    var headSHA: String?
    var isRepository = true
    var mergeInProgress = false
}

struct GitOperationExpectation: Equatable, Sendable {
    let root: String
    let branch: String
    let headSHA: String?
    let upstream: String?
    let remoteURL: String?

    init(_ snapshot: GitDesktopSnapshot) {
        root = snapshot.root
        branch = snapshot.branch
        headSHA = snapshot.headSHA
        upstream = snapshot.upstream
        remoteURL = snapshot.remoteURL
    }
}

enum GitComparison: Hashable, Sendable {
    case working(path: String? = nil)
    case staged(path: String? = nil)
    case upstream
    case branches(base: String, head: String)
    case commit(String)
}

struct GitHubPullRequest: Identifiable, Codable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let baseRefName: String
    let headRefOid: String
    let isDraft: Bool
    let mergeStateStatus: String
    let state: String
}

enum GitHubOperationError: LocalizedError {
    case unavailable(String)
    case invalid(String)
    case failed(String)
    case timedOut
    case outputLimit

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalid(let message), .failed(let message): return message
        case .timedOut: return "The command timed out. Refresh the repository before retrying."
        case .outputLimit: return "The command produced too much output. Select a smaller comparison."
        }
    }
}

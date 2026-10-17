import Foundation

enum ChatStorageSort: String, CaseIterable, Identifiable, Sendable {
    case largest, smallest, oldest, newest
    var id: String { rawValue }
    var title: String {
        switch self { case .largest: "Largest first"; case .smallest: "Smallest first"; case .oldest: "Oldest first"; case .newest: "Newest first" }
    }
}

enum ChatStorageScope: String, CaseIterable, Identifiable, Sendable {
    case all, active, archived
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ChatStorageQuery: Hashable, Sendable {
    var search = ""
    var sort: ChatStorageSort = .largest
    var scope: ChatStorageScope = .all
}

struct ChatStorageEntry: Identifiable, Sendable {
    var conversation: Conversation
    var storedBytes: Int64
    var deletionDate: Date?
    var id: UUID { conversation.id }
}

struct LibraryStorageSummary: Sendable {
    var chatBytes: Int64 = 0
    /// Encoded attachment text/media payload bytes already included in chatBytes.
    var attachmentPayloadBytes: Int64 = 0
    var chatCount = 0
    var archivedCount = 0
}

enum LibraryStorageFileKind: String, Sendable { case backup, cache }

struct LibraryStorageFile: Identifiable, Hashable, Sendable {
    var url: URL
    var kind: LibraryStorageFileKind
    var bytes: Int64
    var modifiedAt: Date
    var identity: String
    var id: String { url.path }
}

struct LibraryDiskStorage: Sendable {
    var databaseBytes: Int64 = 0
    var backupBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var files: [LibraryStorageFile] = []
    var isPartial = false
}

struct MessageBookmark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { messageID }
    let messageID: UUID
    let conversationID: UUID
    var label: String
    var preview: String
    var createdAt: Date = .now
}

struct MessageBookmarkEntry: Identifiable, Sendable {
    var bookmark: MessageBookmark
    var conversationTitle: String
    var archived: Bool
    var messageExists: Bool
    var id: UUID { bookmark.id }
}

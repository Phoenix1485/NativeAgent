import Foundation

struct ArchiveQuery: Hashable, Sendable {
    var search: String = ""
    var archivedFrom: Date?
    /// Exclusive upper bound, so a calendar date range can include its entire last day.
    var archivedBefore: Date?
}

struct ArchivedConversation: Identifiable, Sendable {
    var conversation: Conversation
    /// UTF-8 bytes stored in chat content and attachment metadata, excluding database overhead.
    var storedBytes: Int64
    var id: UUID { conversation.id }
}

enum ArchiveRetention {
    static let standardDays = 30
    static let largeChatDays = 20
    static let archiveCountThreshold = 30
    static let largeChatBytes: Int64 = 10 * 1_024 * 1_024

    static func deletionDate(archivedAt: Date, storedBytes: Int64, archiveCount: Int) -> Date {
        let days = storedBytes >= largeChatBytes && archiveCount > archiveCountThreshold ? largeChatDays : standardDays
        return archivedAt.addingTimeInterval(TimeInterval(days * 86_400))
    }
}

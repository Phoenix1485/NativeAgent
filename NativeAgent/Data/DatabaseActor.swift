import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor DatabaseActor {
    private var database: OpaquePointer?
    private var initialized = false
    private let url: URL
    let startupRestoreNotice: String?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try LibrarySnapshots.applyPending(to: url); startupRestoreNotice = nil }
        catch { startupRestoreNotice = "Restore could not finish: \(error.localizedDescription). Your backup is retained. Check Settings → Configuration." }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NativeAgentError.providerUnavailable("Could not open the local database.")
        }
    }

    deinit { sqlite3_close(database) }

    func backupLibrary(daily: Bool = false) throws -> [URL] {
        try ensureInitialized()
        if daily { try LibrarySnapshots.daily(for: url) }
        else { _ = try LibrarySnapshots.create(for: url, prefix: "manual") }
        return try LibrarySnapshots.list(for: url)
    }
    func libraryBackups() throws -> [URL] { try LibrarySnapshots.list(for: url) }
    func stageLibraryRestore(from source: URL) throws { try LibrarySnapshots.stage(source: source, database: url) }

    // MARK: Storage management and saved message bookmarks

    func libraryStorageURL() -> URL { url }

    func libraryStorageSummary() async throws -> LibraryStorageSummary {
        try ensureInitialized()
        var summary = try query("SELECT COALESCE(SUM(stored_bytes),0),COUNT(*),COALESCE(SUM(archived_at IS NOT NULL),0) FROM conversations") {
            LibraryStorageSummary(chatBytes: Int64($0.int(0)), chatCount: $0.int(1), archivedCount: $0.int(2))
        }.first ?? LibraryStorageSummary()
        // Bound each JSON scan and yield between batches so large attachments cannot monopolize
        // the database actor while a task is saving messages. No media is decoded into Swift.
        var cursor = ""
        while true {
            try Task.checkCancellation()
            let page = try query("""
            SELECT f.id,COALESCE(SUM(CASE WHEN json_extract(j.value,'$.kind') IN ('attachment','code','fileReference')
                THEN COALESCE(length(CAST(json_extract(j.value,'$.text') AS BLOB)),0)
                  + COALESCE(length(CAST(json_extract(j.value,'$.mediaData') AS BLOB)),0) ELSE 0 END),0)
            FROM (SELECT id,payload FROM feature_records WHERE kind='context' AND conversation_id IS NOT NULL AND id>?
                  ORDER BY id LIMIT 20) f
            LEFT JOIN json_each(CASE WHEN json_valid(f.payload) THEN f.payload ELSE '[]' END) j
            GROUP BY f.id ORDER BY f.id
            """, [.text(cursor)]) { ($0.text(0), Int64($0.int(1))) }
            summary.attachmentPayloadBytes += page.reduce(0) { $0 + $1.1 }
            guard page.count == 20, let last = page.last else { break }
            cursor = last.0
            await Task.yield()
        }
        return summary
    }

    func chatStoragePage(query request: ChatStorageQuery = .init(), after: ChatStorageEntry? = nil, limit: Int = 50) throws -> [ChatStorageEntry] {
        try ensureInitialized()
        let field = [.largest, .smallest].contains(request.sort) ? "stored_bytes" : "updated_at"
        let ascending = [.smallest, .oldest].contains(request.sort)
        let comparison = ascending ? ">" : "<"
        let direction = ascending ? "ASC" : "DESC"
        var sql = "SELECT id,project_id,group_id,remote_thread_id,title,created_at,updated_at,provider_id,archived_at,stored_bytes FROM conversations WHERE 1=1"
        var bindings: [Binding] = []
        if request.scope == .active { sql += " AND archived_at IS NULL" }
        if request.scope == .archived { sql += " AND archived_at IS NOT NULL" }
        if !request.search.isEmpty {
            sql += " AND instr(lower(title),lower(?))>0"
            bindings.append(.text(request.search))
        }
        if let after {
            let cursor: Binding = field == "stored_bytes" ? .int(Int(after.storedBytes)) : .double(after.conversation.updatedAt.timeIntervalSince1970)
            sql += " AND (\(field) \(comparison) ? OR (\(field)=? AND id \(comparison) ?))"
            bindings += [cursor, cursor, .text(after.id.uuidString)]
        }
        sql += " ORDER BY \(field) \(direction),id \(direction) LIMIT ?"
        bindings.append(.int(max(1, min(100, limit))))
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(ArchiveRetention.standardDays * 86_400)).timeIntervalSince1970
        let archivedCount = try query("SELECT COUNT(*) FROM conversations WHERE archived_at > ?", [.double(cutoff)]) { $0.int(0) }.first ?? 0
        return try query(sql, bindings) { row in
            let chat = self.storageConversation(row)
            let bytes = Int64(row.int(9))
            let date = chat.archivedAt.map { ArchiveRetention.deletionDate(archivedAt: $0, storedBytes: bytes, archiveCount: archivedCount) }
            return ChatStorageEntry(conversation: chat, storedBytes: bytes, deletionDate: date)
        }
    }

    func upcomingArchiveDeletions(limit: Int = 20) throws -> [ChatStorageEntry] {
        try ensureInitialized()
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(ArchiveRetention.standardDays * 86_400)).timeIntervalSince1970
        let count = try query("SELECT COUNT(*) FROM conversations WHERE archived_at > ?", [.double(cutoff)]) { $0.int(0) }.first ?? 0
        let sql = """
        SELECT id,project_id,group_id,remote_thread_id,title,created_at,updated_at,provider_id,archived_at,stored_bytes
        FROM conversations WHERE archived_at IS NOT NULL
        ORDER BY archived_at + CASE WHEN stored_bytes >= ? AND ? > ? THEN ? ELSE ? END,id LIMIT ?
        """
        let bindings: [Binding] = [.int(Int(ArchiveRetention.largeChatBytes)), .int(count), .int(ArchiveRetention.archiveCountThreshold),
                                   .int(ArchiveRetention.largeChatDays * 86_400), .int(ArchiveRetention.standardDays * 86_400), .int(max(1, min(50, limit)))]
        return try query(sql, bindings) { row in
            let chat = self.storageConversation(row), bytes = Int64(row.int(9))
            return ChatStorageEntry(conversation: chat, storedBytes: bytes,
                                    deletionDate: chat.archivedAt.map { ArchiveRetention.deletionDate(archivedAt: $0, storedBytes: bytes, archiveCount: count) })
        }
    }

    private func storageConversation(_ row: Row) -> Conversation {
        var chat = Conversation(id: UUID(uuidString: row.text(0))!, projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)),
                                groupID: row.optionalText(2).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(3), title: row.text(4),
                                createdAt: Date(timeIntervalSince1970: row.double(5)), updatedAt: Date(timeIntervalSince1970: row.double(6)))
        chat.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
        chat.archivedAt = row.optionalText(8).map { _ in Date(timeIntervalSince1970: row.double(8)) }
        return chat
    }

    func saveMessageBookmark(conversationID: UUID, messageID: UUID, label: String) throws -> MessageBookmark {
        try ensureInitialized()
        guard let preview = try query("SELECT substr(display_text,1,300) FROM timeline_items WHERE id=? AND conversation_id=? AND is_streaming=0",
                                      [.text(messageID.uuidString), .text(conversationID.uuidString)], map: { $0.text(0) }).first else {
            throw NativeAgentError.unsupported("This message is unavailable or still being written.")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { throw NativeAgentError.unsupported("Use a bookmark label between 1 and 160 characters.") }
        let previous = try feature(MessageBookmark.self, kind: "message-bookmark", id: messageID.uuidString)
        let bookmark = MessageBookmark(messageID: messageID, conversationID: conversationID, label: trimmed, preview: preview, createdAt: previous?.createdAt ?? .now)
        try saveFeature(bookmark, kind: "message-bookmark", id: messageID.uuidString, title: trimmed, searchText: preview, conversationID: conversationID)
        return bookmark
    }

    func messageBookmarkPage(search: String = "", after: MessageBookmark? = nil, limit: Int = 50) throws -> [MessageBookmarkEntry] {
        try ensureInitialized()
        var sql = """
        SELECT f.payload,c.title,c.archived_at,t.id FROM feature_records f
        JOIN conversations c ON c.id=f.conversation_id
        LEFT JOIN timeline_items t ON t.id=f.id AND t.conversation_id=f.conversation_id
        WHERE f.kind='message-bookmark'
        """
        var bindings: [Binding] = []
        if !search.isEmpty {
            sql += " AND instr(lower(f.title || ' ' || f.search_text || ' ' || c.title),lower(?))>0"
            bindings.append(.text(search))
        }
        if let after {
            sql += " AND (json_extract(f.payload,'$.createdAt') < ? OR (json_extract(f.payload,'$.createdAt')=? AND f.id < ?))"
            bindings += [.double(after.createdAt.timeIntervalSinceReferenceDate), .double(after.createdAt.timeIntervalSinceReferenceDate), .text(after.id.uuidString)]
        }
        sql += " ORDER BY json_extract(f.payload,'$.createdAt') DESC,f.id DESC LIMIT ?"
        bindings.append(.int(max(1, min(100, limit))))
        return try query(sql, bindings) { row in
            MessageBookmarkEntry(bookmark: try JSONDecoder().decode(MessageBookmark.self, from: Data(row.text(0).utf8)),
                                 conversationTitle: row.text(1), archived: row.optionalText(2) != nil, messageExists: row.optionalText(3) != nil)
        }
    }

    func bookmarkedConversation(messageID: UUID, conversationID: UUID) throws -> Conversation? {
        try ensureInitialized()
        guard try query("SELECT 1 FROM timeline_items WHERE id=? AND conversation_id=?", [.text(messageID.uuidString), .text(conversationID.uuidString)], map: { $0.int(0) }).first != nil else { return nil }
        return try conversation(id: conversationID)
    }

    func conversationMarkdown(_ chat: Conversation) throws -> String {
        try ensureInitialized()
        var result = "# \(chat.title)\n\nExported from NativeAgent. User and assistant messages only.\n\n"
        let rows = try query("SELECT kind,display_text,created_at FROM timeline_items WHERE conversation_id=? AND kind IN ('userMessage','agentMessage') ORDER BY received_order", [.text(chat.id.uuidString)]) {
            ($0.text(0), $0.text(1), Date(timeIntervalSince1970: $0.double(2)))
        }
        for (kind, text, date) in rows { result += "## \(kind == "userMessage" ? "You" : "Assistant") · \(date.ISO8601Format())\n\n\(text)\n\n" }
        return result
    }

    func chatAttention() throws -> [UUID: ChatAttention] {
        try ensureInitialized()
        let rows = try query("SELECT f.id,f.payload FROM feature_records f JOIN conversations c ON c.id=f.conversation_id WHERE f.kind='chat-attention' AND c.archived_at IS NULL") {
            (UUID(uuidString: $0.text(0)), try JSONDecoder().decode(ChatAttention.self, from: Data($0.text(1).utf8)))
        }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { id, value in id.map { ($0, value) } })
    }

    func setChatAttention(_ id: UUID, pinned: Bool? = nil, unread: Bool? = nil) throws {
        guard let chat = try conversation(id: id), chat.archivedAt == nil else { return }
        var state = try feature(ChatAttention.self, kind: "chat-attention", id: id.uuidString) ?? ChatAttention()
        if let pinned {
            if pinned && !state.pinned {
                if try chatAttention().values.filter(\.pinned).count >= 50 { throw NativeAgentError.unsupported("You can pin up to 50 chats. Unpin one first.") }
            }
            state.pinned = pinned
        }
        if let unread { state.unread = unread }
        if state == ChatAttention() { try removeFeature(kind: "chat-attention", id: id.uuidString) }
        else { try saveFeature(state, kind: "chat-attention", id: id.uuidString, conversationID: id) }
    }

    func pinnedConversations() throws -> [Conversation] {
        let states = try chatAttention()
        return try states.filter { $0.value.pinned }.keys.compactMap { try conversation(id: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(project: Project) throws {
        try ensureInitialized()
        try execute(
            "INSERT INTO projects(id,name,canonical_path,created_at,last_opened_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, canonical_path=excluded.canonical_path, last_opened_at=excluded.last_opened_at",
            [.text(project.id.uuidString), .text(project.name), .text(project.canonicalPath), .double(project.createdAt.timeIntervalSince1970), .double(project.lastOpenedAt.timeIntervalSince1970)]
        )
    }

    func projects() throws -> [Project] {
        try ensureInitialized()
        return try query("SELECT id,name,canonical_path,created_at,last_opened_at FROM projects ORDER BY last_opened_at DESC") { row in
            Project(id: UUID(uuidString: row.text(0)) ?? UUID(), name: row.text(1), canonicalPath: row.text(2), createdAt: Date(timeIntervalSince1970: row.double(3)), lastOpenedAt: Date(timeIntervalSince1970: row.double(4)))
        }
    }

    func removeProject(id: UUID) throws { try ensureInitialized(); try execute("DELETE FROM projects WHERE id=?", [.text(id.uuidString)]) }

    func save(conversation: Conversation) throws {
        try ensureInitialized()
        try execute(
            "INSERT INTO conversations(id,project_id,remote_thread_id,title,created_at,updated_at,group_id,provider_id) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,group_id=excluded.group_id,remote_thread_id=excluded.remote_thread_id,title=excluded.title,updated_at=excluded.updated_at,provider_id=excluded.provider_id",
            [.text(conversation.id.uuidString), conversation.projectID.map { .text($0.uuidString) } ?? .null, conversation.remoteThreadID.map(Binding.text) ?? .null, .text(conversation.title), .double(conversation.createdAt.timeIntervalSince1970), .double(conversation.updatedAt.timeIntervalSince1970), conversation.groupID.map { .text($0.uuidString) } ?? .null, .text(conversation.providerID.rawValue)]
        )
    }

    func conversations(projectID: UUID? = nil) throws -> [Conversation] {
        try ensureInitialized()
        let filter = projectID == nil ? " WHERE archived_at IS NULL" : " WHERE archived_at IS NULL AND project_id=?"
        return try query("SELECT id,project_id,remote_thread_id,title,created_at,updated_at,group_id,provider_id FROM conversations" + filter + " ORDER BY updated_at DESC,id DESC", projectID.map { [.text($0.uuidString)] } ?? []) { row in
            var conversation = Conversation(id: UUID(uuidString: row.text(0)) ?? UUID(), projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)), groupID: row.optionalText(6).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(2), title: row.text(3), createdAt: Date(timeIntervalSince1970: row.double(4)), updatedAt: Date(timeIntervalSince1970: row.double(5)))
            conversation.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
            return conversation
        }
    }

    /// Search the whole library, not only sidebar pages already loaded in memory.
    /// Drafts and folder choices are retained when this unsent chat is reused.
    func unsentConversation(preferredID: UUID?, excluding: Set<UUID> = []) throws -> Conversation? {
        try ensureInitialized()
        var sql = """
        SELECT c.id,c.project_id,c.remote_thread_id,c.title,c.created_at,c.updated_at,c.group_id,c.provider_id
        FROM conversations c WHERE c.archived_at IS NULL AND c.remote_thread_id IS NULL
        AND NOT EXISTS (SELECT 1 FROM timeline_items t WHERE t.conversation_id=c.id)
        AND NOT EXISTS (SELECT 1 FROM turns t WHERE t.conversation_id=c.id)
        """
        var bindings: [Binding] = []
        if !excluding.isEmpty {
            sql += " AND c.id NOT IN (" + excluding.map { _ in "?" }.joined(separator: ",") + ")"
            bindings += excluding.map { .text($0.uuidString) }
        }
        sql += " ORDER BY (c.id=?) DESC,c.updated_at DESC,c.id DESC LIMIT 1"
        bindings.append(.text(preferredID?.uuidString ?? ""))
        return try query(sql, bindings) { row in
            var chat = Conversation(id: UUID(uuidString: row.text(0))!, projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)),
                groupID: row.optionalText(6).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(2), title: row.text(3),
                createdAt: Date(timeIntervalSince1970: row.double(4)), updatedAt: Date(timeIntervalSince1970: row.double(5)))
            chat.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
            return chat
        }.first
    }

    /// Keyset pagination avoids increasingly expensive OFFSET scans as the library grows.
    func conversationPage(groupID: UUID? = nil, search: String? = nil, archived: Bool = false, after: Conversation? = nil, limit: Int = 50, now: Date = .now) throws -> [Conversation] {
        try ensureInitialized()
        var sql = "SELECT id,project_id,remote_thread_id,title,created_at,updated_at,group_id,provider_id,archived_at FROM conversations WHERE "
        var bindings: [Binding] = []
        if archived {
            // Keep legacy callers on the same retention policy as the archive browser.
            let retention = retainedArchivePredicate(now: now, alias: "conversations")
            sql += retention.sql
            bindings += retention.bindings
        } else { sql += "archived_at IS NULL" }
        if let search {
            // Treat wildcard characters literally; search all folders, not just loaded rows.
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sql += " AND title LIKE ? ESCAPE '\\'"
            bindings.append(.text("%" + escaped + "%"))
        } else if !archived {
            sql += groupID == nil ? " AND group_id IS NULL" : " AND group_id=?"
            if let groupID { bindings.append(.text(groupID.uuidString)) }
        }
        if let after {
            sql += " AND (updated_at < ? OR (updated_at = ? AND id < ?))"
            bindings += [.double(after.updatedAt.timeIntervalSince1970), .double(after.updatedAt.timeIntervalSince1970), .text(after.id.uuidString)]
        }
        sql += " ORDER BY updated_at DESC,id DESC LIMIT ?"
        bindings.append(.int(max(1, min(limit, 200))))
        return try query(sql, bindings) { row in
            var chat = Conversation(id: UUID(uuidString: row.text(0))!, projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)), groupID: row.optionalText(6).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(2), title: row.text(3), createdAt: Date(timeIntervalSince1970: row.double(4)), updatedAt: Date(timeIntervalSince1970: row.double(5)))
            chat.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
            chat.archivedAt = row.optionalText(8) == nil ? nil : Date(timeIntervalSince1970: row.double(8))
            return chat
        }
    }

    func archiveConversation(id: UUID, now: Date = .now) throws {
        try ensureInitialized()
        // Repeated clicks must not extend the retention period.
        try execute("UPDATE conversations SET archived_at=? WHERE id=? AND archived_at IS NULL", [.double(now.timeIntervalSince1970), .text(id.uuidString)])
    }

    /// Search and date filters apply to the whole archive, with stable archive-date keyset paging.
    func archivePage(query archiveQuery: ArchiveQuery = .init(), after: Conversation? = nil, limit: Int = 50, now: Date = .now) throws -> [ArchivedConversation] {
        try ensureInitialized()
        let retention = retainedArchivePredicate(now: now, alias: "c")
        var sql = "SELECT c.id,c.project_id,c.remote_thread_id,c.title,c.created_at,c.updated_at,c.group_id,c.provider_id,c.archived_at,c.stored_bytes FROM conversations c WHERE " + retention.sql
        var bindings = retention.bindings
        let search = archiveQuery.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sql += " AND c.title LIKE ? ESCAPE '\\'"
            bindings.append(.text("%" + escaped + "%"))
        }
        if let from = archiveQuery.archivedFrom {
            sql += " AND c.archived_at >= ?"
            bindings.append(.double(from.timeIntervalSince1970))
        }
        if let before = archiveQuery.archivedBefore {
            sql += " AND c.archived_at < ?"
            bindings.append(.double(before.timeIntervalSince1970))
        }
        if let after, let archivedAt = after.archivedAt {
            sql += " AND (c.archived_at < ? OR (c.archived_at = ? AND c.id < ?))"
            bindings += [.double(archivedAt.timeIntervalSince1970), .double(archivedAt.timeIntervalSince1970), .text(after.id.uuidString)]
        }
        sql += " ORDER BY c.archived_at DESC,c.id DESC LIMIT ?"
        bindings.append(.int(max(1, min(limit, 200))))
        return try query(sql, bindings) { row in
            var chat = Conversation(id: UUID(uuidString: row.text(0))!, projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)), groupID: row.optionalText(6).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(2), title: row.text(3), createdAt: Date(timeIntervalSince1970: row.double(4)), updatedAt: Date(timeIntervalSince1970: row.double(5)))
            chat.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
            chat.archivedAt = Date(timeIntervalSince1970: row.double(8))
            return ArchivedConversation(conversation: chat, storedBytes: Int64(row.int(9)))
        }
    }

    func archivedConversationCount(now: Date = .now) throws -> Int {
        try ensureInitialized()
        let retention = retainedArchivePredicate(now: now, alias: "c")
        return try query("SELECT COUNT(*) FROM conversations c WHERE " + retention.sql, retention.bindings) { $0.int(0) }.first ?? 0
    }

    /// Identical eligibility for listings and restores, even before scheduled maintenance runs.
    /// Only the oldest excess large chats expire early; the archive never shrinks below 30 for size alone.
    private func retainedArchivePredicate(now: Date, alias: String) -> (sql: String, bindings: [Binding]) {
        let standardCutoff = now.addingTimeInterval(-TimeInterval(ArchiveRetention.standardDays * 86_400)).timeIntervalSince1970
        let largeCutoff = now.addingTimeInterval(-TimeInterval(ArchiveRetention.largeChatDays * 86_400)).timeIntervalSince1970
        let sql = """
        \(alias).archived_at > ? AND \(alias).id NOT IN (
            SELECT aged.id FROM conversations aged
            WHERE aged.archived_at > ? AND aged.archived_at <= ? AND aged.stored_bytes >= ?
            ORDER BY aged.archived_at ASC,aged.id ASC
            LIMIT (SELECT MAX(COUNT(*) - ?,0) FROM conversations WHERE archived_at > ?)
        )
        """
        return (sql, [.double(standardCutoff), .double(standardCutoff), .double(largeCutoff), .int(Int(ArchiveRetention.largeChatBytes)), .int(ArchiveRetention.archiveCountThreshold), .double(standardCutoff)])
    }

    func restoreConversation(id: UUID, now: Date = .now) throws -> Bool {
        try ensureInitialized()
        let retention = retainedArchivePredicate(now: now, alias: "conversations")
        try execute("UPDATE conversations SET archived_at=NULL WHERE id=? AND " + retention.sql, [.text(id.uuidString)] + retention.bindings)
        return sqlite3_changes(database) > 0
    }

    /// Permanent deletion is scoped to an archived chat and its local dependent records.
    @discardableResult
    func deleteArchivedConversation(id: UUID) throws -> Bool {
        try ensureInitialized()
        try execute("BEGIN IMMEDIATE")
        do {
            let archived = try query("SELECT 1 FROM conversations WHERE id=? AND archived_at IS NOT NULL", [.text(id.uuidString)]) { $0.int(0) }.first != nil
            if archived { try deleteConversationRecords(id: id) }
            try execute("COMMIT")
            return archived
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func deleteConversationRecords(id: UUID) throws {
        let binding: [Binding] = [.text(id.uuidString)]
        try execute("DELETE FROM context_references WHERE timeline_item_id IN (SELECT id FROM timeline_items WHERE conversation_id=?)", binding)
        try execute("DELETE FROM approval_records WHERE turn_id IN (SELECT id FROM turns WHERE conversation_id=?)", binding)
        try execute("DELETE FROM attachments WHERE conversation_id=?", binding)
        // Foreign keys cascade timeline, turns, drafts and conversation-scoped feature records.
        try execute("DELETE FROM conversations WHERE id=?", binding)
    }

    /// Small transactions keep maintenance from monopolizing the database actor.
    /// Freed SQLite pages are reused; avoid a blocking whole-library VACUUM on every cleanup.
    @discardableResult
    func purgeExpiredArchive(now: Date = .now, limit: Int = 100) throws -> [UUID] {
        try ensureInitialized()
        let batchLimit = max(1, min(limit, 200))
        let standardCutoff = now.addingTimeInterval(-TimeInterval(ArchiveRetention.standardDays * 86_400)).timeIntervalSince1970
        let largeCutoff = now.addingTimeInterval(-TimeInterval(ArchiveRetention.largeChatDays * 86_400)).timeIntervalSince1970
        try execute("BEGIN IMMEDIATE")
        do {
            var ids = try query("SELECT id FROM conversations WHERE archived_at <= ? ORDER BY archived_at ASC,id ASC LIMIT ?", [.double(standardCutoff), .int(batchLimit)]) { UUID(uuidString: $0.text(0))! }
            if ids.count < batchLimit {
                let liveCount = try query("SELECT COUNT(*) FROM conversations WHERE archived_at > ?", [.double(standardCutoff)]) { $0.int(0) }.first ?? 0
                let excess = min(batchLimit - ids.count, max(0, liveCount - ArchiveRetention.archiveCountThreshold))
                if excess > 0 {
                    ids += try query("SELECT id FROM conversations WHERE archived_at > ? AND archived_at <= ? AND stored_bytes >= ? ORDER BY archived_at ASC,id ASC LIMIT ?", [.double(standardCutoff), .double(largeCutoff), .int(Int(ArchiveRetention.largeChatBytes)), .int(excess)]) { UUID(uuidString: $0.text(0))! }
                }
            }
            for id in ids { try deleteConversationRecords(id: id) }
            try execute("COMMIT")
            return ids
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func groups() throws -> [ChatGroup] {
        try ensureInitialized()
        return try query("SELECT id,parent_id,project_id,name,created_at FROM chat_groups ORDER BY created_at,name") { row in
            ChatGroup(id: UUID(uuidString: row.text(0))!, parentID: row.optionalText(1).flatMap(UUID.init(uuidString:)), projectID: row.optionalText(2).flatMap(UUID.init(uuidString:)), name: row.text(3), createdAt: Date(timeIntervalSince1970: row.double(4)))
        }
    }

    func save(group: ChatGroup) throws {
        try ensureInitialized()
        let all = try groups()
        var parentID = group.parentID
        var visited: Set<UUID> = [group.id]
        while let id = parentID {
            guard visited.insert(id).inserted, let parent = all.first(where: { $0.id == id }) else {
                throw NativeAgentError.unsupported("A folder cannot be placed inside itself or a missing folder.")
            }
            parentID = parent.parentID
        }
        guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeAgentError.unsupported("Enter a folder name.")
        }
        try execute("INSERT INTO chat_groups(id,parent_id,project_id,name,created_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent_id=excluded.parent_id,project_id=excluded.project_id,name=excluded.name", [.text(group.id.uuidString), group.parentID.map { .text($0.uuidString) } ?? .null, group.projectID.map { .text($0.uuidString) } ?? .null, .text(group.name), .double(group.createdAt.timeIntervalSince1970)])
    }

    func removeEmptyGroup(id: UUID) throws {
        try ensureInitialized()
        try execute("BEGIN IMMEDIATE")
        do {
            let occupied = try query("""
            SELECT EXISTS(SELECT 1 FROM chat_groups WHERE parent_id=?)
                OR EXISTS(SELECT 1 FROM conversations WHERE group_id=? AND archived_at IS NULL)
            """, [.text(id.uuidString), .text(id.uuidString)]) { $0.int(0) }.first ?? 0
            guard occupied == 0 else { throw NativeAgentError.unsupported("Move the chats and folders out of this group before removing it.") }
            // Archived chats are hidden from the sidebar. Keep their history and retention
            // dates; detach even expired rows that have not reached scheduled cleanup yet.
            // Preserve a workspace inherited from this group or its nearest ancestor.
            try execute("""
            WITH RECURSIVE workspace(id,parent_id,project_id) AS (
                SELECT id,parent_id,project_id FROM chat_groups WHERE id=?
                UNION ALL
                SELECT g.id,g.parent_id,g.project_id FROM chat_groups g
                JOIN workspace w ON g.id=w.parent_id WHERE w.project_id IS NULL
            )
            UPDATE conversations SET group_id=NULL,
                project_id=COALESCE(project_id,(SELECT project_id FROM workspace WHERE project_id IS NOT NULL LIMIT 1))
            WHERE group_id=? AND archived_at IS NOT NULL
            """, [.text(id.uuidString), .text(id.uuidString)])
            try execute("DELETE FROM chat_groups WHERE id=?", [.text(id.uuidString)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func migrateLibrary() throws {
        let version = try query("SELECT MAX(version) FROM schema_migrations") { $0.int(0) }.first ?? 0
        guard version <= 6 else { throw NativeAgentError.unsupported("This library was created by a newer NativeAgent version.") }
        guard version < 2 else { return }
        // SQLite's backup API includes committed WAL pages, unlike copying the .sqlite file.
        var backupDB: OpaquePointer?
        let backupPath = url.deletingPathExtension().appendingPathExtension("before-library-v2.sqlite3").path
        guard sqlite3_open(backupPath, &backupDB) == SQLITE_OK else { sqlite3_close(backupDB); throw databaseError() }
        guard let backup = sqlite3_backup_init(backupDB, "main", database, "main") else { sqlite3_close(backupDB); throw databaseError() }
        let copied = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        sqlite3_close(backupDB)
        guard copied == SQLITE_DONE else { throw databaseError() }
        try execute("PRAGMA foreign_keys=OFF")
        defer { try? execute("PRAGMA foreign_keys=ON") }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE chat_groups(id TEXT PRIMARY KEY,parent_id TEXT REFERENCES chat_groups(id),project_id TEXT REFERENCES projects(id),name TEXT NOT NULL,created_at REAL NOT NULL)")
            try execute("CREATE INDEX groups_parent ON chat_groups(parent_id)")
            try execute("CREATE TABLE conversations_v2(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,remote_thread_id TEXT,title TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,group_id TEXT REFERENCES chat_groups(id))")
            try execute("INSERT INTO conversations_v2(id,project_id,remote_thread_id,title,created_at,updated_at) SELECT id,project_id,remote_thread_id,title,created_at,updated_at FROM conversations")
            try execute("DROP TABLE conversations")
            try execute("ALTER TABLE conversations_v2 RENAME TO conversations")
            try execute("CREATE INDEX conversations_project_updated ON conversations(project_id,updated_at DESC)")
            try execute("CREATE INDEX conversations_group ON conversations(group_id,updated_at DESC)")
            try execute("CREATE UNIQUE INDEX conversations_remote ON conversations(remote_thread_id) WHERE remote_thread_id IS NOT NULL")
            let violations = try query("PRAGMA foreign_key_check") { $0.text(0) }
            guard violations.isEmpty else { throw NativeAgentError.protocolError("Library migration failed its integrity check.") }
            try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(2,?)", [.double(Date.now.timeIntervalSince1970)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func save(entry: TimelineEntry, conversationID: UUID) throws {
        try ensureInitialized()
        let metadata = entry.detail
        let existingOrder = try query("SELECT received_order FROM timeline_items WHERE id=?", [.text(entry.id.uuidString)]) { $0.int(0) }.first
        let nextOrder: Int
        if let existingOrder {
            nextOrder = existingOrder
        } else {
            let maximum = try query("SELECT COALESCE(MAX(received_order),0) FROM timeline_items WHERE conversation_id=?", [.text(conversationID.uuidString)]) { $0.int(0) }.first ?? 0
            nextOrder = maximum + 1
        }
        try execute(
            "INSERT INTO timeline_items(id,conversation_id,turn_id,kind,title,display_text,metadata_json,received_order,created_at,is_streaming) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,turn_id=excluded.turn_id,kind=excluded.kind,title=excluded.title,display_text=excluded.display_text,metadata_json=excluded.metadata_json,received_order=excluded.received_order,created_at=excluded.created_at,is_streaming=excluded.is_streaming",
            [.text(entry.id.uuidString), .text(conversationID.uuidString), entry.turnID.map(Binding.text) ?? .null, .text(entry.kind.rawValue), .text(entry.title), .text(entry.text), metadata.map(Binding.text) ?? .null, .int(nextOrder), .double(entry.createdAt.timeIntervalSince1970), .int(entry.isStreaming ? 1 : 0)]
        )
    }

    func timeline(conversationID: UUID, limit: Int = 100, beforeOrder: Int? = nil, afterOrder: Int? = nil, previewCharacters: Int? = nil, messagesOnly: Bool = false, detailsOnly: Bool = false) throws -> [TimelineEntry] {
        try ensureInitialized()
        let textColumn = previewCharacters.map { "substr(display_text,1,\(max(1, $0)))" } ?? "display_text"
        var sql = "SELECT id,turn_id,kind,title,\(textColumn),metadata_json,created_at,is_streaming,received_order,length(display_text) FROM timeline_items WHERE conversation_id=?"
        var bindings: [Binding] = [.text(conversationID.uuidString)]
        if messagesOnly { sql += " AND kind IN ('userMessage','agentMessage')" }
        if detailsOnly { sql += " AND kind IN ('fact','command','fileChange','agentMessage','error','approval')" }
        if let beforeOrder { sql += " AND received_order < ?"; bindings.append(.int(beforeOrder)) }
        if let afterOrder { sql += " AND received_order > ?"; bindings.append(.int(afterOrder)) }
        // Updated plans/statuses retain their timeline order, but are recent
        // details even after a long run has added hundreds of other records.
        sql += detailsOnly ? " ORDER BY created_at DESC, received_order DESC LIMIT ?" : afterOrder != nil ? " ORDER BY received_order ASC LIMIT ?" : " ORDER BY received_order DESC LIMIT ?"
        bindings.append(.int(limit))
        let entries = try query(sql, bindings) { row in
            var entry = TimelineEntry(id: UUID(uuidString: row.text(0)) ?? UUID(), turnID: row.optionalText(1), kind: TimelineKind(rawValue: row.text(2)) ?? .notice, title: row.text(3), text: row.text(4), detail: row.optionalText(5), createdAt: Date(timeIntervalSince1970: row.double(6)), isStreaming: row.int(7) != 0)
            entry.receivedOrder = row.int(8)
            entry.textIsPreview = previewCharacters.map { row.int(9) > $0 } ?? false
            return entry
        }
        return afterOrder != nil && !detailsOnly ? entries : entries.reversed()
    }

    func renameConversation(id: UUID, title: String) throws -> Conversation {
        try ensureInitialized()
        guard let existing = try conversation(id: id), existing.archivedAt == nil else {
            throw NativeAgentError.unsupported("This chat is no longer available to rename.")
        }
        try execute("UPDATE conversations SET title=? WHERE id=?", [.text(title), .text(id.uuidString)])
        var renamed = existing; renamed.title = title
        return renamed
    }

    /// Eligibility and stable transcript boundary, independent of the UI's preview window.
    func titleContext(conversationID: UUID) throws -> (userMessageCount: Int, lastMessageOrder: Int) {
        try ensureInitialized()
        guard let chat = try conversation(id: conversationID), chat.archivedAt == nil else {
            throw NativeAgentError.unsupported("This chat is no longer available to rename.")
        }
        // Count and upper bound come from the same snapshot, not the currently loaded UI page.
        return try query("SELECT COALESCE(SUM(CASE WHEN kind='userMessage' THEN 1 ELSE 0 END),0),COALESCE(MAX(received_order),0) FROM timeline_items WHERE conversation_id=? AND kind IN ('userMessage','agentMessage') AND is_streaming=0",
                         [.text(conversationID.uuidString)]) { ($0.int(0), $0.int(1)) }.first ?? (0, 0)
    }

    /// Full message text, oldest first. Used independently of the UI's preview window.
    func titleMessages(conversationID: UUID, after: Int, through: Int) throws -> [TimelineEntry] {
        try ensureInitialized()
        return try query("SELECT kind,display_text,received_order FROM timeline_items WHERE conversation_id=? AND kind IN ('userMessage','agentMessage') AND is_streaming=0 AND received_order>? AND received_order<=? ORDER BY received_order LIMIT 40",
                         [.text(conversationID.uuidString), .int(after), .int(through)]) { row in
            var entry = TimelineEntry(kind: TimelineKind(rawValue: row.text(0))!, title: "", text: row.text(1))
            entry.receivedOrder = row.int(2)
            return entry
        }
    }

    func fullTimelineText(id: UUID) throws -> String? {
        try ensureInitialized()
        return try query("SELECT display_text FROM timeline_items WHERE id=?", [.text(id.uuidString)]) { $0.text(0) }.first
    }

    /// Only IDs, order and short excerpts are loaded, not full conversation bodies.
    func promptBookmarks(conversationID: UUID, limit: Int? = nil) throws -> [PromptBookmark] {
        try ensureInitialized()
        let order = limit.map { " ORDER BY received_order DESC LIMIT \(max(1, $0))" } ?? " ORDER BY received_order"
        let entries = try query("SELECT id,received_order,substr(display_text,1,240) FROM timeline_items WHERE conversation_id=? AND kind='userMessage'" + order, [.text(conversationID.uuidString)]) { row -> PromptBookmark? in
            guard let id = UUID(uuidString: row.text(0)) else { return nil }
            return PromptBookmark(id: id, order: row.int(1), preview: row.text(2))
        }.compactMap { $0 }
        return limit == nil ? entries : entries.reversed()
    }

    func timelineWindow(conversationID: UUID, around id: UUID) throws -> [TimelineEntry] {
        try ensureInitialized()
        guard let order = try query("SELECT received_order FROM timeline_items WHERE conversation_id=? AND id=?", [.text(conversationID.uuidString), .text(id.uuidString)], map: { $0.int(0) }).first else { return [] }
        return try timeline(conversationID: conversationID, limit: 60, beforeOrder: order + 40, previewCharacters: 8_000)
    }

    func timelineOrder(id: UUID) throws -> Int? {
        try ensureInitialized()
        return try query("SELECT received_order FROM timeline_items WHERE id=?", [.text(id.uuidString)]) { $0.int(0) }.first
    }

    func saveDraft(_ text: String, conversationID: UUID) throws {
        try ensureInitialized()
        try execute("INSERT INTO drafts(conversation_id,text,updated_at) VALUES(?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET text=excluded.text,updated_at=excluded.updated_at", [.text(conversationID.uuidString), .text(text), .double(Date.now.timeIntervalSince1970)])
    }

    func draft(conversationID: UUID) throws -> String {
        try ensureInitialized()
        return try query("SELECT text FROM drafts WHERE conversation_id=?", [.text(conversationID.uuidString)]) { $0.text(0) }.first ?? ""
    }

    private func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let version = try query("SELECT COALESCE(MAX(version),0) FROM schema_migrations") { $0.int(0) }.first ?? 0
        guard version < 1 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,canonical_path TEXT NOT NULL UNIQUE,created_at REAL NOT NULL,last_opened_at REAL NOT NULL)")
            try execute("CREATE TABLE provider_profiles(id TEXT PRIMARY KEY,provider_kind TEXT NOT NULL,display_name TEXT NOT NULL,binary_path TEXT,account_namespace TEXT,last_known_version TEXT)")
            try execute("CREATE TABLE conversations(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,remote_thread_id TEXT,title TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL)")
            try execute("CREATE TABLE turns(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,remote_turn_id TEXT,status TEXT NOT NULL,started_at REAL NOT NULL,finished_at REAL,error_code TEXT)")
            try execute("CREATE TABLE timeline_items(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,turn_id TEXT,kind TEXT NOT NULL,title TEXT NOT NULL,display_text TEXT NOT NULL,metadata_json TEXT,received_order INTEGER NOT NULL,created_at REAL NOT NULL,is_streaming INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE approval_records(id TEXT PRIMARY KEY,turn_id TEXT,provider_request_id TEXT NOT NULL,kind TEXT NOT NULL,summary TEXT,decision TEXT,resolved_at REAL)")
            try execute("CREATE TABLE context_references(id TEXT PRIMARY KEY,timeline_item_id TEXT NOT NULL,relative_path TEXT NOT NULL,start_line INTEGER,end_line INTEGER,content_hash TEXT,snippet TEXT)")
            try execute("CREATE TABLE attachments(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,file_name TEXT NOT NULL,mime_type TEXT,relative_storage_path TEXT NOT NULL,size_bytes INTEGER NOT NULL,content_hash TEXT)")
            try execute("CREATE TABLE drafts(conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,text TEXT NOT NULL,updated_at REAL NOT NULL)")
            try execute("CREATE INDEX timeline_conversation_order ON timeline_items(conversation_id,received_order)")
            try execute("CREATE INDEX conversations_project_updated ON conversations(project_id,updated_at DESC)")
            try execute("CREATE UNIQUE INDEX conversations_remote ON conversations(remote_thread_id) WHERE remote_thread_id IS NOT NULL")
            try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(1,?)", [.double(Date.now.timeIntervalSince1970)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func ensureInitialized() throws {
        guard !initialized else { return }
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA secure_delete = ON")
        try migrate()
        try migrateLibrary()
        let version = try query("SELECT MAX(version) FROM schema_migrations") { $0.int(0) }.first ?? 0
        if version < 3 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("ALTER TABLE conversations ADD COLUMN provider_id TEXT NOT NULL DEFAULT 'codex'")
                try execute("DROP INDEX conversations_remote")
                try execute("CREATE UNIQUE INDEX conversations_remote ON conversations(provider_id,remote_thread_id) WHERE remote_thread_id IS NOT NULL")
                try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(3,?)", [.double(Date.now.timeIntervalSince1970)])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        if version < 4 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("ALTER TABLE conversations ADD COLUMN archived_at REAL")
                try execute("CREATE INDEX conversations_active_page ON conversations(group_id,updated_at DESC,id DESC) WHERE archived_at IS NULL")
                try execute("CREATE INDEX conversations_archive_expiry ON conversations(archived_at) WHERE archived_at IS NOT NULL")
                try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(4,?)", [.double(Date.now.timeIntervalSince1970)])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        if version < 5 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("CREATE TABLE feature_records(kind TEXT NOT NULL,id TEXT NOT NULL,project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,title TEXT NOT NULL,search_text TEXT NOT NULL,payload TEXT NOT NULL,updated_at REAL NOT NULL,PRIMARY KEY(kind,id))")
                try execute("CREATE INDEX features_scope ON feature_records(kind,conversation_id,project_id,updated_at)")
                try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(5,?)", [.double(Date.now.timeIntervalSince1970)])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        if version < 6 { try migrateArchiveStorage() }
        initialized = true
    }

    private func migrateArchiveStorage() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("ALTER TABLE conversations ADD COLUMN stored_bytes INTEGER NOT NULL DEFAULT 0 CHECK(stored_bytes >= 0)")
            try execute("CREATE INDEX conversations_archive_page ON conversations(archived_at DESC,id DESC) WHERE archived_at IS NOT NULL")
            try execute("CREATE INDEX features_conversation ON feature_records(conversation_id) WHERE conversation_id IS NOT NULL")
            try execute("CREATE INDEX attachments_conversation ON attachments(conversation_id)")
            // One migration-time scan, entirely inside SQLite. Later writes update only one small counter.
            for table in ArchiveStorageSchema.payloadTables {
                try execute("UPDATE conversations SET stored_bytes = stored_bytes + COALESCE((SELECT SUM(\(table.bytes())) FROM \(table.name) WHERE conversation_id=conversations.id),0)")
            }
            for name in ArchiveStorageSchema.triggers.keys.sorted() {
                try execute(ArchiveStorageSchema.triggers[name]!)
            }
            try execute("INSERT INTO schema_migrations(version,applied_at) VALUES(6,?)", [.double(Date.now.timeIntervalSince1970)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func saveFeature<T: Encodable & Sendable>(_ value: T, kind: String, id: String, title: String = "", searchText: String = "", projectID: UUID? = nil, conversationID: UUID? = nil) throws {
        try ensureInitialized()
        let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try execute("INSERT INTO feature_records VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET project_id=excluded.project_id,conversation_id=excluded.conversation_id,title=excluded.title,search_text=excluded.search_text,payload=excluded.payload,updated_at=excluded.updated_at", [.text(kind), .text(id), projectID.map { .text($0.uuidString) } ?? .null, conversationID.map { .text($0.uuidString) } ?? .null, .text(title), .text(searchText), .text(payload), .double(Date.now.timeIntervalSince1970)])
    }

    func feature<T: Decodable & Sendable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        try ensureInitialized()
        return try query("SELECT payload FROM feature_records WHERE kind=? AND id=?", [.text(kind), .text(id)]) { try JSONDecoder().decode(type, from: Data($0.text(0).utf8)) }.first
    }

    func features<T: Decodable & Sendable>(_ type: T.Type, kind: String, projectID: UUID? = nil, conversationID: UUID? = nil, limit: Int = 100, offset: Int = 0, search: String = "") throws -> [T] {
        try ensureInitialized()
        var sql = "SELECT payload FROM feature_records WHERE kind=?"
        var bindings: [Binding] = [.text(kind)]
        if let projectID { sql += " AND (project_id=? OR project_id IS NULL)"; bindings.append(.text(projectID.uuidString)) }
        if let conversationID { sql += " AND conversation_id=?"; bindings.append(.text(conversationID.uuidString)) }
        if !search.isEmpty { sql += " AND instr(lower(title || ' ' || search_text),lower(?))>0"; bindings.append(.text(search)) }
        sql += " ORDER BY updated_at DESC,id LIMIT ? OFFSET ?"
        bindings += [.int(min(200, max(1, limit))), .int(max(0, offset))]
        return try query(sql, bindings) { try JSONDecoder().decode(type, from: Data($0.text(0).utf8)) }
    }

    func removeFeature(kind: String, id: String) throws {
        try ensureInitialized(); try execute("DELETE FROM feature_records WHERE kind=? AND id=?", [.text(kind), .text(id)])
    }

    func conversation(id: UUID) throws -> Conversation? {
        try ensureInitialized()
        return try query("SELECT id,project_id,group_id,remote_thread_id,title,created_at,updated_at,provider_id,archived_at FROM conversations WHERE id=?", [.text(id.uuidString)]) { row in
            var chat = Conversation(id: id, projectID: row.optionalText(1).flatMap(UUID.init(uuidString:)), groupID: row.optionalText(2).flatMap(UUID.init(uuidString:)), remoteThreadID: row.optionalText(3), title: row.text(4), createdAt: Date(timeIntervalSince1970: row.double(5)), updatedAt: Date(timeIntervalSince1970: row.double(6)))
            chat.providerID = ProviderKind(rawValue: row.text(7)) ?? .codex
            chat.archivedAt = row.optionalText(8).map { _ in Date(timeIntervalSince1970: row.double(8)) }
            return chat
        }.first
    }

    func branchLinks(for id: UUID) throws -> [BranchLink] {
        try ensureInitialized()
        return try query("SELECT payload FROM feature_records WHERE kind='branch' AND (id=? OR json_extract(payload,'$.parentID')=?) ORDER BY updated_at DESC LIMIT 100", [.text(id.uuidString), .text(id.uuidString)]) { try JSONDecoder().decode(BranchLink.self, from: Data($0.text(0).utf8)) }
    }

    /// Copy complete message history before the selected prompt, not a UI preview.
    func retryBranch(from parent: Conversation, entryID: UUID, editedPrompt: String? = nil) throws -> Conversation {
        try ensureInitialized()
        guard try conversation(id: parent.id)?.archivedAt == nil,
              let target = try query("SELECT received_order FROM timeline_items WHERE id=? AND conversation_id=?", [.text(entryID.uuidString), .text(parent.id.uuidString)], map: { $0.int(0) }).first,
              let prompt = try query("SELECT id,received_order,display_text FROM timeline_items WHERE conversation_id=? AND kind='userMessage' AND received_order<=? ORDER BY received_order DESC LIMIT 1", [.text(parent.id.uuidString), .int(target)], map: { ($0.text(0), $0.int(1), $0.text(2)) }).first else {
            throw NativeAgentError.unsupported("No original prompt is available to retry.")
        }
        let text = editedPrompt ?? prompt.2
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeAgentError.unsupported("Enter a message before continuing.") }
        var child = Conversation(projectID: parent.projectID, groupID: parent.groupID, title: "Retry · " + parent.title)
        child.providerID = parent.providerID
        try execute("BEGIN IMMEDIATE")
        do {
            try save(conversation: child)
            var cursor = 0
            while true {
                let page = try query("SELECT received_order,kind,title,display_text,created_at FROM timeline_items WHERE conversation_id=? AND kind IN ('userMessage','agentMessage') AND is_streaming=0 AND received_order>? AND received_order<? ORDER BY received_order LIMIT 100", [.text(parent.id.uuidString), .int(cursor), .int(prompt.1)]) { row in
                    (row.int(0), TimelineEntry(kind: TimelineKind(rawValue: row.text(1))!, title: row.text(2), text: row.text(3), createdAt: Date(timeIntervalSince1970: row.double(4))))
                }
                if page.isEmpty { break }
                for (order, entry) in page { try save(entry: entry, conversationID: child.id); cursor = order }
            }
            var context = try feature([ContextAttachment].self, kind: "context", id: parent.id.uuidString) ?? []
            for index in context.indices { context[index].allowEdits = false }
            try saveFeature(context, kind: "context", id: child.id.uuidString, conversationID: child.id)
            if let pins = try feature(String.self, kind: "chat-pins", id: parent.id.uuidString) {
                try saveFeature(pins, kind: "chat-pins", id: child.id.uuidString, conversationID: child.id)
            }
            let link = BranchLink(id: child.id, parentID: parent.id, messageID: entryID, parentTitle: parent.title, branchTitle: child.title, mode: "Retry branch with complete earlier messages; original unchanged")
            try saveFeature(link, kind: "branch", id: child.id.uuidString, conversationID: child.id)
            try saveDraft(text, conversationID: child.id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return child
    }

    /// A new local identity plus explicitly selected, bounded context; never a reused remote session.
    func branch(from parent: Conversation, messageID: UUID) throws -> (Conversation, [ContextAttachment]) {
        try ensureInitialized()
        guard let entry = try query("SELECT received_order,kind,display_text FROM timeline_items WHERE id=? AND conversation_id=?", [.text(messageID.uuidString), .text(parent.id.uuidString)], map: { ($0.int(0), $0.text(1), $0.text(2)) }).first else { throw NativeAgentError.unsupported("The branch point is no longer available.") }
        let history = try timeline(conversationID: parent.id, limit: 24, beforeOrder: entry.0 + (entry.1 == "userMessage" ? 0 : 1), previewCharacters: 2_000, messagesOnly: true)
        var child = Conversation(projectID: parent.projectID, groupID: parent.groupID, title: "Branch · " + parent.title)
        child.providerID = parent.providerID
        let context = history.isEmpty ? [] : [ContextAttachment(kind: .excerpt, title: "Selected branch context (up to 24 messages, 2,000 characters each)", text: history.map { "\($0.kind == .userMessage ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n"))]
        try execute("BEGIN IMMEDIATE")
        do {
            try save(conversation: child)
            try saveDraft(entry.1 == "userMessage" ? entry.2 : "", conversationID: child.id)
            let link = BranchLink(id: child.id, parentID: parent.id, messageID: messageID, parentTitle: parent.title, branchTitle: child.title)
            try saveFeature(link, kind: "branch", id: child.id.uuidString, title: child.title, projectID: child.projectID, conversationID: child.id)
            try saveFeature(context, kind: "context", id: child.id.uuidString, conversationID: child.id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return (child, context)
    }

    func globalSearch(_ text: String, offset: Int = 0, limit: Int = 40) throws -> [LocalSearchHit] {
        try ensureInitialized()
        try Task.checkCancellation()
        // The callback runs synchronously inside this task's sqlite3_step, on the database actor.
        sqlite3_progress_handler(database, 1_000, { _ in withUnsafeCurrentTask { $0?.isCancelled == true ? 1 : 0 } }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let sql = """
        WITH hits(kind,id,title,body,project_id,conversation_id) AS (
          SELECT 'message',t.id,t.title,t.display_text,c.project_id,c.id FROM timeline_items t JOIN conversations c ON c.id=t.conversation_id WHERE c.archived_at IS NULL
          UNION ALL SELECT 'conversation',id,title,title,project_id,id FROM conversations WHERE archived_at IS NULL
          UNION ALL SELECT 'project',id,name,canonical_path,id,NULL FROM projects
          UNION ALL SELECT f.kind,f.id,f.title,f.search_text,f.project_id,f.conversation_id FROM feature_records f LEFT JOIN conversations c ON c.id=f.conversation_id WHERE f.kind IN ('report','template') AND (f.conversation_id IS NULL OR c.archived_at IS NULL)
        )
        SELECT h.kind,h.id,h.title,substr(h.body,max(1,instr(lower(h.body),lower(?))-60),240),h.project_id,h.conversation_id,COALESCE(p.name,''),COALESCE(c.title,'') FROM hits h LEFT JOIN projects p ON p.id=h.project_id LEFT JOIN conversations c ON c.id=h.conversation_id WHERE instr(lower(h.title || ' ' || h.body),lower(?))>0 ORDER BY h.kind,h.id LIMIT ? OFFSET ?
        """
        return try query(sql, [.text(text), .text(text), .int(min(100, max(1, limit))), .int(max(0, offset))]) { row in
            LocalSearchHit(kind: row.text(0), recordID: row.text(1), title: row.text(2), excerpt: row.text(3), projectID: row.optionalText(4).flatMap(UUID.init(uuidString:)), conversationID: row.optionalText(5).flatMap(UUID.init(uuidString:)), projectName: row.text(6), conversationTitle: row.text(7))
        }
    }

    func saveTaskReport(_ report: TaskReport) throws {
        try saveFeature(report, kind: "report", id: report.id.uuidString, title: String(report.prompt.prefix(100)), searchText: report.markdown, projectID: report.projectID, conversationID: report.conversationID)
    }

    func unfinishedReports() throws -> [TaskReport] {
        try ensureInitialized()
        return try query("SELECT payload FROM feature_records WHERE kind='report' AND json_extract(payload,'$.state') IN ('running','awaitingApproval','awaitingInput') ORDER BY updated_at DESC LIMIT 200") {
            try JSONDecoder().decode(TaskReport.self, from: Data($0.text(0).utf8))
        }
    }

    /// Listing reports never decodes their command output or checkpoint contents.
    func reportSummaries(projectID: UUID?, offset: Int = 0) throws -> [TaskReport] {
        try ensureInitialized()
        var sql = "SELECT id,conversation_id,project_id,title,json_extract(payload,'$.projectPath'),json_extract(payload,'$.provider'),json_extract(payload,'$.state'),json_extract(payload,'$.startedAt') FROM feature_records WHERE kind='report'"
        var bindings: [Binding] = []
        if let projectID { sql += " AND project_id=?"; bindings.append(.text(projectID.uuidString)) }
        sql += " ORDER BY updated_at DESC,id LIMIT 30 OFFSET ?"; bindings.append(.int(max(0, offset)))
        return try query(sql, bindings) { row in
            guard let id = UUID(uuidString: row.text(0)), let chat = UUID(uuidString: row.text(1)), let project = UUID(uuidString: row.text(2)) else { throw NativeAgentError.protocolError("Invalid report identity") }
            return TaskReport(id: id, conversationID: chat, projectID: project, projectPath: row.text(4), provider: ProviderKind(rawValue: row.text(5)) ?? .codex, prompt: row.text(3), state: WorkTaskState(rawValue: row.text(6)) ?? .needsReview, startedAt: Date(timeIntervalSinceReferenceDate: row.double(7)))
        }
    }

    private enum Binding { case null, text(String), int(Int), double(Double) }

    private struct Row {
        let statement: OpaquePointer
        func text(_ index: Int32) -> String { optionalText(index) ?? "" }
        func optionalText(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL, let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        }
        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result != SQLITE_ROW { throw databaseError() }
        }
    }

    private func query<T>(_ sql: String, _ bindings: [Binding] = [], map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { values.append(try map(Row(statement: statement))) }
            else if result == SQLITE_DONE { return values }
            else { throw databaseError() }
        }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .int(let value): result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    private func databaseError() -> Error {
        NativeAgentError.providerUnavailable(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unknown database error")
    }
}

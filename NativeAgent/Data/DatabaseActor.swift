import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor DatabaseActor {
    private var database: OpaquePointer?
    private var initialized = false
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NativeAgentError.providerUnavailable("Could not open the local database.")
        }
    }

    deinit { sqlite3_close(database) }

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
            sql += "archived_at > ?"
            bindings.append(.double(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970))
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

    func restoreConversation(id: UUID, now: Date = .now) throws -> Bool {
        try ensureInitialized()
        try execute("UPDATE conversations SET archived_at=NULL WHERE id=? AND archived_at > ?", [.text(id.uuidString), .double(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970)])
        return sqlite3_changes(database) > 0
    }

    /// Small transactions keep maintenance from monopolizing the database actor.
    @discardableResult
    func purgeExpiredArchive(now: Date = .now, limit: Int = 100) throws -> [UUID] {
        try ensureInitialized()
        let ids = try query("SELECT id FROM conversations WHERE archived_at <= ? ORDER BY archived_at LIMIT ?", [.double(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970), .int(max(1, min(limit, 200)))]) { UUID(uuidString: $0.text(0))! }
        guard !ids.isEmpty else { return [] }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                let binding: [Binding] = [.text(id.uuidString)]
                try execute("DELETE FROM context_references WHERE timeline_item_id IN (SELECT id FROM timeline_items WHERE conversation_id=?)", binding)
                try execute("DELETE FROM approval_records WHERE turn_id IN (SELECT id FROM turns WHERE conversation_id=?)", binding)
                try execute("DELETE FROM attachments WHERE conversation_id=?", binding)
                try execute("DELETE FROM conversations WHERE id=?", binding)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return ids
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
        let children = try query("SELECT (SELECT COUNT(*) FROM chat_groups WHERE parent_id=?) + (SELECT COUNT(*) FROM conversations WHERE group_id=?)", [.text(id.uuidString), .text(id.uuidString)]) { $0.int(0) }.first ?? 0
        guard children == 0 else { throw NativeAgentError.unsupported("Move the chats and folders out of this group before removing it.") }
        try execute("DELETE FROM chat_groups WHERE id=?", [.text(id.uuidString)])
    }

    private func migrateLibrary() throws {
        let version = try query("SELECT MAX(version) FROM schema_migrations") { $0.int(0) }.first ?? 0
        guard version <= 5 else { throw NativeAgentError.unsupported("This library was created by a newer NativeAgent version.") }
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
            "INSERT OR REPLACE INTO timeline_items(id,conversation_id,turn_id,kind,title,display_text,metadata_json,received_order,created_at,is_streaming) VALUES(?,?,?,?,?,?,?,?,?,?)",
            [.text(entry.id.uuidString), .text(conversationID.uuidString), entry.turnID.map(Binding.text) ?? .null, .text(entry.kind.rawValue), .text(entry.title), .text(entry.text), metadata.map(Binding.text) ?? .null, .int(nextOrder), .double(entry.createdAt.timeIntervalSince1970), .int(entry.isStreaming ? 1 : 0)]
        )
    }

    func timeline(conversationID: UUID, limit: Int = 100, beforeOrder: Int? = nil, previewCharacters: Int? = nil, messagesOnly: Bool = false, detailsOnly: Bool = false) throws -> [TimelineEntry] {
        try ensureInitialized()
        let textColumn = previewCharacters.map { "substr(display_text,1,\(max(1, $0)))" } ?? "display_text"
        var sql = "SELECT id,turn_id,kind,title,\(textColumn),metadata_json,created_at,is_streaming,received_order,length(display_text) FROM timeline_items WHERE conversation_id=?"
        var bindings: [Binding] = [.text(conversationID.uuidString)]
        if messagesOnly { sql += " AND kind IN ('userMessage','agentMessage')" }
        if detailsOnly { sql += " AND kind IN ('fact','command','fileChange','agentMessage','error','approval')" }
        if let beforeOrder { sql += " AND received_order < ?"; bindings.append(.int(beforeOrder)) }
        // Updated plans/statuses retain their timeline order, but are recent
        // details even after a long run has added hundreds of other records.
        sql += detailsOnly ? " ORDER BY created_at DESC, received_order DESC LIMIT ?" : " ORDER BY received_order DESC LIMIT ?"
        bindings.append(.int(limit))
        return try query(sql, bindings) { row in
            var entry = TimelineEntry(id: UUID(uuidString: row.text(0)) ?? UUID(), turnID: row.optionalText(1), kind: TimelineKind(rawValue: row.text(2)) ?? .notice, title: row.text(3), text: row.text(4), detail: row.optionalText(5), createdAt: Date(timeIntervalSince1970: row.double(6)), isStreaming: row.int(7) != 0)
            entry.receivedOrder = row.int(8)
            entry.textIsPreview = previewCharacters.map { row.int(9) > $0 } ?? false
            return entry
        }.reversed()
    }

    func fullTimelineText(id: UUID) throws -> String? {
        try ensureInitialized()
        return try query("SELECT display_text FROM timeline_items WHERE id=?", [.text(id.uuidString)]) { $0.text(0) }.first
    }

    /// Only IDs, order and short excerpts are loaded, not full conversation bodies.
    func promptBookmarks(conversationID: UUID) throws -> [PromptBookmark] {
        try ensureInitialized()
        return try query("SELECT id,received_order,substr(display_text,1,240) FROM timeline_items WHERE conversation_id=? AND kind='userMessage' ORDER BY received_order", [.text(conversationID.uuidString)]) { row -> PromptBookmark? in
            guard let id = UUID(uuidString: row.text(0)) else { return nil }
            return PromptBookmark(id: id, order: row.int(1), preview: row.text(2))
        }.compactMap { $0 }
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
        initialized = true
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

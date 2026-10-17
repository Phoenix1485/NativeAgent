import Foundation
import CSQLite

enum LibrarySnapshots {
    static func folder(for database: URL) -> URL { database.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    static func pending(for database: URL) -> URL { database.deletingLastPathComponent().appendingPathComponent("restore-pending.sqlite3") }

    static func validate(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("Choose a regular NativeAgent backup file.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); throw failure("Could not open backup.") }
        defer { sqlite3_close(db) }
        guard try scalar(db, "PRAGMA quick_check") == "ok",
              let version = Int(try scalar(db, "SELECT MAX(version) FROM schema_migrations")), (5...7).contains(version) else {
            throw failure("This is not a compatible, healthy NativeAgent backup.")
        }
        try validateSchemaObjects(db, version: version)
        for query in ["SELECT id,title,archived_at FROM conversations LIMIT 0", "SELECT id,conversation_id,display_text FROM timeline_items LIMIT 0", "SELECT kind,id,payload FROM feature_records LIMIT 0", "SELECT conversation_id,text FROM drafts LIMIT 0", "SELECT id,parent_id FROM chat_groups LIMIT 0"] {
            var statement: OpaquePointer?
            let code = sqlite3_prepare_v2(db, query, -1, &statement, nil); sqlite3_finalize(statement)
            guard code == SQLITE_OK else { throw failure("The backup’s library schema is incomplete.") }
        }
        if version >= 6 {
            guard try scalar(db, "SELECT COALESCE(SUM(stored_bytes < 0),0) FROM conversations") == "0" else {
                throw failure("The backup contains invalid chat storage sizes.")
            }
        }
        if version >= 7 {
            guard try scalar(db, "SELECT COUNT(*) FROM usage_tracking WHERE id=1 AND started_at>=0 AND started_at<=253402300799") == "1",
                  try scalar(db, "SELECT COUNT(*) FROM pragma_foreign_key_list('usage_records')") == "0",
                  try scalar(db, """
                  SELECT COUNT(*) FROM usage_records WHERE
                    id IS NULL OR length(id)=0 OR length(CAST(id AS BLOB))>512 OR
                    recorded_at IS NULL OR recorded_at<0 OR recorded_at>253402300799 OR
                    provider IS NULL OR length(provider)=0 OR length(CAST(provider AS BLOB))>1024 OR
                    model IS NULL OR length(CAST(model AS BLOB))>2048 OR
                    source IS NULL OR length(source)=0 OR length(CAST(source AS BLOB))>128 OR
                    activity IS NULL OR length(activity)=0 OR length(CAST(activity AS BLOB))>128 OR
                    instr(id,char(0))>0 OR instr(provider,char(0))>0 OR instr(model,char(0))>0 OR instr(source,char(0))>0 OR instr(activity,char(0))>0 OR
                    (conversation_id IS NOT NULL AND (typeof(conversation_id)!='text' OR length(CAST(conversation_id AS BLOB))!=36 OR
                        substr(conversation_id,9,1)!='-' OR substr(conversation_id,14,1)!='-' OR
                        substr(conversation_id,19,1)!='-' OR substr(conversation_id,24,1)!='-' OR
                        length(replace(conversation_id,'-',''))!=32 OR replace(conversation_id,'-','') GLOB '*[^0-9A-Fa-f]*')) OR
                    ((input_tokens IS NULL) != (output_tokens IS NULL)) OR
                    (input_tokens IS NOT NULL AND (typeof(input_tokens)!='integer' OR input_tokens<0 OR input_tokens>1000000000000)) OR
                    (output_tokens IS NOT NULL AND (typeof(output_tokens)!='integer' OR output_tokens<0 OR output_tokens>1000000000000)) OR
                    input_tokens+output_tokens>1000000000000 OR
                    (cached_input_tokens IS NOT NULL AND (input_tokens IS NULL OR typeof(cached_input_tokens)!='integer' OR cached_input_tokens<0 OR cached_input_tokens>input_tokens)) OR
                    (cache_write_input_tokens IS NOT NULL AND (input_tokens IS NULL OR typeof(cache_write_input_tokens)!='integer' OR cache_write_input_tokens<0 OR cache_write_input_tokens>input_tokens-COALESCE(cached_input_tokens,0))) OR
                    (reasoning_output_tokens IS NOT NULL AND (output_tokens IS NULL OR typeof(reasoning_output_tokens)!='integer' OR reasoning_output_tokens<0 OR reasoning_output_tokens>output_tokens)) OR
                    (context_tokens IS NOT NULL AND (typeof(context_tokens)!='integer' OR context_tokens<0 OR context_tokens>1000000000000)) OR
                    (context_limit IS NOT NULL AND (typeof(context_limit)!='integer' OR context_limit<1 OR context_limit>1000000000000))
                  """) == "0" else { throw failure("The backup contains an invalid usage ledger.") }
        }
        guard try scalar(db, "PRAGMA foreign_key_check").isEmpty else { throw failure("The backup contains broken references.") }
    }

    private static func validateSchemaObjects(_ db: OpaquePointer?, version: Int) throws {
        let expected = version >= 6 ? ArchiveStorageSchema.triggers : [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT type,name,sql FROM sqlite_master WHERE type IN ('trigger','view')", -1, &statement, nil) == SQLITE_OK else {
            throw failure("Could not validate the backup’s schema.")
        }
        defer { sqlite3_finalize(statement) }
        var found: Set<String> = []
        func normalized(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW,
                  let type = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1),
                  let sql = sqlite3_column_text(statement, 2) else { throw failure("Invalid backup schema.") }
            let key = String(cString: name)
            guard String(cString: type) == "trigger", let definition = expected[key],
                  normalized(String(cString: sql)) == normalized(definition) else {
                throw failure("The backup contains an unexpected schema trigger or view.")
            }
            found.insert(key)
        }
        guard found == Set(expected.keys) else { throw failure("The backup’s storage accounting schema is incomplete.") }
    }

    static func copy(from source: URL, to destination: URL, overwrite: Bool = false) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw failure("Choose a different backup location.") }
        if !overwrite && FileManager.default.fileExists(atPath: destination.path) { throw failure("The destination already exists.") }
        if FileManager.default.fileExists(atPath: destination.path), try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw failure("Refusing a symbolic-link destination.") }
        var input: OpaquePointer?, output: OpaquePointer?
        defer { sqlite3_close(input); sqlite3_close(output) }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw failure("Could not open the snapshot files.") }
        sqlite3_busy_timeout(output, 3_000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw failure("Could not start the snapshot.") }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw failure("Snapshot could not finish. The library was not replaced; try again when it is idle.") }
        if !overwrite {
            guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw failure("Could not finalize a self-contained backup.") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func create(for database: URL, prefix: String) throws -> URL {
        let directory = folder(for: database)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(prefix)-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString).sqlite3")
        try copy(from: database, to: url)
        try validate(url)
        return url
    }

    static func list(for database: URL) throws -> [URL] {
        let directory = folder(for: database)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey])
            .filter { $0.pathExtension == "sqlite3" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }

    static func daily(for database: URL, now: Date = .now) throws {
        let existing = try list(for: database).filter { $0.lastPathComponent.hasPrefix("daily-") }
        if let latest = existing.first, let date = try latest.resourceValues(forKeys: [.creationDateKey]).creationDate, now.timeIntervalSince(date) < 86_400 { return }
        _ = try create(for: database, prefix: "daily")
        // Only old automatically generated snapshots in our dedicated backup folder.
        for old in existing.dropFirst(6) { try FileManager.default.removeItem(at: old) }
    }

    static func stage(source: URL, database: URL) throws {
        try validate(source)
        let destination = pending(for: database)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("A restore is already queued. Relaunch NativeAgent first.") }
        let staging = database.deletingLastPathComponent().appendingPathComponent("restore-stage-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: staging) }
        try copy(from: source, to: staging)
        try validate(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    /// Called before opening the application's live connection, never while its UI can write.
    static func applyPending(to database: URL) throws {
        let source = pending(for: database)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try validate(source)
        if FileManager.default.fileExists(atPath: database.path) { _ = try create(for: database, prefix: "before-restore") }
        try copy(from: source, to: database, overwrite: true)
        // Restoring local history must not resume old remote sessions or reconnect automatically.
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); throw failure("Restore needs attention.") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "UPDATE conversations SET remote_thread_id=NULL; DELETE FROM feature_records WHERE kind='session';", nil, nil, nil) == SQLITE_OK else { throw failure("Could not reset restored session state.") }
        try FileManager.default.removeItem(at: source)
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("Invalid backup schema: \(String(cString: sqlite3_errmsg(db))).") }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return "" }
        guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure("Could not validate backup.") }
        return String(cString: text)
    }
    private static func failure(_ message: String) -> Error { NativeAgentError.unsupported(message) }
}

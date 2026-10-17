import Foundation

/// Persist small content-size counters so archive browsing and cleanup never load chat histories.
/// Keep the exact trigger definitions shared with backup validation, which rejects unknown triggers.
enum ArchiveStorageSchema {
    struct PayloadTable {
        let name: String
        let columns: [String]

        func bytes(prefix: String = "") -> String {
            columns.map { "COALESCE(length(CAST(\(prefix)\($0) AS BLOB)),0)" }.joined(separator: " + ")
        }
    }

    static let payloadTables = [
        PayloadTable(name: "timeline_items", columns: ["title", "display_text", "metadata_json"]),
        PayloadTable(name: "drafts", columns: ["text"]),
        PayloadTable(name: "feature_records", columns: ["title", "search_text", "payload"]),
        PayloadTable(name: "attachments", columns: ["file_name", "mime_type", "relative_storage_path", "content_hash"])
    ]

    static let triggers: [String: String] = {
        var result: [String: String] = [:]
        for table in payloadTables {
            let prefix = "archive_bytes_\(table.name)"
            result[prefix + "_insert"] = """
            CREATE TRIGGER \(prefix)_insert AFTER INSERT ON \(table.name) BEGIN
                UPDATE conversations SET stored_bytes = stored_bytes + (\(table.bytes(prefix: "NEW."))) WHERE id = NEW.conversation_id;
            END
            """
            result[prefix + "_delete"] = """
            CREATE TRIGGER \(prefix)_delete AFTER DELETE ON \(table.name) BEGIN
                UPDATE conversations SET stored_bytes = stored_bytes - (\(table.bytes(prefix: "OLD."))) WHERE id = OLD.conversation_id;
            END
            """
            result[prefix + "_update"] = """
            CREATE TRIGGER \(prefix)_update AFTER UPDATE OF conversation_id,\(table.columns.joined(separator: ",")) ON \(table.name) BEGIN
                UPDATE conversations SET stored_bytes = stored_bytes - (\(table.bytes(prefix: "OLD."))) WHERE id = OLD.conversation_id;
                UPDATE conversations SET stored_bytes = stored_bytes + (\(table.bytes(prefix: "NEW."))) WHERE id = NEW.conversation_id;
            END
            """
        }
        return result
    }()
}

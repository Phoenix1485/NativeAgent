import CSQLite
import Foundation
import XCTest
@testable import NativeAgent

final class UsageDatabaseTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var database: DatabaseActor!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = directory.appendingPathComponent("usage.sqlite3")
        database = try DatabaseActor(url: url)
        _ = try await database.usageSummary()
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ sql: String, at target: URL? = nil) throws {
        var connection: OpaquePointer?
        guard sqlite3_open((target ?? url).path, &connection) == SQLITE_OK else { throw NativeAgentError.unsupported("Could not open usage fixture") }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NativeAgentError.unsupported(String(cString: sqlite3_errmsg(connection)))
        }
    }

    private func record(_ id: String, at date: Date = .now, input: Int64? = 100, output: Int64 = 20,
                        provider: String = "openai", model: String = "model-a", chat: UUID? = nil) -> UsageRecord {
        UsageRecord(id: id, recordedAt: date, provider: provider, model: model, source: "api", activity: "Chat",
                    conversationID: chat, tokens: input.map { UsageTokens(inputTokens: $0, outputTokens: output) })
    }

    func testReportsUpsertWithoutDoubleCountingAndKeepMissingDistinctFromZero() async throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let original = record("request", at: date, input: nil)
        try await database.recordUsage(original)
        try await database.recordUsage(record("unreported", at: date, input: nil))
        try await database.recordUsage(record("zero", at: date, input: 0, output: 0))
        let before = try await database.usageSummary()
        XCTAssertEqual(before.totals.recordCount, 3)
        XCTAssertEqual(before.totals.reportedCount, 1)
        XCTAssertEqual(before.totals.missingCount, 2)
        var update = original
        update.recordedAt = date.addingTimeInterval(86_400)
        update.model = "actual-model-name"
        update.tokens = UsageTokens(inputTokens: 200, outputTokens: 50, cachedInputTokens: 80, cacheWriteInputTokens: 30, reasoningOutputTokens: 20)
        try await database.recordUsage(update)
        try await database.recordUsage(update)
        try await database.recordUsage(original) // Missing final metadata must not erase a report.
        let page = try await database.usageRecords()
        let saved = try XCTUnwrap(page.first { $0.id == "request" })
        XCTAssertEqual(saved.recordedAt, date)
        XCTAssertEqual(saved.model, original.model)
        XCTAssertEqual(saved.tokens, update.tokens)
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 3)
        XCTAssertEqual(summary.totals.reportedCount, 2)
        XCTAssertEqual(summary.totals.missingCount, 1)
        XCTAssertEqual(summary.totals.tokens.totalTokens, 250)
        XCTAssertEqual(summary.totals.tokens.cachedInputTokens, 80)
        XCTAssertEqual(summary.totals.tokens.reasoningOutputTokens, 20)
        let reopened = try DatabaseActor(url: url)
        let persisted = try await reopened.usageSummary()
        XCTAssertEqual(persisted.totals, summary.totals)
        XCTAssertEqual(persisted.trackingStartedAt, before.trackingStartedAt)
    }

    func testDateProviderModelAndConversationFiltersUseInclusiveStartExclusiveEnd() async throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 2_000_000_000))
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: day))
        let chat = UUID()
        try await database.recordUsage(record("before", at: day.addingTimeInterval(-1)))
        try await database.recordUsage(record("start", at: day, input: 10, output: 2, chat: chat))
        try await database.recordUsage(record("inside", at: day.addingTimeInterval(60), input: 30, output: 4, chat: chat))
        try await database.recordUsage(record("end", at: tomorrow))
        try await database.recordUsage(record("other-provider", at: day, provider: "anthropic", chat: chat))
        try await database.recordUsage(record("other-model", at: day, model: "model-b", chat: chat))
        try await database.recordUsage(record("other-chat", at: day))
        let query = UsageQuery(start: day, end: tomorrow, provider: "openai", model: "model-a", conversationID: chat)
        let summary = try await database.usageSummary(query: query)
        XCTAssertEqual(summary.totals.recordCount, 2)
        XCTAssertEqual(summary.totals.tokens.totalTokens, 46)
        XCTAssertEqual(summary.daily.count, 1)
        XCTAssertEqual(summary.daily.first?.aggregate, summary.totals)
        XCTAssertEqual(summary.providers.first?.label, "openai")
        XCTAssertEqual(summary.models.first?.label, "model-a")
        XCTAssertEqual(summary.models.first?.provider, "openai")
        let first = try await database.usageRecords(query: query, limit: 1)
        let second = try await database.usageRecords(query: query, after: first.last, limit: 1)
        XCTAssertEqual(first.map(\.id), ["inside"])
        XCTAssertEqual(second.map(\.id), ["start"])
        do { _ = try await database.usageSummary(query: .init(start: tomorrow, end: day)); XCTFail("Invalid range accepted") } catch { }
    }

    func testUsageSurvivesChatPurgeAndKeepsDeletedChatIdentity() async throws {
        let chat = Conversation(title: "Original chat")
        try await database.save(conversation: chat)
        try await database.recordUsage(record("retained", chat: chat.id))
        var report = record("context", input: nil, chat: chat.id)
        report.contextTokens = 12_345; report.contextLimit = 128_000
        try await database.recordUsage(report)
        let before = try await database.usageSummary()
        XCTAssertEqual(before.conversations.first?.label, chat.title)
        try await database.archiveConversation(id: chat.id, now: Date.now.addingTimeInterval(-31 * 86_400))
        _ = try await database.purgeExpiredArchive()
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals, before.totals)
        XCTAssertEqual(summary.conversations.first?.id, chat.id.uuidString)
        XCTAssertEqual(summary.conversations.first?.label, "Deleted chat")
        let records = try await database.usageRecords(query: .init(conversationID: chat.id))
        XCTAssertEqual(records.count, 2)
        let context = try await database.latestUsageContext(conversationID: chat.id)
        XCTAssertEqual(context?.contextTokens, 12_345)
        XCTAssertEqual(context?.contextLimit, 128_000)
        XCTAssertNil(context?.tokens)
    }

    func testSubsetsNormalizeAndInvalidCountsOrIdentityCannotAlterExistingRecord() async throws {
        var item = record("valid", input: 100, output: 10)
        item.tokens = UsageTokens(inputTokens: 100, outputTokens: 10, cachedInputTokens: 90, cacheWriteInputTokens: 50, reasoningOutputTokens: 999)
        XCTAssertEqual(item.tokens?.totalTokens, 110)
        XCTAssertNil(item.tokens?.cacheWriteInputTokens)
        XCTAssertNil(item.tokens?.reasoningOutputTokens)
        let decodedJSON = try JSONDecoder().decode(UsageTokens.self, from: Data("{\"inputTokens\":100,\"outputTokens\":10,\"cachedInputTokens\":999,\"cacheWriteInputTokens\":50,\"reasoningOutputTokens\":-1}".utf8))
        XCTAssertNil(decodedJSON.cachedInputTokens)
        XCTAssertEqual(decodedJSON.cacheWriteInputTokens, 50)
        XCTAssertNil(decodedJSON.reasoningOutputTokens)
        try await database.recordUsage(item)
        var decoded = item
        // Mutations/decoding also pass through normalization at the persistence boundary.
        decoded.tokens?.cachedInputTokens = -4
        decoded.tokens?.cacheWriteInputTokens = 999
        try await database.recordUsage(decoded)
        let stored = try await database.usageRecords().first
        XCTAssertNil(stored?.tokens?.cachedInputTokens)
        XCTAssertNil(stored?.tokens?.cacheWriteInputTokens)
        var invalid = [record("negative", input: -1), record("overflow", input: Int64.max, output: Int64.max),
                       record("too-large", input: 1_000_000_000_000, output: 1)]
        var context = record("invalid-context"); context.contextLimit = 0; invalid.append(context)
        var changed = item; changed.provider = "other"; invalid.append(changed)
        var moved = item; moved.conversationID = UUID(); invalid.append(moved)
        for candidate in invalid {
            do { try await database.recordUsage(candidate); XCTFail("Invalid report accepted: \(candidate.id)") } catch { }
        }
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 1)
        XCTAssertEqual(summary.totals.tokens.totalTokens, 110)
        XCTAssertEqual(summary.providers.first?.label, "openai")
    }

    func testBoundedPagesAndBreakdownsPreserveFullTotalsAndOlderContextLookup() async throws {
        let chat = UUID()
        var context = record("context", at: Date(timeIntervalSince1970: 1_600_000_000), input: nil, chat: chat)
        context.contextTokens = 333
        try await database.recordUsage(context)
        try fixture("""
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<3662)
        INSERT INTO usage_records(id,recorded_at,provider,model,source,activity,conversation_id,input_tokens,output_tokens)
        SELECT printf('report-%05d',x),2000000000-x*86400,printf('provider-%03d',x%120),'model','api','review','\(chat.uuidString)',10,2 FROM n;
        """)
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 3663)
        XCTAssertEqual(summary.totals.tokens.totalTokens, 3662 * 12)
        XCTAssertEqual(summary.providers.count, 100)
        XCTAssertTrue(summary.breakdownsAreTruncated)
        XCTAssertEqual(summary.daily.count, 3660)
        XCTAssertTrue(summary.dailyIsTruncated)
        let first = try await database.usageRecords(limit: 10_000)
        let second = try await database.usageRecords(after: first.last, limit: 500)
        XCTAssertEqual(first.count, 500)
        XCTAssertEqual(second.count, 500)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        let latest = try await database.latestUsageContext(conversationID: chat)
        XCTAssertEqual(latest?.id, "context")
        XCTAssertEqual(latest?.contextTokens, 333)
    }

    func testFailedUpsertRollsBackAndRemainsUsable() async throws {
        let item = record("original", at: Date(timeIntervalSince1970: 2_000_000_000))
        try await database.recordUsage(item)
        try fixture("CREATE TRIGGER reject_usage BEFORE UPDATE ON usage_records BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
        var update = item; update.tokens = UsageTokens(inputTokens: 9_000, outputTokens: 800)
        do { try await database.recordUsage(update); XCTFail("Expected fixture failure") } catch { }
        try fixture("DROP TRIGGER reject_usage;")
        let saved = try await database.usageRecords().first
        XCTAssertEqual(saved, item)
        try await database.recordUsage(record("after"))
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 2)
    }

    func testUnicodeConnectionLabelsRoundTripAndEmbeddedNullsAreRejected() async throws {
        let item = record("unicode", provider: String(repeating: "名", count: 80), model: String(repeating: "模", count: 200))
        try await database.recordUsage(item)
        let saved = try await database.usageRecords().first
        XCTAssertEqual(saved?.provider, item.provider)
        XCTAssertEqual(saved?.model, item.model)
        let invalid = record("prefix\u{0}suffix")
        do { try await database.recordUsage(invalid); XCTFail("Embedded NULL accepted") } catch { }
        let backups = try await database.backupLibrary()
        try LibrarySnapshots.validate(try XCTUnwrap(backups.first))
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 1)
    }

    func testLatestChatInputSupersedesOlderContextAndSkipsAuxiliaryActivity() async throws {
        let chat = UUID(), start = Date(timeIntervalSince1970: 2_000_000_000)
        var old = record("older-context", at: start, chat: chat)
        old.contextTokens = 200; old.contextLimit = 10_000
        try await database.recordUsage(old)
        let latest = record("latest-chat", at: start.addingTimeInterval(1), input: 5_000, chat: chat)
        try await database.recordUsage(latest)
        var review = record("newer-review", at: start.addingTimeInterval(2), chat: chat)
        review.activity = "AI assistance"; review.contextTokens = 600; review.contextLimit = 20_000
        try await database.recordUsage(review)
        var title = record("newer-title", at: start.addingTimeInterval(3), chat: chat)
        title.activity = "Chat title"
        try await database.recordUsage(title)
        try await database.recordUsage(record("newer-unreported", at: start.addingTimeInterval(4), input: nil, chat: chat))
        let context = try await database.latestUsageContext(conversationID: chat)
        XCTAssertEqual(context?.id, latest.id)
        XCTAssertEqual(context?.tokens?.inputTokens, 5_000)
        XCTAssertNil(context?.contextTokens)
        XCTAssertNil(context?.contextLimit)
    }

    func testVersionSixMigrationIsAtomicAndDoesNotInventHistory() async throws {
        database = nil
        try fixture("DROP TABLE usage_records; DROP TABLE usage_tracking; DELETE FROM schema_migrations WHERE version=7; CREATE TABLE usage_tracking(conflict TEXT);")
        let failed = try DatabaseActor(url: url)
        do { _ = try await failed.usageSummary(); XCTFail("Expected migration failure") } catch { }
        // A partially created usage_records table would make the next migration fail.
        try fixture("DROP TABLE usage_tracking;")
        let reopened = try DatabaseActor(url: url)
        let summary = try await reopened.usageSummary()
        XCTAssertEqual(summary.totals.recordCount, 0)
        XCTAssertTrue(summary.daily.isEmpty)
        XCTAssertLessThan(abs(summary.trackingStartedAt.timeIntervalSinceNow), 30)
        try await reopened.recordUsage(record("after-migration"))
        let second = try DatabaseActor(url: url)
        let persisted = try await second.usageSummary()
        XCTAssertEqual(persisted.totals.recordCount, 1)
        XCTAssertEqual(persisted.trackingStartedAt, summary.trackingStartedAt)
    }

    func testBackupsSupportVersionsFiveSixSevenAndRejectFutureSchema() async throws {
        try await database.recordUsage(record("backed-up"))
        let backups = try await database.backupLibrary()
        let original = try XCTUnwrap(backups.first)
        try LibrarySnapshots.validate(original)
        let target = directory.appendingPathComponent("restored-seven.sqlite3")
        try LibrarySnapshots.stage(source: original, database: target)
        let restored = try DatabaseActor(url: target)
        let records = try await restored.usageRecords()
        XCTAssertEqual(records.map(\.id), ["backed-up"])
        for version in [6, 5] {
            let legacy = directory.appendingPathComponent("legacy-\(version).sqlite3")
            try LibrarySnapshots.copy(from: original, to: legacy)
            try fixture("DROP TABLE usage_records; DROP TABLE usage_tracking; DELETE FROM schema_migrations WHERE version=7;", at: legacy)
            if version == 5 {
                let triggers = ArchiveStorageSchema.triggers.keys.map { "DROP TRIGGER \($0);" }.joined(separator: "\n")
                try fixture("""
                \(triggers)
                DROP INDEX conversations_archive_page; DROP INDEX features_conversation; DROP INDEX attachments_conversation;
                ALTER TABLE conversations DROP COLUMN stored_bytes; DELETE FROM schema_migrations WHERE version=6;
                """, at: legacy)
            }
            try LibrarySnapshots.validate(legacy)
            let destination = directory.appendingPathComponent("restored-\(version).sqlite3")
            try LibrarySnapshots.stage(source: legacy, database: destination)
            let migrated = try DatabaseActor(url: destination)
            let summary = try await migrated.usageSummary()
            XCTAssertEqual(summary.totals.recordCount, 0)
        }
        try fixture("INSERT INTO schema_migrations(version,applied_at) VALUES(8,1)", at: original)
        XCTAssertThrowsError(try LibrarySnapshots.validate(original))
        let future = try DatabaseActor(url: original)
        do { _ = try await future.usageSummary(); XCTFail("Future version accepted") } catch { }
    }

    func testBackupRejectsOversizedAndMalformedUsageConversationIDs() async throws {
        try await database.recordUsage(record("backup-identity"))
        let backups = try await database.backupLibrary()
        let backup = try XCTUnwrap(backups.first)
        try fixture("UPDATE usage_records SET conversation_id=hex(zeroblob(65536));", at: backup)
        XCTAssertThrowsError(try LibrarySnapshots.validate(backup))
        try fixture("UPDATE usage_records SET conversation_id='ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ';", at: backup)
        XCTAssertThrowsError(try LibrarySnapshots.validate(backup))
        // A deleted chat's valid UUID is deliberately allowed without a matching chat row.
        try fixture("UPDATE usage_records SET conversation_id='\(UUID().uuidString)';", at: backup)
        try LibrarySnapshots.validate(backup)
    }
}

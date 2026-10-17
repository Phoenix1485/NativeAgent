import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class UsageControllerTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseActor!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("usage.sqlite3"))
    }
    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testCalendarRangesIncludeWholeLocalDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        var selection = UsageSelection(range: .today)
        let today = try selection.query(now: date, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(today.end).timeIntervalSince(try XCTUnwrap(today.start)), 23 * 3_600)
        selection.range = .week
        let week = try selection.query(now: date, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(week.start)), 2)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(week.end)), 9)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(week.start)), 0)
        selection.range = .custom; selection.customStart = date; selection.customEnd = date
        XCTAssertEqual(try selection.query(now: date, calendar: calendar), today)
        selection.customEnd = date.addingTimeInterval(-86_400)
        XCTAssertThrowsError(try selection.query(now: date, calendar: calendar))
        selection.range = .all
        XCTAssertNil(try selection.query(now: date, calendar: calendar).start)
        XCTAssertNil(try selection.query(now: date, calendar: calendar).end)
    }

    func testDateProviderModelFiltersAndCurrentChatAreIndependent() async throws {
        let chat = Conversation(title: "Selected chat")
        try await database.save(conversation: chat)
        let now = Date.now.addingTimeInterval(-60)
        for record in [
            UsageRecord(id: "included", recordedAt: now, provider: "Provider A", model: "model-a", source: "fixture", activity: "Chat", conversationID: chat.id, tokens: UsageTokens(inputTokens: 100, outputTokens: 20), contextTokens: 700, contextLimit: 4_000),
            UsageRecord(id: "other-provider", recordedAt: now, provider: "Provider B", model: "model-b", source: "fixture", activity: "review", conversationID: chat.id, tokens: UsageTokens(inputTokens: 200, outputTokens: 30)),
            UsageRecord(id: "unreported", recordedAt: now, provider: "Provider A", model: "model-a", source: "fixture", activity: "Chat", conversationID: chat.id),
            UsageRecord(id: "old", recordedAt: now.addingTimeInterval(-120 * 86_400), provider: "Provider A", model: "model-a", source: "fixture", activity: "Chat", tokens: UsageTokens(inputTokens: 9_000, outputTokens: 1_000))
        ] { try await database.recordUsage(record) }
        let controller = UsageController(database: database)
        controller.selection.range = .week
        controller.selection.provider = "Provider A"
        controller.selection.model = "model-a"
        await controller.load(conversationID: chat.id)
        XCTAssertEqual(controller.summary?.totals.tokens.totalTokens, 120)
        XCTAssertEqual(controller.summary?.totals.recordCount, 2)
        XCTAssertEqual(controller.summary?.totals.reportedCount, 1)
        XCTAssertEqual(controller.summary?.totals.missingCount, 1)
        XCTAssertNil(controller.summary?.totals.tokens.cachedInputTokens)
        XCTAssertEqual(Set(controller.recent.map(\.id)), ["included", "unreported"])
        XCTAssertEqual(controller.currentChat?.totals.tokens.totalTokens, 350)
        XCTAssertEqual(controller.context?.contextTokens, 700)
        XCTAssertEqual(controller.catalog?.totals.recordCount, 4)
        controller.selectProvider("Provider B")
        XCTAssertNil(controller.selection.model)
        XCTAssertEqual(controller.modelOptions.map(\.label), ["model-b"])
        controller.deactivate()
    }

    func testSupersededLoadCannotReplaceNewFiltersEvenWhenLoaderIgnoresCancellation() async throws {
        let gate = UsageReadGate()
        let entered = expectation(description: "Old query is suspended")
        let controller = UsageController(database: database, summaryLoader: { query in
            if query.provider == "Old" { await gate.pause(entered: entered) }
            return UsageSummary(totals: UsageAggregate(tokens: UsageTokens(inputTokens: query.provider == "New" ? 200 : 100, outputTokens: 0), recordCount: 1, reportedCount: 1))
        }, recordsLoader: { _, _, _ in [] }, contextLoader: { _ in nil })
        controller.selection.provider = "Old"
        let first = Task { await controller.load() }
        await fulfillment(of: [entered], timeout: 2)
        controller.selection.provider = "New"
        await controller.load()
        await gate.release()
        await first.value
        XCTAssertEqual(controller.summary?.totals.tokens.totalTokens, 200)
        XCTAssertFalse(controller.loading)
        XCTAssertNil(controller.notice)
        controller.deactivate()
    }

    func testRefreshIsLazyCoalescedAndStopsAfterSettingsClose() async throws {
        let reads = UsageReadCounter()
        let controller = UsageController(database: database, summaryLoader: { _ in
            await reads.increment(); return UsageSummary()
        }, recordsLoader: { _, _, _ in [] }, contextLoader: { _ in nil })
        controller.selection.range = .all
        await controller.refresh()
        let beforeOpen = await reads.count
        XCTAssertEqual(beforeOpen, 0)
        await controller.load()
        controller.captureFailed("Fixture save failed")
        for _ in 0..<10 { await controller.refresh() }
        try await Task.sleep(for: .milliseconds(400))
        let refreshed = await reads.count
        XCTAssertEqual(refreshed, 2)
        XCTAssertEqual(controller.captureError, "Fixture save failed")
        await controller.refresh()
        controller.deactivate()
        for _ in 0..<3 { await controller.refresh() }
        try await Task.sleep(for: .milliseconds(350))
        let closed = await reads.count
        XCTAssertEqual(closed, refreshed)
    }

    func testPaginationUsesStableCursorAndExportIncludesEveryMatchingRecord() async throws {
        let now = Date.now.addingTimeInterval(-60)
        for index in 0..<53 {
            try await database.recordUsage(UsageRecord(id: "record-\(index)", recordedAt: now, provider: "=UNTRUSTED()", model: "A, \"quoted\" model", source: "fixture", activity: "Chat",
                                                       tokens: index == 0 ? nil : UsageTokens(inputTokens: 10, outputTokens: 2)))
        }
        let controller = UsageController(database: database)
        controller.selection.range = .all
        await controller.load()
        XCTAssertEqual(controller.recent.count, 25)
        await controller.loadMore(); await controller.loadMore()
        XCTAssertEqual(controller.recent.count, 53)
        XCTAssertEqual(Set(controller.recent.map(\.id)).count, 53)
        XCTAssertFalse(controller.hasMore)
        let destination = directory.appendingPathComponent("export.csv")
        await controller.export(to: destination)
        let csv = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 55)
        XCTAssertTrue(csv.contains("\"'=UNTRUSTED()\""))
        XCTAssertTrue(csv.contains("\"A, \"\"quoted\"\" model\""))
        let missing = try XCTUnwrap(csv.components(separatedBy: "\r\n").first { $0.hasPrefix("\"record-0\"") })
        XCTAssertTrue(missing.contains("\"false\",\"\",\"\",\"\""), "Unreported tokens must remain empty, never zero")
        XCTAssertEqual(controller.exportNotice, "Exported 53 requests.")
        controller.deactivate()
    }

    func testCancelledExportPreservesExistingDestinationAndRemovesTemporaryFile() async throws {
        let gate = UsageReadGate()
        let entered = expectation(description: "Export read started")
        let controller = UsageController(database: database, recordsLoader: { _, _, _ in
            await gate.pause(entered: entered)
            return [UsageRecord(id: "record", provider: "fixture", model: "model", source: "fixture", activity: "Chat")]
        })
        let destination = directory.appendingPathComponent("existing.csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Existing export".utf8).write(to: destination)
        let task = Task { await controller.export(to: destination) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Existing export")
        XCTAssertEqual(controller.exportNotice, "Export canceled.")
        XCTAssertFalse(controller.exporting)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".nativeagent-usage-") })
    }
}

private actor UsageReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause(entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor UsageReadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

import Combine
import Foundation

/// Calendar-day ranges use an exclusive upper bound, including DST transitions.
enum UsageDateRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", quarter = "90 days", all = "All time", custom = "Custom"
    var id: String { rawValue }
}

struct UsageSelection: Hashable {
    var range: UsageDateRange = .month
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now
    var customEnd: Date = .now
    var provider = ""
    var model: String?

    func query(now: Date = .now, calendar: Calendar = .current) throws -> UsageQuery {
        let start: Date?, end: Date?
        switch range {
        case .all: start = nil; end = nil
        case .custom:
            start = calendar.startOfDay(for: customStart)
            guard calendar.startOfDay(for: customEnd) >= start! else { throw UsageDashboardError.invalidRange }
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))
        default:
            let days: Int = switch range { case .week: 7; case .month: 30; case .quarter: 90; default: 1 }
            let today = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: 1 - days, to: today)
            end = calendar.date(byAdding: .day, value: 1, to: today)
        }
        return UsageQuery(start: start, end: end, provider: provider.isEmpty ? nil : provider, model: model)
    }
}

enum UsageDashboardError: LocalizedError {
    case invalidRange
    var errorDescription: String? { "The end date must be on or after the start date." }
}

@MainActor
final class UsageController: ObservableObject {
    typealias SummaryLoader = @Sendable (UsageQuery) async throws -> UsageSummary
    typealias RecordsLoader = @Sendable (UsageQuery, UsageRecord?, Int) async throws -> [UsageRecord]
    typealias ContextLoader = @Sendable (UUID) async throws -> UsageRecord?

    @Published var selection = UsageSelection()
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var catalog: UsageSummary?
    @Published private(set) var recent: [UsageRecord] = []
    @Published private(set) var currentChat: UsageSummary?
    @Published private(set) var context: UsageRecord?
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var exporting = false
    @Published var notice: String?
    @Published var exportNotice: String?
    @Published private(set) var captureError: String?

    private let summaryLoader: SummaryLoader
    private let recordsLoader: RecordsLoader
    private let contextLoader: ContextLoader
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var conversationID: UUID?
    private var activeQuery: UsageQuery?
    private var activated = false
    private let pageSize = 25

    init(database: DatabaseActor, summaryLoader: SummaryLoader? = nil,
         recordsLoader: RecordsLoader? = nil, contextLoader: ContextLoader? = nil) {
        self.summaryLoader = summaryLoader ?? { try await database.usageSummary(query: $0) }
        self.recordsLoader = recordsLoader ?? { try await database.usageRecords(query: $0, after: $1, limit: $2) }
        self.contextLoader = contextLoader ?? { try await database.latestUsageContext(conversationID: $0) }
    }

    var modelOptions: [UsageBreakdown] {
        (catalog?.models ?? []).filter { selection.provider.isEmpty || $0.provider == selection.provider }
    }

    func selectProvider(_ provider: String) {
        selection.provider = provider
        selection.model = nil
    }

    func captureFailed(_ message: String) { captureError = message }

    /// New events refresh an already-open dashboard without loading history on app startup.
    func refresh() async {
        guard activated else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.activated, !Task.isCancelled else { return }
            await self.load(conversationID: self.conversationID)
        }
    }

    func deactivate() {
        activated = false
        refreshTask?.cancel()
        loadTask?.cancel()
        generation = UUID()
        loading = false
        loadingMore = false
    }

    func load(conversationID: UUID? = nil) async {
        activated = true
        let token = UUID()
        generation = token
        loadTask?.cancel()
        loadingMore = false
        if self.conversationID != conversationID { currentChat = nil; context = nil }
        self.conversationID = conversationID
        let query: UsageQuery
        do { query = try selection.query() }
        catch { summary = nil; recent = []; loading = false; hasMore = false; activeQuery = nil; notice = error.localizedDescription; return }
        let requestedCount = activeQuery == query ? min(500, max(pageSize, recent.count)) : pageSize
        if activeQuery != query { summary = nil; recent = []; hasMore = false }
        activeQuery = query
        loading = true
        notice = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.loading = false } }
            do {
                let totals = try await self.summaryLoader(query)
                try Task.checkCancellation()
                let all = query == UsageQuery() ? totals : try await self.summaryLoader(UsageQuery())
                let records = try await self.recordsLoader(query, nil, requestedCount)
                let chat: UsageSummary?
                let context: UsageRecord?
                if let conversationID {
                    chat = try await self.summaryLoader(UsageQuery(conversationID: conversationID))
                    context = try await self.contextLoader(conversationID)
                } else { chat = nil; context = nil }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.summary = totals; self.catalog = all; self.recent = records
                self.currentChat = chat; self.context = context
                self.hasMore = records.count == requestedCount && requestedCount < 500
            } catch is CancellationError { }
            catch { if self.generation == token { self.notice = error.localizedDescription } }
        }
        loadTask = task
        await task.value
    }

    func loadMore() async {
        guard !loading, !loadingMore, hasMore, recent.count < 500, let query = activeQuery, let cursor = recent.last else { return }
        let token = generation
        loadingMore = true
        defer { if generation == token { loadingMore = false } }
        do {
            let records = try await recordsLoader(query, cursor, pageSize)
            try Task.checkCancellation()
            guard generation == token else { return }
            let existing = Set(recent.map(\.id))
            recent += records.filter { !existing.contains($0.id) }
            hasMore = records.count == pageSize && recent.count < 500
        } catch is CancellationError { }
        catch { if generation == token { notice = error.localizedDescription } }
    }

    /// Streams bounded pages into a temporary sibling file; only a completed export replaces the destination.
    func export(to destination: URL) async {
        guard !exporting else { return }
        exporting = true; exportNotice = nil
        defer { exporting = false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nativeagent-usage-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            var query = try selection.query()
            // Hold the export's upper boundary stable while new requests arrive.
            query.end = min(query.end ?? .distantFuture, .now)
            _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(UsageCSV.header.utf8))
            var cursor: UsageRecord?
            var count = 0
            while true {
                try Task.checkCancellation()
                let rows = try await recordsLoader(query, cursor, 500)
                try Task.checkCancellation()
                guard !rows.isEmpty else { break }
                try handle.write(contentsOf: Data(rows.map(UsageCSV.row).joined().utf8))
                count += rows.count
                cursor = rows.last
                if rows.count < 500 { break }
                await Task.yield()
            }
            try handle.synchronize()
            try handle.close()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            exportNotice = "Exported \(count.formatted()) requests."
        } catch is CancellationError { exportNotice = "Export canceled." }
        catch { exportNotice = error.localizedDescription }
    }
}

enum UsageCSV {
    static let header = "request_id,recorded_at,provider,model,source,activity,conversation_id,usage_reported,input_tokens,output_tokens,total_tokens,cached_input_tokens,cache_write_input_tokens,reasoning_output_tokens,context_tokens,context_limit\r\n"

    static func row(_ record: UsageRecord) -> String {
        let tokens = record.tokens
        let fields = [record.id, record.recordedAt.ISO8601Format(), record.provider, record.model, record.source, record.activity,
                      record.conversationID?.uuidString ?? "", tokens == nil ? "false" : "true", number(tokens?.inputTokens),
                      number(tokens?.outputTokens), number(tokens?.totalTokens), number(tokens?.cachedInputTokens),
                      number(tokens?.cacheWriteInputTokens), number(tokens?.reasoningOutputTokens), number(record.contextTokens), number(record.contextLimit)]
        return fields.map(escape).joined(separator: ",") + "\r\n"
    }

    private static func number(_ value: Int64?) -> String { value.map(String.init) ?? "" }
    static func escape(_ value: String) -> String {
        // Provider/model labels can be user-defined. Prevent spreadsheet formula execution.
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let guarded = (first.map { "=+-@".contains($0) } ?? false) || value.first == "\t" || value.first == "\r"
        let safe = guarded ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

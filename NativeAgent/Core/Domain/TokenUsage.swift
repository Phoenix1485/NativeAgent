import Foundation

/// Provider-reported counts. Cache and reasoning counts are subsets, never added to totalTokens.
struct UsageTokens: Codable, Equatable, Sendable {
    var inputTokens: Int64
    var outputTokens: Int64
    var cachedInputTokens: Int64?
    var cacheWriteInputTokens: Int64?
    var reasoningOutputTokens: Int64?

    init(inputTokens: Int64, outputTokens: Int64, cachedInputTokens: Int64? = nil,
         cacheWriteInputTokens: Int64? = nil, reasoningOutputTokens: Int64? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        let input = max(0, inputTokens), output = max(0, outputTokens)
        func valid(_ value: Int64?, maximum: Int64) -> Int64? {
            value.flatMap { (0...maximum).contains($0) ? $0 : nil }
        }
        let cached = valid(cachedInputTokens, maximum: input)
        self.cachedInputTokens = cached
        self.cacheWriteInputTokens = valid(cacheWriteInputTokens, maximum: input - (cached ?? 0))
        self.reasoningOutputTokens = valid(reasoningOutputTokens, maximum: output)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, cacheWriteInputTokens, reasoningOutputTokens
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputTokens: try values.decode(Int64.self, forKey: .inputTokens),
                  outputTokens: try values.decode(Int64.self, forKey: .outputTokens),
                  cachedInputTokens: try values.decodeIfPresent(Int64.self, forKey: .cachedInputTokens),
                  cacheWriteInputTokens: try values.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens),
                  reasoningOutputTokens: try values.decodeIfPresent(Int64.self, forKey: .reasoningOutputTokens))
    }

    var totalTokens: Int64 {
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        return sum.overflow ? Int64.max : sum.partialValue
    }
}

struct UsageRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var recordedAt: Date
    var provider: String
    var model: String
    var source: String
    var activity: String
    var conversationID: UUID?
    /// nil means the provider did not report usage, distinct from a reported zero.
    var tokens: UsageTokens?
    var contextTokens: Int64?
    var contextLimit: Int64?

    init(id: String, recordedAt: Date = .now, provider: String, model: String, source: String,
         activity: String, conversationID: UUID? = nil, tokens: UsageTokens? = nil,
         contextTokens: Int64? = nil, contextLimit: Int64? = nil) {
        self.id = id; self.recordedAt = recordedAt; self.provider = provider; self.model = model
        self.source = source; self.activity = activity; self.conversationID = conversationID
        self.tokens = tokens; self.contextTokens = contextTokens; self.contextLimit = contextLimit
    }
}

struct UsageQuery: Hashable, Sendable {
    var start: Date? = nil
    var end: Date? = nil
    var provider: String? = nil
    var model: String? = nil
    var conversationID: UUID? = nil
}

struct UsageAggregate: Equatable, Sendable {
    var tokens = UsageTokens(inputTokens: 0, outputTokens: 0)
    var recordCount = 0
    var reportedCount = 0
    var missingCount: Int { recordCount - reportedCount }
}

struct UsageDailyTotal: Identifiable, Equatable, Sendable {
    /// SQLite local calendar day, YYYY-MM-DD. Missing days have no records, not inferred usage.
    var day: String
    var aggregate: UsageAggregate
    var id: String { day }
}

struct UsageBreakdown: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var provider: String?
    var aggregate: UsageAggregate
}

struct UsageSummary: Sendable {
    var totals = UsageAggregate()
    var daily: [UsageDailyTotal] = []
    var providers: [UsageBreakdown] = []
    var models: [UsageBreakdown] = []
    var activities: [UsageBreakdown] = []
    var conversations: [UsageBreakdown] = []
    var trackingStartedAt: Date = .now
    var dailyIsTruncated = false
    var breakdownsAreTruncated = false
}

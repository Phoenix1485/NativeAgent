import Foundation
import XCTest
@testable import NativeAgent

actor TokenReportRecorder {
    private(set) var reports: [ProviderTokenUsage] = []
    func append(_ report: ProviderTokenUsage) { reports.append(report) }
}

final class TokenUsageParserTests: XCTestCase {
    private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }
    private func update(_ input: Int64, _ output: Int64, turn: String = "turn", thread: String = "thread") -> JSONValue {
        .object(["threadId": .string(thread), "turnId": .string(turn), "tokenUsage": .object([
            "total": .object(["inputTokens": .number(Double(input)), "outputTokens": .number(Double(output)), "cachedInputTokens": .number(Double(input / 2)), "reasoningOutputTokens": .number(Double(output / 2))]),
            "last": .object(["totalTokens": .number(42)]), "modelContextWindow": .number(200_000)
        ])])
    }
    func testResponseSubsetsDoNotDoubleCountConsumption() throws {
        let usage = try json(#"{"input_tokens":100,"output_tokens":40,"input_tokens_details":{"cached_tokens":60,"cache_write_tokens":10},"output_tokens_details":{"reasoning_tokens":30}}"#)
        let tokens = try XCTUnwrap(TokenUsageParser.responses(usage))
        XCTAssertEqual(tokens.totalTokens, 140)
        XCTAssertEqual(tokens.cachedInputTokens, 60)
        XCTAssertEqual(tokens.cacheWriteInputTokens, 10)
        XCTAssertEqual(tokens.reasoningOutputTokens, 30)
    }
    func testReportedZeroIsDifferentFromMissingOrInvalidUsage() throws {
        XCTAssertEqual(TokenUsageParser.responses(try json(#"{"input_tokens":0,"output_tokens":0}"#))?.totalTokens, 0)
        for source in ["null", "{}", #"{"input_tokens":20}"#, #"{"input_tokens":true,"output_tokens":0}"#,
                       #"{"input_tokens":-1,"output_tokens":0}"#, #"{"input_tokens":1.5,"output_tokens":0}"#,
                       #"{"input_tokens":"12","output_tokens":0}"#, #"{"input_tokens":1000000000000,"output_tokens":1}"#] {
            XCTAssertNil(TokenUsageParser.responses(try json(source)), source)
        }
        XCTAssertNil(TokenUsageParser.count(.number(.infinity)))
        XCTAssertNil(TokenUsageParser.count(.number(.nan)))
    }
    func testAnthropicAddsSeparateCacheBucketsButOpenAIAlreadyIncludesThem() throws {
        let anthropic = try json(#"{"id":"msg_1","model":"actual","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":70,"cache_creation_input_tokens":20}}"#)
        let report = TokenUsageParser.api(anthropic, format: .anthropic, requestID: "fallback", model: "requested")
        XCTAssertEqual(report.id, "msg_1"); XCTAssertEqual(report.model, "actual")
        XCTAssertEqual(report.tokens?.inputTokens, 100); XCTAssertEqual(report.tokens?.totalTokens, 105)
        XCTAssertEqual(report.tokens?.cachedInputTokens, 70); XCTAssertEqual(report.tokens?.cacheWriteInputTokens, 20)
        let openAI = try json(#"{"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":70},"completion_tokens_details":{"reasoning_tokens":2}}}"#)
        let compatible = TokenUsageParser.api(openAI, format: .openAI, requestID: "fallback", model: "requested")
        XCTAssertEqual(compatible.id, "fallback"); XCTAssertEqual(compatible.model, "requested")
        XCTAssertEqual(compatible.tokens?.totalTokens, 105); XCTAssertEqual(compatible.tokens?.reasoningOutputTokens, 2)
        let invalid = try json(#"{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":-1}}"#)
        XCTAssertNil(TokenUsageParser.api(invalid, format: .anthropic, requestID: "id", model: "model").tokens)
    }
    func testEveryResponseTerminalCapturesUsageAndSuppressesUnknownFallback() throws {
        for terminal in ["response.completed", "response.failed", "response.incomplete"] {
            var tracker = ResponseUsageTracker(requestID: "local", turnID: "turn", threadID: "thread", model: "requested")
            XCTAssertNil(try tracker.consume(#"{"type":"response.created","response":{"id":"resp_1","model":"actual"}}"#))
            let report = try XCTUnwrap(tracker.consume("{\"type\":\"\(terminal)\",\"response\":{\"usage\":{\"input_tokens\":30,\"output_tokens\":2}}}"))
            XCTAssertEqual(report.id, "resp_1"); XCTAssertEqual(report.turnID, "turn"); XCTAssertEqual(report.threadID, "thread")
            XCTAssertEqual(report.model, "actual"); XCTAssertEqual(report.tokens?.totalTokens, 32)
            XCTAssertNil(tracker.finish())
        }
    }
    func testMissingTerminalOrMissingUsageEmitsOneUnavailableRequest() throws {
        var first = ResponseUsageTracker(model: "model"), second = ResponseUsageTracker(model: "model")
        let a = try XCTUnwrap(first.finish()), b = try XCTUnwrap(second.finish())
        XCTAssertNotEqual(a.id, b.id); XCTAssertNil(a.tokens); XCTAssertNil(first.finish())
        var tracker = ResponseUsageTracker(requestID: "local", model: "model")
        let report = try XCTUnwrap(tracker.consume(#"{"type":"response.incomplete","response":{"id":"resp_incomplete","usage":null}}"#))
        XCTAssertEqual(report.id, "resp_incomplete"); XCTAssertNil(report.tokens); XCTAssertNil(tracker.finish())
    }
    func testACPUsageIsContextOccupancyAndNeverLifetimeConsumption() throws {
        let report = TokenUsageParser.acpContext(try json(#"{"used":4500,"size":128000,"cost":{"amount":0.05,"currency":"USD"}}"#), threadID: "session", turnID: "turn", model: "grok")
        XCTAssertNil(report.tokens); XCTAssertEqual(report.contextTokens, 4500); XCTAssertEqual(report.contextLimit, 128000)
        XCTAssertEqual(report.id, "grok/session/turn")
        XCTAssertNil(TokenUsageParser.contextLimit(.number(0)))
        XCTAssertEqual(TokenUsageParser.count(.number(0)), 0, "Zero context use remains a valid reported value")
    }
    func testNewCodexThreadReportsReplaceSameTurnAndNextTurnUsesDelta() throws {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: true)
        tracker.prepare(model: "model"); XCTAssertTrue(tracker.activate(turnID: "turn").isEmpty)
        let first = try XCTUnwrap(tracker.consume(update(100, 20)))
        let second = try XCTUnwrap(tracker.consume(update(150, 30)))
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(first.tokens?.totalTokens, 120); XCTAssertEqual(second.tokens?.totalTokens, 180)
        XCTAssertEqual(second.contextTokens, 42); XCTAssertEqual(second.contextLimit, 200000)
        XCTAssertNil(tracker.finish(turnID: "turn"))
        tracker.prepare(model: "other"); _ = tracker.activate(turnID: "next")
        let next = try XCTUnwrap(tracker.consume(update(170, 34, turn: "next")))
        XCTAssertEqual(next.tokens?.inputTokens, 20); XCTAssertEqual(next.tokens?.outputTokens, 4)
        XCTAssertNotEqual(next.id, first.id); XCTAssertEqual(next.model, "other")
    }
    func testResumedHistoryBecomesBaselineAndCannotBeChargedAgain() throws {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: false)
        XCTAssertTrue(tracker.needsBaseline)
        XCTAssertNil(tracker.consume(update(5000, 1000, turn: "old")))
        XCTAssertFalse(tracker.needsBaseline)
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "turn")
        XCTAssertNil(tracker.consume(update(5100, 1010, turn: "other")))
        XCTAssertNil(tracker.consume(update(100, 20, thread: "unrelated")))
        let report = try XCTUnwrap(tracker.consume(update(5120, 1015)))
        XCTAssertEqual(report.tokens?.totalTokens, 135)
    }
    func testResumedThreadWithoutBaselineDoesNotGuessFirstTurn() throws {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: false)
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "turn")
        let first = try XCTUnwrap(tracker.consume(update(50_000, 10_000)))
        XCTAssertNil(first.tokens); XCTAssertEqual(first.contextTokens, 42)
        _ = tracker.finish(turnID: "turn")
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "next")
        XCTAssertEqual(tracker.consume(update(50_100, 10_020, turn: "next"))?.tokens?.totalTokens, 120)
    }
    func testReadBaselineAndUpdatesArrivingBeforeTurnStartResponse() throws {
        var tracker = CodexTurnUsageTracker()
        let response: JSONValue = .object(["thread": .object(["tokenUsage": update(100, 20)["tokenUsage"]!])])
        tracker.reset(threadID: "thread", newThread: false, response: response)
        tracker.prepare(model: "model")
        XCTAssertNil(tracker.consume(update(200, 40, turn: "history")))
        XCTAssertNil(tracker.consume(update(220, 45)))
        let reports = tracker.activate(turnID: "turn")
        XCTAssertEqual(reports.count, 1); XCTAssertEqual(reports.first?.tokens?.totalTokens, 25)
    }
    func testMissingPriorTurnAndCounterResetInvalidateDelta() throws {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: true)
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "turn")
        XCTAssertNil(tracker.finish(turnID: "wrong"))
        let missing = try XCTUnwrap(tracker.finish(turnID: "turn"))
        XCTAssertNil(missing.tokens); XCTAssertTrue(tracker.needsBaseline)
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "next")
        XCTAssertNil(tracker.consume(update(5000, 500, turn: "next"))?.tokens)
        _ = tracker.finish(turnID: "next")
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "reset")
        XCTAssertNil(tracker.consume(update(10, 2, turn: "reset"))?.tokens)
        XCTAssertNil(tracker.consume(update(5010, 502, turn: "reset"))?.tokens, "A reset cannot later become a huge delta")
    }
    func testDroppedStartupUpdatesNeverInventCompleteTurnConsumption() {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: true); tracker.prepare(model: "model")
        for number in 1...257 { _ = tracker.consume(update(Int64(number), 0)) }
        let reports = tracker.activate(turnID: "turn")
        XCTAssertEqual(reports.count, 256); XCTAssertTrue(reports.allSatisfy { $0.tokens == nil })
    }
    func testDelayedOlderHistoryCannotLowerNextTurnBaseline() {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: true); tracker.prepare(model: "model"); _ = tracker.activate(turnID: "turn")
        _ = tracker.consume(update(100, 20)); _ = tracker.finish(turnID: "turn")
        _ = tracker.consume(update(50, 10, turn: "old"))
        tracker.prepare(model: "model")
        _ = tracker.consume(update(40, 8, turn: "older"))
        _ = tracker.activate(turnID: "next")
        XCTAssertEqual(tracker.consume(update(130, 25, turn: "next"))?.tokens?.totalTokens, 35)
    }
    func testReadSnapshotCannotReplaceNewerResumeNotificationBaseline() {
        var tracker = CodexTurnUsageTracker()
        tracker.reset(threadID: "thread", newThread: false)
        _ = tracker.consume(update(100, 20, turn: "old"))
        tracker.captureBaseline(.object(["thread": .object(["tokenUsage": update(50, 10)["tokenUsage"]!])]))
        tracker.prepare(model: "model"); _ = tracker.activate(turnID: "turn")
        XCTAssertEqual(tracker.consume(update(130, 25))?.tokens?.totalTokens, 35)
    }
}

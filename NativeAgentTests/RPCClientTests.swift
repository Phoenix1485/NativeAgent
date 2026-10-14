import Foundation
import XCTest
@testable import NativeAgent

private actor DataRecorder {
    private var values: [Data] = []
    func append(_ data: Data) { values.append(data) }
    func snapshot() -> [Data] { values }
}

final class RPCClientTests: XCTestCase {
    func testOutOfOrderResponsesMatchTheirRequests() async throws {
        let recorder = DataRecorder()
        let client = RPCClient { data in await recorder.append(data) }
        let first = Task { try await client.request(method: "first", timeout: .seconds(2)) }
        let second = Task { try await client.request(method: "second", timeout: .seconds(2)) }
        let requests = await waitForWrites(2, recorder: recorder)
        let decoded = try requests.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.dropLast())) }
        let idsByMethod = Dictionary(uniqueKeysWithValues: decoded.compactMap { value -> (String, Int)? in
            guard let method = value["method"]?.stringValue, let id = value["id"]?.intValue else { return nil }
            return (method, id)
        })
        let responses = "{\"id\":\(idsByMethod["second"]!),\"result\":\"two\"}\n{\"id\":\(idsByMethod["first"]!),\"result\":\"one\"}\n"
        await client.consume(AsyncStream { continuation in
            continuation.yield(Data(responses.utf8)); continuation.finish()
        })
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, .string("one"))
        XCTAssertEqual(secondValue, .string("two"))
    }

    func testTimeoutDoesNotRetryRequest() async throws {
        let recorder = DataRecorder()
        let client = RPCClient { data in await recorder.append(data) }
        do {
            _ = try await client.request(method: "slow", timeout: .milliseconds(20))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? NativeAgentError, .requestTimedOut)
        }
        let writeCount = await recorder.snapshot().count
        XCTAssertEqual(writeCount, 1)
    }

    func testServerRequestIsNotMisclassifiedAsNotification() async throws {
        let client = RPCClient { _ in }
        let requests = await client.serverRequests
        let waiter = Task { await requests.first(where: { _ in true }) }
        await client.consume(AsyncStream { continuation in
            continuation.yield(Data("{\"id\":\"approval-1\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{}}\n".utf8))
            continuation.finish()
        })
        let request = await waiter.value
        XCTAssertEqual(request?.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(request?.id, .string("approval-1"))
    }

    func testEOFImmediatelyFailsPendingRequestsAndRejectsNewOnes() async throws {
        let recorder = DataRecorder()
        let client = RPCClient { data in await recorder.append(data) }
        let pending = Task { try await client.request(method: "account/read", timeout: .seconds(60)) }
        _ = await waitForWrites(1, recorder: recorder)
        await client.consume(AsyncStream { $0.finish() })
        do { _ = try await pending.value; XCTFail("EOF returned success") } catch {}
        do { _ = try await client.request(method: "after-close"); XCTFail("Closed client accepted request") } catch {}
    }

    private func waitForWrites(_ count: Int, recorder: DataRecorder) async -> [Data] {
        for _ in 0..<1_000 {
            let values = await recorder.snapshot()
            if values.count >= count { return values }
            await Task.yield()
        }
        return await recorder.snapshot()
    }
}

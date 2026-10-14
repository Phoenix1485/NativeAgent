import Foundation
import XCTest
@testable import NativeAgent

final class JSONLineFramerTests: XCTestCase {
    func testSplitAndMultipleFrames() throws {
        var framer = JSONLineFramer(maximumFrameSize: 100, maximumBufferSize: 200)
        XCTAssertTrue(try framer.append(Data("{\"a\":\"".utf8)).isEmpty)
        let frames = try framer.append(Data("é\"}\n{\"b\":2}\r\n".utf8))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(String(decoding: frames[0], as: UTF8.self), "{\"a\":\"é\"}")
        XCTAssertEqual(String(decoding: frames[1], as: UTF8.self), "{\"b\":2}")
        XCTAssertNoThrow(try framer.finish())
    }

    func testOversizedFrameIsRejected() throws {
        var framer = JSONLineFramer(maximumFrameSize: 4, maximumBufferSize: 20)
        XCTAssertThrowsError(try framer.append(Data("12345\n".utf8))) { error in
            XCTAssertEqual(error as? NativeAgentError, .frameTooLarge(limit: 4))
        }
    }

    func testBufferOverflowIsRejectedAndCleared() throws {
        var framer = JSONLineFramer(maximumFrameSize: 10, maximumBufferSize: 5)
        XCTAssertThrowsError(try framer.append(Data("123456".utf8)))
        XCTAssertNoThrow(try framer.finish())
    }

    func testIncompleteFrameFailsAtEOF() throws {
        var framer = JSONLineFramer()
        _ = try framer.append(Data("{}".utf8))
        XCTAssertThrowsError(try framer.finish())
    }
}

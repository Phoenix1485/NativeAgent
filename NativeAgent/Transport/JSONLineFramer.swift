import Foundation

struct JSONLineFramer: Sendable {
    let maximumFrameSize: Int
    let maximumBufferSize: Int
    private(set) var buffer = Data()

    init(maximumFrameSize: Int = 16 * 1_024 * 1_024, maximumBufferSize: Int = 32 * 1_024 * 1_024) {
        self.maximumFrameSize = maximumFrameSize
        self.maximumBufferSize = maximumBufferSize
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= maximumBufferSize else {
            buffer.removeAll(keepingCapacity: false)
            throw NativeAgentError.bufferOverflow(limit: maximumBufferSize)
        }
        buffer.append(bytes)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var frame = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if frame.last == 0x0D { frame = frame.dropLast() }
            if frame.isEmpty { continue }
            guard frame.count <= maximumFrameSize else {
                throw NativeAgentError.frameTooLarge(limit: maximumFrameSize)
            }
            frames.append(Data(frame))
        }
        guard buffer.count <= maximumFrameSize else {
            buffer.removeAll(keepingCapacity: false)
            throw NativeAgentError.frameTooLarge(limit: maximumFrameSize)
        }
        return frames
    }

    mutating func finish() throws {
        guard buffer.isEmpty else { throw NativeAgentError.protocolError("Provider closed with an incomplete JSON frame") }
    }
}

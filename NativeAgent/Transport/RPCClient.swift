import Foundation

struct RPCNotification: Sendable {
    let method: String
    let params: JSONValue?
}

struct RPCServerRequest: Sendable {
    let id: JSONValue
    let method: String
    let params: JSONValue?
}

actor RPCClient {
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    private let writer: @Sendable (Data) async throws -> Void
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var framer = JSONLineFramer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let jsonRPCVersion: Bool
    private var closed = false
    private var notificationContinuation: AsyncStream<RPCNotification>.Continuation?
    private var requestContinuation: AsyncStream<RPCServerRequest>.Continuation?

    let notifications: AsyncStream<RPCNotification>
    let serverRequests: AsyncStream<RPCServerRequest>

    init(transport: ProcessTransport, jsonRPCVersion: Bool = false) {
        self.jsonRPCVersion = jsonRPCVersion
        self.writer = { data in try await transport.write(data) }
        var notificationContinuation: AsyncStream<RPCNotification>.Continuation?
        notifications = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { notificationContinuation = $0 }
        self.notificationContinuation = notificationContinuation
        var requestContinuation: AsyncStream<RPCServerRequest>.Continuation?
        serverRequests = AsyncStream(bufferingPolicy: .bufferingOldest(32)) { requestContinuation = $0 }
        self.requestContinuation = requestContinuation
    }

    init(jsonRPCVersion: Bool = false, writer: @escaping @Sendable (Data) async throws -> Void) {
        self.jsonRPCVersion = jsonRPCVersion
        self.writer = writer
        var notificationContinuation: AsyncStream<RPCNotification>.Continuation?
        notifications = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { notificationContinuation = $0 }
        self.notificationContinuation = notificationContinuation
        var requestContinuation: AsyncStream<RPCServerRequest>.Continuation?
        serverRequests = AsyncStream(bufferingPolicy: .bufferingOldest(32)) { requestContinuation = $0 }
        self.requestContinuation = requestContinuation
    }

    func consume(_ stream: AsyncStream<Data>) async {
        do {
            for await chunk in stream {
                for frame in try framer.append(chunk) {
                    try handle(frame)
                    await Task.yield()
                }
            }
            try framer.finish()
            close()
        } catch {
            close(with: error)
        }
    }

    func request(method: String, params: JSONValue? = nil, timeout: Duration = .seconds(15)) async throws -> JSONValue {
        guard !closed else { throw NativeAgentError.providerUnavailable("Provider connection closed. Reconnect to continue.") }
        guard pending.count < 64 else { throw NativeAgentError.protocolError("Too many pending provider requests") }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.timeOut(id)
            }
            pending[id] = Pending(continuation: continuation, timeout: timeoutTask)
            Task {
                do {
                    try await send(.object([
                    "id": .number(Double(id)),
                    "method": .string(method),
                    "params": params ?? .object([:])
                    ]))
                } catch {
                    failRequest(id, with: error)
                }
            }
        }
    }

    func notify(method: String, params: JSONValue? = nil) async throws {
        try await send(.object([
            "method": .string(method),
            "params": params ?? .object([:])
        ]))
    }

    func reply(to id: JSONValue, result: JSONValue) async throws {
        try await send(.object(["id": id, "result": result]))
    }

    func reply(to id: JSONValue, errorCode: Int, message: String) async throws {
        try await send(.object([
            "id": id,
            "error": .object(["code": .number(Double(errorCode)), "message": .string(message)])
        ]))
    }

    func close(with error: Error = NativeAgentError.providerUnavailable("Provider connection closed.")) {
        closed = true
        failAll(with: error)
        notificationContinuation?.finish()
        requestContinuation?.finish()
    }

    private func send(_ value: JSONValue) async throws {
        var envelope = value
        if jsonRPCVersion, case .object(var object) = value { object["jsonrpc"] = .string("2.0"); envelope = .object(object) }
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        try await writer(data)
    }

    private func handle(_ data: Data) throws {
        let envelope = try decoder.decode(RPCEnvelope.self, from: data)
        if let id = envelope.id, envelope.method != nil {
            if case .dropped = requestContinuation?.yield(RPCServerRequest(id: id, method: envelope.method!, params: envelope.params)) {
                throw NativeAgentError.protocolError("Provider request queue overflow. Reconnect to continue.")
            }
            return
        }
        if let method = envelope.method {
            if case .dropped = notificationContinuation?.yield(RPCNotification(method: method, params: envelope.params)) {
                throw NativeAgentError.protocolError("Provider notification queue overflow. Reconnect to continue.")
            }
            return
        }
        guard let id = envelope.id, let numericID = id.intValue else {
            throw NativeAgentError.protocolError("Response has no recognized request id")
        }
        guard let request = pending.removeValue(forKey: numericID) else { return }
        request.timeout.cancel()
        if let error = envelope.error {
            request.continuation.resume(throwing: NativeAgentError.protocolError("\(error.code): \(error.message)"))
        } else {
            request.continuation.resume(returning: envelope.result ?? .null)
        }
    }

    private func timeOut(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: NativeAgentError.requestTimedOut)
    }

    private func failRequest(_ id: Int, with error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAll(with error: Error) {
        let active = pending.values
        pending.removeAll()
        active.forEach {
            $0.timeout.cancel()
            $0.continuation.resume(throwing: error)
        }
    }
}

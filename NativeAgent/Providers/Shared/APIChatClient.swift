import Foundation

/// No tools, automatic retries, redirects, cookies, or shared credential storage.
final class APIChatClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func request(connection: AIConnection, token: String, instructions: String, prompt: String) throws -> URLRequest {
        let connection = try connection.validated()
        let url = URL(string: connection.baseURL)!.appendingPathComponent(connection.format == .anthropic ? "messages" : "chat/completions")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": connection.model, "stream": false]
        if connection.format == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = 4096
            body["system"] = instructions
            body["messages"] = [["role": "user", "content": prompt]]
        } else {
            body["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": prompt]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func answer(data: Data, status: Int, format: AIWireFormat) throws -> String {
        guard (200..<300).contains(status) else {
            // Never reflect server bodies: a malicious endpoint could echo credentials.
            let reason = switch status {
            case 401, 403: "Check the token and model access."
            case 429: "Usage or rate limit reached. No automatic retry was made."
            case 300..<400: "Redirects are blocked to protect your token. Check the API base URL."
            default: "Check the provider status, API format, and model ID."
            }
            throw NativeAgentError.providerUnavailable("API request failed (HTTP \(status)). \(reason)")
        }
        guard data.count <= 4_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeAgentError.protocolError("Invalid or oversized API response.")
        }
        let text: String?
        if format == .anthropic {
            text = (object["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeAgentError.protocolError("The provider returned no text answer. This connection supports text chat only.")
        }
        guard text.count <= 100_000 else { throw NativeAgentError.protocolError("The answer exceeded the 100,000-character review limit.") }
        return text
    }

    func complete(connection: AIConnection, token: String, instructions: String, prompt: String, usage: ProviderTokenUsageCallback? = nil) async throws -> String {
        let request = try Self.request(connection: connection, token: token, instructions: instructions, prompt: prompt)
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let requestID = UUID().uuidString
        var reported = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return try Self.answer(data: Data(), status: status, format: connection.format) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4_000_000 else { throw NativeAgentError.protocolError("API response exceeds the 4 MB limit.") }
                data.append(byte)
            }
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            await usage?(TokenUsageParser.api(payload, format: connection.format, requestID: requestID, model: connection.model))
            reported = true
            return try Self.answer(data: data, status: status, format: connection.format)
        } catch {
            if !reported { await usage?(.init(id: requestID, model: connection.model)) }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? NativeAgentError { throw error }
            throw NativeAgentError.providerUnavailable("API connection failed. Check the endpoint and network. No automatic retry was made.")
        }
    }
}

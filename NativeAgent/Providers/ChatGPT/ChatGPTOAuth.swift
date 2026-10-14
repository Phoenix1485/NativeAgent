import CryptoKit
import Foundation
import Network
import Security

enum ChatGPTAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func failure(_ message: String) -> NativeAgentError { .providerUnavailable(message) }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Could not prepare secure browser sign-in.") }
        return Data(bytes).base64URL
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

extension Data {
    fileprivate var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    fileprivate init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

struct ChatGPTAuthorizationAttempt: Sendable {
    let state: String
    let nonce: String
    let verifier: String
    let redirect: URL
    let registration: ChatGPTRegistration?
    let createdAt: Date
    init(redirect: URL, registration: ChatGPTRegistration?, now: Date = .now) throws {
        self.redirect = redirect; self.registration = registration; createdAt = now
        state = try ChatGPTAuth.random(); nonce = try ChatGPTAuth.random(); verifier = try ChatGPTAuth.random()
    }
    func authorizationURL(hostID: String) throws -> URL {
        guard ChatGPTHostID.isValid(hostID) else {
            throw ChatGPTAuth.failure("ChatGPT authorization requires a valid urn:uuid: host identifier.")
        }
        var url = URLComponents(string: ChatGPTAuth.issuer + "/api/accounts/authorize")!
        var values = ["client_id": registration?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": ChatGPTAuth.scope,
            "resource": ChatGPTAuth.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if let registration {
            values["id_token_hint"] = registration.tokens?.idToken
            values["login_hint"] = registration.email
        } else { values["agent_name_hint"] = "NativeAgent" }
        url.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return url.url!
    }
    func validateCallback(_ url: URL, now: Date = .now) throws -> (code: String, clientID: String) {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 300,
              url.scheme == redirect.scheme, url.host == "127.0.0.1", url.port == redirect.port,
              url.path == "/auth/callback", url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ChatGPTAuth.failure("The sign-in callback is invalid or expired. Start again.")
        }
        guard Set(items.map(\.name)).count == items.count else { throw ChatGPTAuth.failure("The sign-in callback contained duplicate parameters.") }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw ChatGPTAuth.failure("The browser sign-in state did not match. Start again.") }
        if values["error"] != nil { throw ChatGPTAuth.failure("ChatGPT authorization was declined or could not be completed. No account was connected.") }
        guard let code = values["code"], !code.isEmpty,
              let clientID = values["client_id"] ?? registration?.clientID,
              clientID.hasPrefix("oaiapp_"), clientID.count <= 256,
              registration == nil || registration?.clientID == clientID else {
            throw ChatGPTAuth.failure("ChatGPT did not return the expected app registration. Start sign-in again.")
        }
        return (code, clientID)
    }
}

/// No cookies, disk cache, redirects, subprocesses, or secret-bearing diagnostics.
final class ChatGPTHTTP: @unchecked Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func json(_ url: URL, form: [String: String]? = nil, token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form { request.httpMethod = "POST"; request.httpBody = ChatGPTAuth.form(form); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ChatGPTHTTPError(status: status) }
        if data.isEmpty { return [:] }
        guard data.count <= 4_194_304, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuth.failure("ChatGPT returned an invalid response.")
        }
        return object
    }
}

struct ChatGPTHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403: "ChatGPT did not authorize this connection. Sign in again and approve plan access."
        case 429: "ChatGPT reported a usage or request limit. Try again later; no API billing fallback was used."
        default: "ChatGPT could not complete the request (HTTP \(status)). Retry sign-in if authorization has expired."
        }
    }
}

enum ChatGPTIdentityValidator {
    static func validate(_ token: String, jwks: [String: Any], clientID: String, nonce: String?, now: Date = .now) throws -> (subject: String, email: String?) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let kid = header["kid"] as? String, let algorithm = header["alg"] as? String,
              header["crit"] == nil,
              let keys = jwks["keys"] as? [[String: Any]],
              let key = keys.first(where: { ($0["kid"] as? String) == kid }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == algorithm else { throw invalid }
        let message = Data((parts[0] + "." + parts[1]).utf8)
        let validSignature: Bool
        switch algorithm {
        case "RS256":
            guard key["kty"] as? String == "RSA", let n = key["n"] as? String, let e = key["e"] as? String,
                  let modulus = Data(base64URL: n), modulus.count >= 256, let exponent = Data(base64URL: e) else { throw invalid }
            let der = field(0x30, field(0x02, integer(modulus)) + field(0x02, integer(exponent)))
            guard let publicKey = SecKeyCreateWithData(der as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { throw invalid }
            validSignature = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
        case "ES256":
            guard key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let y = key["y"] as? String,
                  let xData = Data(base64URL: x), xData.count == 32, let yData = Data(base64URL: y), yData.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + xData + yData),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { throw invalid }
            validSignature = publicKey.isValidSignature(sig, for: message)
        default: throw invalid
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        let timestamp = now.timeIntervalSince1970
        guard validSignature, claims["iss"] as? String == ChatGPTAuth.issuer,
              audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              let expiry = claims["exp"] as? Double, expiry > timestamp - 5,
              let issued = claims["iat"] as? Double, issued <= timestamp + 5,
              (claims["nbf"] as? Double ?? 0) <= timestamp + 5,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              nonce == nil || claims["nonce"] as? String == nonce else { throw invalid }
        return (subject, claims["email"] as? String)
    }
    private static var invalid: NativeAgentError { ChatGPTAuth.failure("ChatGPT’s identity token could not be verified. No account was connected.") }
    private static func integer(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        return (bytes.first ?? 0) & 0x80 != 0 ? Data([0]) + bytes : bytes
    }
    private static func field(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count
        var encoded: [UInt8] = []
        repeat { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return Data([tag]) + (data.count < 128 ? Data([UInt8(data.count)]) : Data([0x80 | UInt8(encoded.count)] + encoded)) + data
    }
}

/// Listener exists only during an explicit sign-in, bound to IPv4 loopback, never the LAN.
final class ChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nativeagent.oauth-loopback")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var pending: URL?
    private var stopped = false
    private var port: UInt16 = 0
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port?.rawValue else { return }
                            self.port = port
                            self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port)/auth/callback")!); self.ready = nil
                        case .failed: self.finish(ChatGPTAuth.failure("Could not open the local sign-in callback. Try again."))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !self.stopped, self.connections.count < 8 else { connection.cancel(); return }
                        let id = UUID(); self.connections[id] = connection
                        connection.start(queue: self.queue); self.receive(connection, id: id, buffer: Data())
                        self.queue.asyncAfter(deadline: .now() + 10) { self.connections.removeValue(forKey: id)?.cancel() }
                    }
                    listener.start(queue: self.queue)
                } catch { self.finish(ChatGPTAuth.failure("Could not open the local sign-in callback.")) }
            }
        }
    }
    func result() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let url = self.pending { self.pending = nil; continuation.resume(returning: url) }
                else if self.stopped { continuation.resume(throwing: CancellationError()) }
                else { self.callback = continuation }
            }
        }
    }
    func cancel() { queue.async { self.finish(CancellationError()) } }
    private func finish(_ error: Error) {
        stopped = true; listener?.cancel(); listener = nil
        ready?.resume(throwing: error); ready = nil
        callback?.resume(throwing: error); callback = nil
        for connection in connections.values { connection.cancel() }; connections = [:]
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            let buffer = buffer + (data ?? Data())
            guard buffer.count <= 16_384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.receive(connection, id: id, buffer: buffer) }; return
            }
            let request = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            let target = request.count == 3 && request[0] == "GET" ? String(request[1]) : ""
            let url = target.hasPrefix("/auth/callback?") ? URL(string: "http://127.0.0.1:\(self.port)" + target) : nil
            let response: Data
            do { response = try LocalAuthenticationPage.response(for: LocalAuthenticationPage.state(for: url)) }
            catch { self.finish(ChatGPTAuth.failure("Could not load the local sign-in page. Reinstall NativeAgent and try again.")); return }
            connection.send(content: response, completion: .contentProcessed { _ in self.connections.removeValue(forKey: id)?.cancel() })
            if let url {
                self.listener?.cancel(); self.listener = nil
                if let continuation = self.callback { self.callback = nil; continuation.resume(returning: url) }
                else { self.pending = url }
            }
        }
    }
}

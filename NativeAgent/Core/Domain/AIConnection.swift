import Foundation

enum AIWireFormat: String, Codable, CaseIterable, Identifiable {
    case openAI, anthropic
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI-compatible chat" : "Anthropic Messages" }
}

/// Non-secret metadata only. Each connection's token is stored separately in Keychain.
struct AIConnection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var format: AIWireFormat = .openAI

    func validated() throws -> AIConnection {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 80, !value.model.isEmpty, value.model.count <= 200,
              !value.model.contains(where: \.isWhitespace) else {
            throw NativeAgentError.unsupported("Enter a name and a valid model ID from your provider.")
        }
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else {
            throw NativeAgentError.unsupported("Use an HTTPS API base URL without credentials, query parameters or a fragment.")
        }
        value.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value
    }

    var destination: String { URL(string: baseURL)?.host ?? baseURL }
    static let presets: [AIConnection] = [
        .init(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: ""),
        .init(name: "Claude", baseURL: "https://api.anthropic.com/v1", model: "", format: .anthropic),
        .init(name: "Grok", baseURL: "https://api.x.ai/v1", model: ""),
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: ""),
        .init(name: "Custom API", baseURL: "", model: "")
    ]
}

struct AIRecipient: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String
    let detail: String
    var connection: AIConnection?
    var legacyKey: ProviderKind?
    var account: ProviderKind?
}

enum ComposerMention {
    /// A trailing mention token, not an email address. The editor remains ordinary text.
    static func range(in text: String) -> Range<String.Index>? {
        guard let at = text.lastIndex(of: "@"),
              at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
        let query = text[text.index(after: at)...]
        guard query.count <= 80, !query.contains(where: \.isWhitespace) else { return nil }
        return at..<text.endIndex
    }
    static func query(in text: String) -> String? {
        range(in: text).map { String(text[$0].dropFirst()) }
    }
    static func removingToken(from text: String) -> String {
        guard let range = range(in: text) else { return text }
        var result = text; result.removeSubrange(range); return result
    }
}

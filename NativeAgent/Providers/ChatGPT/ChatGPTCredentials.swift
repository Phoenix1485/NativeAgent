import Foundation
import Security

struct ChatGPTTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var earliestRefreshAt: Date?
    var scope: String
}

struct ChatGPTRegistration: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String?
    var tokens: ChatGPTTokens?
}

enum ChatGPTHostID {
    static func make() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }
    // NativeAgent uses the documented UUIDv4 URI alternative, not a bare UUID.
    static func isValid(_ value: String) -> Bool {
        value.range(of: #"\Aurn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z"#, options: .regularExpression) != nil
    }
}

struct ChatGPTCredentialRecord: Codable, Sendable {
    var hostID = ChatGPTHostID.make()
    var activeClientID: String?
    var registrations: [ChatGPTRegistration] = []
    var active: ChatGPTRegistration? { registrations.first { $0.clientID == activeClientID } }

    mutating func prepareHostID() throws {
        // Build 0.4.1 persisted bare UUIDs. Preserve that UUID and every registration/token;
        // fix only its representation, before saving and opening the next browser attempt.
        if ChatGPTHostID.isValid("urn:uuid:" + hostID) { hostID = "urn:uuid:" + hostID }
        guard ChatGPTHostID.isValid(hostID) else {
            throw NativeAgentError.providerUnavailable("NativeAgent’s saved ChatGPT host identifier is malformed. No browser was opened and no account credentials were changed.")
        }
    }
}

protocol ChatGPTCredentialStoring: Sendable {
    func load() throws -> ChatGPTCredentialRecord
    func save(_ record: ChatGPTCredentialRecord) throws
}

/// Deliberately separate from API keys and from every Codex/Claude credential store.
struct ChatGPTKeychainStore: ChatGPTCredentialStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.nativeagent.chatgpt-oauth",
         kSecAttrAccount as String: "registrations"]
    }
    func load() throws -> ChatGPTCredentialRecord {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return ChatGPTCredentialRecord() }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        do { return try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: data) }
        catch { throw NativeAgentError.providerUnavailable("NativeAgent’s ChatGPT registration could not be read from Keychain.") }
    }
    func save(_ record: ChatGPTCredentialRecord) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(record),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> Error {
        NativeAgentError.providerUnavailable("Keychain could not store or read the ChatGPT connection (\(status)). No credentials were written to preferences or logs.")
    }
}

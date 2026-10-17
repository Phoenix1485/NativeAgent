import Combine
import Foundation
import Security

protocol AITokenStoring: Sendable {
    func read(_ id: UUID) throws -> String?
    func save(_ token: String, id: UUID) throws
    func remove(_ id: UUID) throws
}

struct AIKeychainStore: AITokenStoring {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.nativeagent.ai-connections",
         kSecAttrAccount as String: id.uuidString]
    }
    func read(_ id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw NativeAgentError.unsupported("The saved API token could not be read.")
        }
        return token
    }
    func save(_ token: String, id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { try check(SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)) }
        else { try check(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NativeAgentError.unsupported("Keychain request failed (\(status)). No token was written to preferences.") }
    }
}

@MainActor
final class AIConnectionStore: ObservableObject {
    static let maximumTokens = 10
    @Published private(set) var connections: [AIConnection]
    private let defaults: UserDefaults
    private let tokens: any AITokenStoring
    private static let preferencesKey = "nativeagent.ai-connections.v1"
    init(defaults: UserDefaults, tokens: any AITokenStoring = AIKeychainStore()) {
        self.defaults = defaults; self.tokens = tokens
        connections = defaults.data(forKey: Self.preferencesKey).flatMap { try? JSONDecoder().decode([AIConnection].self, from: $0) } ?? []
    }
    func save(_ connection: AIConnection, token: String, legacyTokenCount: Int = 0) throws {
        let value = try connection.validated()
        let existing = connections.firstIndex { $0.id == value.id }
        guard existing != nil || connections.count + legacyTokenCount < Self.maximumTokens else {
            throw NativeAgentError.unsupported("You can save at most 10 API tokens, including existing provider keys. Remove one before adding another.")
        }
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            guard let previous = connections.first(where: { $0.id == value.id }), previous.baseURL == value.baseURL,
                  try tokens.read(value.id) != nil else {
                throw NativeAgentError.unsupported("Enter a token. Changing the destination requires entering its token again.")
            }
        } else {
            guard clean.count <= 16_384, !clean.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
                throw NativeAgentError.unsupported("Enter a valid API token without spaces or control characters.")
            }
            try tokens.save(clean, id: value.id)
        }
        if let existing { connections[existing] = value } else { connections.append(value) }
        persist()
    }
    func remove(_ id: UUID) throws {
        try tokens.remove(id); connections.removeAll { $0.id == id }; persist()
    }
    func token(for id: UUID) throws -> String {
        guard connections.contains(where: { $0.id == id }), let token = try tokens.read(id) else {
            throw NativeAgentError.unsupported("This API connection has no saved token. Update it in Settings → API connections.")
        }
        return token
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: Self.preferencesKey) }
    }
}

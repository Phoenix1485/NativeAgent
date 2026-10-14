import Foundation
import Security
import LocalAuthentication

protocol CredentialStoring: Sendable {
    func read(_ provider: ProviderKind) throws -> String?
    func save(_ key: String, for provider: ProviderKind) throws
    func remove(_ provider: ProviderKind) throws
    func contains(_ provider: ProviderKind) throws -> Bool
}

struct KeychainCredentialStore: CredentialStoring {
    private let service = "com.nativeagent.provider-api-key"
    private func query(_ provider: ProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }
    func read(_ provider: ProviderKind) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw NativeAgentError.providerUnavailable("The saved credential could not be read.") }
        return key
    }
    func contains(_ provider: ProviderKind) throws -> Bool {
        var request = query(provider)
        request[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { return true }
        try check(status)
        return true
    }
    func save(_ key: String, for provider: ProviderKind) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: \.isWhitespace), clean.count <= 16_384 else {
            throw NativeAgentError.providerUnavailable("Enter a valid API key without spaces or line breaks.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(provider).merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(_ provider: ProviderKind) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NativeAgentError.providerUnavailable("Keychain could not complete the request (\(status)). Your key was not written to preferences or logs.") }
    }
}

enum ProviderExecutable {
    static func resolve(_ kind: ProviderKind, configured: String) -> String? {
        if !configured.isEmpty { return configured }
        return (["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] +
                (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") })
            .map { $0 + "/" + kind.executable }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let credentialVariables = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL",
        "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID", "CODEX_MODEL_PROVIDER",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE", "ANTHROPIC_WORKSPACE_ID",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_AWS",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL", "ANTHROPIC_FOUNDRY_BASE_URL", "XAI_API_KEY",
        "CLAUDE_CODE_SIMPLE", "CLAUDECODE"]

    static func environment(kind: ProviderKind, key: String?, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = inherited
        // Never accidentally select another credential inherited from the parent app.
        for name in credentialVariables { result.removeValue(forKey: name) }
        for name in result.keys.filter({ $0.hasPrefix("CODEX_WIF_") || $0.hasPrefix("OPENAI_WIF_") || $0.hasPrefix("ANTHROPIC_FEDERATION_") }) { result.removeValue(forKey: name) }
        let keyName = switch kind { case .codex: "OPENAI_API_KEY"; case .claude: "ANTHROPIC_API_KEY"; case .grok: "XAI_API_KEY" }
        if let key { result[keyName] = key }
        result["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", result["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        return result
    }

    static func profileDescription(_ kind: ProviderKind, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch kind {
        case .codex: return environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        case .claude: return environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        case .grok: return "Grok Build default profile"
        }
    }
}

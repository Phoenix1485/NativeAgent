import Combine
import Foundation
import SwiftUI

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, grok
    var id: String { rawValue }
    var title: String { switch self { case .codex: "ChatGPT / Codex"; case .claude: "Claude Code"; case .grok: "Grok" } }
    var executable: String { self == .codex ? "codex" : rawValue }
    var symbol: String { switch self { case .codex: "sparkles"; case .claude: "sun.max"; case .grok: "bolt" } }
    var setupURL: URL { let value = switch self {
    case .codex: "https://developers.openai.com/codex/cli"
    case .claude: "https://code.claude.com/docs/en/setup"
    case .grok: "https://docs.x.ai/build/overview"
    }; return URL(string: value)! }
    var keyURL: URL { let value = switch self {
    case .codex: "https://platform.openai.com/api-keys"
    case .claude: "https://platform.claude.com/settings/keys"
    case .grok: "https://console.x.ai"
    }; return URL(string: value)! }
}

enum AuthenticationMethod: String, Codable, CaseIterable, Sendable { case account, apiKey }
enum AppTheme: String, Codable, CaseIterable { case system, light, dark
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}
enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case violet, blue, mint, amber, rose
    var id: String { rawValue }
    var color: Color { switch self {
    case .violet: Color(red: 0.55, green: 0.50, blue: 0.96)
    case .blue: Color(red: 0.26, green: 0.55, blue: 0.98)
    case .mint: Color(red: 0.16, green: 0.66, blue: 0.51)
    case .amber: Color(red: 0.85, green: 0.55, blue: 0.17)
    case .rose: Color(red: 0.86, green: 0.37, blue: 0.54)
    } }
}
enum WorkspaceAccess: String, Codable, CaseIterable, Sendable { case readOnly, workspaceWrite
    var title: String { self == .readOnly ? "Read only" : "Workspace edits" }
}

struct ProviderPreference: Codable, Equatable, Sendable {
    var method: AuthenticationMethod = .account
    var binaryPath = ""
    var accountLabel: String?
    var verifiedAt: Date?
    var defaultModelID: String?
    var disabledModels: Set<String> = []
    var starredModels: Set<String> = []
    var reasoning: [String: String] = [:]
    var catalog: [ProviderModel] = []
}

struct RunConfiguration: Sendable, Equatable {
    var reasoning: String?
    var access: WorkspaceAccess = .workspaceWrite
    var instructions = ""
}

/// Only non-secret settings belong here. Credentials are stored separately in Keychain.
@MainActor
final class AppPreferences: ObservableObject {
    @Published var provider: ProviderKind { didSet { save() } }
    @Published var providers: [String: ProviderPreference] { didSet { save() } }
    @Published var theme: AppTheme { didSet { save() } }
    @Published var accent: AccentChoice { didSet { save() } }
    @Published var access: WorkspaceAccess { didSet { save() } }
    @Published var instructions: String { didSet { save() } }
    @Published var textSize: Double { didSet { save() } }
    @Published var showTimestamps: Bool { didSet { save() } }
    @Published var onboardingComplete: Bool { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "nativeagent.preferences.v1"

    private struct Saved: Codable {
        var provider: ProviderKind = .codex
        var providers: [String: ProviderPreference] = [:]
        var theme: AppTheme = .system
        var accent: AccentChoice = .violet
        var access: WorkspaceAccess = .workspaceWrite
        var instructions = ""
        var textSize: Double = 14
        var showTimestamps = true
        var onboardingComplete = false
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        provider = saved.provider; providers = saved.providers; theme = saved.theme; accent = saved.accent
        access = saved.access; instructions = saved.instructions; textSize = saved.textSize
        showTimestamps = saved.showTimestamps; onboardingComplete = saved.onboardingComplete
        if providers[ProviderKind.codex.rawValue] == nil, let oldPath = defaults.string(forKey: "codexBinaryPath") {
            providers[ProviderKind.codex.rawValue] = ProviderPreference(binaryPath: oldPath)
        }
    }

    func profile(_ kind: ProviderKind) -> ProviderPreference { providers[kind.rawValue] ?? ProviderPreference() }
    func update(_ kind: ProviderKind, _ change: (inout ProviderPreference) -> Void) {
        var value = profile(kind); change(&value); providers[kind.rawValue] = value
    }
    func enabledModels(_ kind: ProviderKind) -> [ProviderModel] {
        let value = profile(kind)
        return value.catalog.filter { !value.disabledModels.contains($0.id) }.sorted {
            let lhs = value.starredModels.contains($0.id), rhs = value.starredModels.contains($1.id)
            return lhs != rhs ? lhs : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
    func resolvedDefault(_ kind: ProviderKind) -> String? {
        let enabled = enabledModels(kind)
        if let saved = profile(kind).defaultModelID, enabled.contains(where: { $0.id == saved }) { return saved }
        return enabled.first(where: \.isDefault)?.id ?? enabled.first?.id
    }
    func setEnabled(_ id: String, enabled: Bool, provider kind: ProviderKind) {
        update(kind) { value in
            if enabled { value.disabledModels.remove(id) } else { value.disabledModels.insert(id) }
            if !enabled && value.defaultModelID == id { value.defaultModelID = nil }
        }
    }
    func setDefault(_ id: String, provider kind: ProviderKind) {
        update(kind) { $0.disabledModels.remove(id); $0.defaultModelID = id }
    }
    func reasoning(for model: ProviderModel?, provider kind: ProviderKind) -> String? {
        guard let model, let value = profile(kind).reasoning[model.id], model.reasoningEfforts.contains(value) else { return nil }
        return value
    }
    func effectiveReasoning(for model: ProviderModel?, provider kind: ProviderKind) -> String? {
        if let explicit = reasoning(for: model, provider: kind) { return explicit }
        guard let model, let value = model.defaultReasoningEffort, model.reasoningEfforts.contains(value) else { return nil }
        return value
    }
    func mergeCatalog(_ models: [ProviderModel], provider kind: ProviderKind) {
        update(kind) { profile in
            let custom = profile.catalog.filter { $0.description == "Custom model ID · access checked by provider" }
            var seen = Set<String>()
            profile.catalog = (models + custom).filter { seen.insert($0.id).inserted }
        }
    }
    private func save() {
        let value = Saved(provider: provider, providers: providers, theme: theme, accent: accent, access: access, instructions: instructions, textSize: textSize, showTimestamps: showTimestamps, onboardingComplete: onboardingComplete)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

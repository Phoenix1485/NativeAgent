import Combine
import Foundation

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var profiles: [AgentProfile]
    @Published var automaticEnabled: Bool { didSet { defaults.set(automaticEnabled, forKey: "nativeagent.agents.automatic") } }
    @Published var callLimit: Int { didSet { defaults.set(min(6, max(1, callLimit)), forKey: "nativeagent.agents.call-limit") } }
    @Published private(set) var notice: String?
    private let defaults: UserDefaults
    private static let key = "nativeagent.agents.v1"
    init(defaults: UserDefaults) {
        self.defaults = defaults
        automaticEnabled = defaults.object(forKey: "nativeagent.agents.automatic") as? Bool ?? true
        callLimit = min(6, max(1, defaults.object(forKey: "nativeagent.agents.call-limit") as? Int ?? 3))
        if let data = defaults.data(forKey: Self.key) {
            do { profiles = try Self.decode(data) }
            catch { profiles = []; notice = "Saved agents could not be read. Their stored data has been preserved. Export it before restoring the built-in presets." }
        } else { profiles = AgentProfile.builtIns }
    }
    func save(_ profile: AgentProfile) throws {
        let value = try profile.validated()
        guard !profiles.contains(where: { $0.id != value.id && $0.handle == value.handle }) else { throw NativeAgentError.unsupported("That @handle is already used by another agent.") }
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { guard next.count < 50 else { throw NativeAgentError.unsupported("You can configure up to 50 agents.") }; next.append(value) }
        try persist(next)
    }
    func remove(_ id: UUID) throws { try persist(profiles.filter { $0.id != id }) }
    func restoreBuiltIns() throws {
        var next = profiles.filter { !AgentProfile.builtIns.map(\.id).contains($0.id) }
        for preset in AgentProfile.builtIns {
            guard !next.contains(where: { $0.handle == preset.handle }) else { throw NativeAgentError.unsupported("Rename the custom @\(preset.handle) before restoring presets.") }
            next.append(preset)
        }
        guard next.count <= 50 else { throw NativeAgentError.unsupported("Remove an agent before restoring presets.") }
        try persist(next)
    }
    func exportData() throws -> Data {
        if profiles.isEmpty, notice != nil, let original = defaults.data(forKey: Self.key) { return original }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }
    /// Imports are inert until explicitly enabled; importing never authorizes unattended requests.
    func importData(_ data: Data) throws {
        var next = profiles
        for var value in try Self.decode(data) {
            value.id = UUID(); value.enabled = false; value.delegation = .manual
            guard !next.contains(where: { $0.handle == value.handle }) else { throw NativeAgentError.unsupported("@\(value.handle) already exists. Import did not change your agents.") }
            next.append(value)
        }
        guard next.count <= 50 else { throw NativeAgentError.unsupported("The import would exceed 50 agents.") }
        try persist(next)
    }
    private func persist(_ next: [AgentProfile]) throws {
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.key); profiles = next; notice = nil
    }
    private static func decode(_ data: Data) throws -> [AgentProfile] {
        guard data.count <= 6_000_000 else { throw NativeAgentError.unsupported("Agent configuration exceeds 6 MB.") }
        let values = try JSONDecoder().decode([AgentProfile].self, from: data).map { try $0.validated() }
        guard values.count <= 50, Set(values.map(\.id)).count == values.count, Set(values.map(\.handle)).count == values.count else {
            throw NativeAgentError.unsupported("Agent IDs and @handles must be unique, with at most 50 agents.")
        }
        return values
    }
}

import Foundation

struct PromptBookmark: Identifiable, Equatable, Sendable {
    let id: UUID
    let order: Int
    let preview: String
}

/// Provider-owned facts, never inferred by scanning generated prose for links.
struct ConversationFact: Codable, Equatable, Sendable {
    enum Category: String, Codable, Sendable { case plan, activity, source, status, result }
    let key: String
    let category: Category
    let title: String
    let text: String
    var state: String?
    var path: String?
    var url: String?

    var encoded: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> Self? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}

enum PromptFisheye {
    static let pitch: CGFloat = 14
    static func strength(distance: CGFloat, radius: CGFloat = 56) -> CGFloat {
        guard radius > 0 else { return 0 }
        let value = max(0, 1 - abs(distance) / radius)
        return value * value
    }
    static func nearestIndex(y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, Int(floor(y / pitch))))
    }
    static func currentPrompt(order: Int, prompts: [PromptBookmark]) -> UUID? {
        prompts.last(where: { $0.order <= order })?.id ?? prompts.first?.id
    }

    static func currentPrompt(entryIndex: Int, timeline: [TimelineEntry], prompts: [PromptBookmark]) -> UUID? {
        guard timeline.indices.contains(entryIndex) else { return nil }
        if let order = timeline[entryIndex].receivedOrder { return currentPrompt(order: order, prompts: prompts) }
        if let preceding = timeline.prefix(entryIndex + 1).last(where: { $0.kind == .userMessage }) { return preceding.id }
        // Live entries can lack an assigned database order, and a long tool run
        // may have evicted its originating user prompt from the display window.
        if let next = timeline.dropFirst(entryIndex + 1).first(where: { $0.kind == .userMessage }),
           let index = prompts.firstIndex(where: { $0.id == next.id }) {
            return prompts[max(0, index - 1)].id
        }
        return prompts.last?.id
    }
}

import SwiftUI

private struct RailOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Lazy rows keep long prompt indexes cheap. No timer or idle animation runs.
struct ConversationMinimap: View {
    let prompts: [PromptBookmark]
    let currentID: UUID?
    var maximumHeight: CGFloat = 336
    let navigate: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerY: CGFloat?
    @State private var contentOffset: CGFloat = 0
    @State private var keyboardID: UUID?
    @FocusState private var keyboardFocused: Bool

    private var hoveredIndex: Int? { pointerY.flatMap { PromptFisheye.nearestIndex(y: $0 - contentOffset, count: prompts.count) } }
    private var previewPrompt: PromptBookmark? {
        if let index = hoveredIndex { return prompts[index] }
        return keyboardFocused ? prompts.first(where: { $0.id == keyboardID }) : nil
    }

    private var railContent: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                    promptButton(prompt, index: index)
                }
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: RailOffsetKey.self, value: geometry.frame(in: .named("promptRail")).minY)
            })
        }
    }

    private func promptButton(_ prompt: PromptBookmark, index: Int) -> some View {
        let center = CGFloat(index) * PromptFisheye.pitch + PromptFisheye.pitch / 2
        let strength: CGFloat = pointerY.map { PromptFisheye.strength(distance: center - ($0 - contentOffset)) } ?? (keyboardFocused && keyboardID == prompt.id ? 1 : 0)
        return PromptMinimapButton(prompt: prompt, number: index + 1, current: prompt.id == currentID, strength: strength) {
            keyboardID = prompt.id; navigate(prompt.id)
        }.id(prompt.id).animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: strength)
    }

    var body: some View {
        ScrollViewReader { proxy in
            railContent.scrollIndicators(.hidden).coordinateSpace(name: "promptRail")
                .onPreferenceChange(RailOffsetKey.self) { contentOffset = $0 }
                .onContinuousHover { phase in
                    switch phase { case .active(let point): pointerY = point.y; case .ended: pointerY = nil }
                }
                .focusable().focused($keyboardFocused)
                .accessibilityLabel("Conversation prompt navigation")
                .accessibilityHint("Use Up and Down to choose a prompt, then Return to navigate")
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down, !prompts.isEmpty else { return }
                    let old = prompts.firstIndex(where: { $0.id == (keyboardID ?? currentID) }) ?? 0
                    let next = min(prompts.count - 1, max(0, old + (direction == .down ? 1 : -1)))
                    keyboardID = prompts[next].id; proxy.scrollTo(prompts[next].id, anchor: .center)
                }
                .onKeyPress(.return) {
                    guard let id = keyboardID ?? currentID ?? prompts.first?.id else { return .ignored }
                    navigate(id); return .handled
                }
                .onKeyPress(.escape) { keyboardFocused = false; pointerY = nil; return .handled }
                .onChange(of: keyboardFocused) {
                    if keyboardFocused {
                        keyboardID = keyboardID ?? currentID ?? prompts.first?.id
                        if let keyboardID { proxy.scrollTo(keyboardID, anchor: .center) }
                    }
                }
                .onChange(of: currentID) {
                    if pointerY == nil, !keyboardFocused, let currentID { proxy.scrollTo(currentID, anchor: .center) }
                }
                .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
        }
        .frame(width: 48, height: min(max(14, maximumHeight - 20), CGFloat(prompts.count) * PromptFisheye.pitch))
        .padding(.vertical, 10).padding(.trailing, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .trailing) {
            if let prompt = previewPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("USER PROMPT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(prompt.preview.isEmpty ? "Empty prompt" : prompt.preview).font(.system(size: 12)).lineLimit(6)
                }.padding(12).frame(width: 260, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Studio.line))
                    .offset(x: -64).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

private struct PromptMinimapButton: View {
    let prompt: PromptBookmark
    let number: Int
    let current: Bool
    let strength: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Circle().fill(current ? Studio.accent : Color.clear).frame(width: 4, height: 4)
                Capsule().fill(current ? Studio.accent : Color.secondary.opacity(0.5 + Double(strength) * 0.4))
                    .frame(width: 13 + strength * 21, height: 2 + strength * 3)
            }.frame(width: 44, height: PromptFisheye.pitch, alignment: .trailing).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Prompt \(number): \(prompt.preview)")
            .accessibilityValue(current ? "Current conversation position" : "")
            .accessibilityHint("Scroll to this message")
    }
}

import SwiftUI

struct TimelineItemView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let item: TimelineEntry
    @State private var expanded = false
    @State private var fullText: String?
    @State private var loadingText = false
    @State private var editingPrompt = false
    private var displayText: String { fullText ?? String(item.text.prefix(8_000)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 26, height: 26).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Text(item.title).font(.system(size: 12, weight: .semibold))
                if item.isStreaming { ProgressView().controlSize(.small) }
                Spacer()
                if model.settings.showTimestamps { Text(item.createdAt, style: .time).font(.caption).foregroundStyle(.tertiary) }
            }
            if item.kind == .command {
                DisclosureGroup(isExpanded: $expanded) {
                    if let fullText { LongMessageView(text: fullText, fontSize: model.settings.textSize, monospaced: true).frame(height: 260) }
                    else { CommandOutputView(text: displayText).frame(maxHeight: 260) }
                } label: { Text(item.detail ?? "Command output").font(.caption).foregroundStyle(.secondary) }
            } else {
                if let fullText { LongMessageView(text: fullText, fontSize: model.settings.textSize).frame(height: 360) }
                else { Text(displayText).font(.system(size: model.settings.textSize)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if item.kind != .fact, let detail = item.detail { Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if fullText == nil && (item.textIsPreview || item.text.count > 8_000) {
                Button(loadingText ? "Loading…" : "Show full message") {
                    loadingText = true
                    Task {
                        fullText = item.textIsPreview ? await model.fullMessageText(item.id) : item.text
                        loadingText = false
                    }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(Studio.accent).disabled(loadingText || item.isStreaming)
            } else if fullText != nil {
                Button("Collapse message") { fullText = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(Studio.accent)
            }
            if !item.isStreaming {
                if item.kind == .userMessage {
                    Button("Edit & resend…") { editingPrompt = true }.font(.caption).buttonStyle(.plain).foregroundStyle(Studio.accent).disabled(model.isWorking)
                } else if item.kind == .agentMessage || item.kind == .error {
                    Button(item.kind == .agentMessage ? "Regenerate in a new branch…" : "Retry in a new branch…") {
                        Task { await model.features.prepareRetry(item) }
                    }.font(.caption).buttonStyle(.plain).foregroundStyle(Studio.accent).disabled(model.isWorking)
                }
            }
        }
        .padding(18)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .contextMenu {
            if item.kind == .userMessage || item.kind == .agentMessage {
                Button("Branch with selected context…") { Task { await model.features.branch(at: item) } }.disabled(model.isWorking)
            }
            Button("Task reports") { model.features.execute(.reports) }
        }
        .onDisappear { fullText = nil }
        .sheet(isPresented: $editingPrompt) { EditPromptView(item: item).environmentObject(model) }
    }

    private var icon: String {
        switch item.kind {
        case .userMessage: "person.circle"
        case .agentMessage: "sparkles"
        case .command: "terminal"
        case .fileChange: "doc.badge.ellipsis"
        case .approval: "hand.raised"
        case .question: "questionmark.circle"
        case .error: "exclamationmark.triangle"
        case .notice, .fact: "info.circle"
        }
    }
    private var color: Color { item.kind == .error ? .red : (item.kind == .userMessage ? .secondary : Studio.accent) }
    private var background: Color { item.kind == .userMessage ? Studio.surface : .clear }
}

private struct EditPromptView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let item: TimelineEntry
    @State private var text = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit message").font(.title2)
            Text("Continue in a new chat with the earlier messages. The original remains unchanged. Review the new draft before sending.").font(.caption)
            TextEditor(text: $text).disabled(!loaded)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create retry draft") { Task { await model.features.prepareRetry(item, prompt: text); dismiss() } }
                    .disabled(!loaded || model.isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 640, height: 440)
            .task { text = await model.fullMessageText(item.id) ?? item.text; loaded = true }
    }
}

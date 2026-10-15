import AppKit
import SwiftUI

struct ConversationDetailsView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = "Progress"
    @State private var selected: TimelineEntry?
    @State private var preview: String?
    @State private var loading = false
    @State private var showingFile = false

    init(section: String = "Progress") { _section = State(initialValue: section) }

    private var entries: [TimelineEntry] {
        model.conversationDetails.filter { entry in
            let fact = ConversationFact.decode(entry.detail)
            switch section {
            case "Sources": return fact?.category == .source
            case "Results": return entry.kind == .fileChange || entry.kind == .agentMessage || fact?.category == .result
            default: return entry.kind == .command || entry.kind == .error || entry.kind == .approval || fact?.category == .plan || fact?.category == .activity || fact?.category == .status
            }
        }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if selected != nil {
                    Button { selected = nil; preview = nil; showingFile = false } label: { Image(systemName: "chevron.left") }.help("Back to conversation details").accessibilityLabel("Back to conversation details")
                }
                Text(selected?.title ?? "Conversation details").font(.headline).lineLimit(2)
                Spacer()
            }
            if let selected {
                detail(model.conversationDetails.first(where: { $0.id == selected.id }) ?? selected)
            } else {
                Picker("Details section", selection: $section) {
                    ForEach(["Progress", "Results", "Sources"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if section == "Progress" {
                            Label(model.conversationStatus, systemImage: "circle.dotted").font(.subheadline.weight(.medium))
                            ForEach(model.conversationApprovals) { approval in
                                DisclosureGroup {
                                    ApprovalView(approval: approval)
                                } label: { Label(approval.title, systemImage: "hand.raised").font(.subheadline) }
                            }
                        }
                        if entries.isEmpty {
                            Text(section == "Sources" ? "No explicit sources have been reported. File browsing and links mentioned in replies are not treated as used sources." : section == "Results" ? "No recorded file changes or responses yet." : "Plans and tool actions appear when reported by the provider.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                        ForEach(entries) { entry in
                            Button { selected = entry; preview = nil; showingFile = false; loading = false } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: icon(entry)).foregroundStyle(Studio.accent).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.kind == .agentMessage ? "Response" : entry.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(String(entry.text.prefix(240))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityHint("Open recorded details")
                        }
                    }.padding(.vertical, 2)
                }
                Text("Recent recorded activity · up to 200 saved entries. Claude terminal sessions are not captured here.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 390, height: 460)
            .task { await model.refreshConversationSummaries() }
            .onChange(of: model.selectedConversation?.id) { selected = nil; preview = nil }
    }

    private func detail(_ entry: TimelineEntry) -> some View {
        let fact = ConversationFact.decode(entry.detail)
        return VStack(alignment: .leading, spacing: 12) {
            if let state = fact?.state { Text("Provider status: \(state)").font(.caption).foregroundStyle(.secondary) }
            LongMessageView(text: preview ?? entry.text, fontSize: 12, monospaced: entry.kind == .fileChange || entry.kind == .command)
            HStack {
                Button("Show in conversation") { Task { await model.navigateToMessage(entry.id); dismiss() } }.disabled(model.historyLoading)
                if let path = fact?.path ?? (entry.kind == .fileChange ? entry.title : nil) {
                    Button(loading ? "Loading…" : "Preview file") {
                        loading = true; showingFile = true
                        Task {
                            let text: String
                            do { text = try await model.previewConversationFile(path) }
                            catch { text = error.localizedDescription }
                            if selected?.id == entry.id { preview = text; loading = false }
                        }
                    }.disabled(loading)
                }
                if let string = fact?.url, let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    Button("Open source") { NSWorkspace.shared.open(url) }.help(string)
                }
            }.controlSize(.small)
        }.task(id: entry) {
            guard !showingFile else { return }
            let text = await model.fullMessageText(entry.id)
            if !Task.isCancelled, selected?.id == entry.id, !showingFile { preview = text ?? entry.text }
        }
    }

    private func icon(_ entry: TimelineEntry) -> String {
        if let fact = ConversationFact.decode(entry.detail) {
            switch fact.category {
            case .source: return fact.url == nil ? "doc.text.magnifyingglass" : "globe"
            case .result: return "tray.full"
            case .plan: return "checklist"
            case .status: return "circle.dotted"
            case .activity: return fact.state == "completed" ? "checkmark.circle" : "terminal"
            }
        }
        return entry.kind == .fileChange ? "doc.badge.ellipsis" : entry.kind == .command ? "terminal" : entry.kind == .error ? "exclamationmark.triangle" : "text.bubble"
    }
}

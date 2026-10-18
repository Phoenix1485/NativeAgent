import SwiftUI

/// A conversation-scoped summary; the full reports and global queue remain available.
struct ChatWorkStatusView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var editing: QueuedWork?
    @State private var dismissedReport: UUID?

    private var report: TaskReport? {
        let value = features.activeTask?.conversationID == model.selectedConversation?.id ? features.activeTask : features.latestChatReport
        return value?.conversationID == model.selectedConversation?.id ? value : nil
    }
    private var pending: [QueuedWork] {
        guard let id = model.selectedConversation?.id else { return [] }
        return features.queue.filter { $0.followUpConversationID == id && ![.completed, .canceled].contains($0.state) }
            .sorted { $0.position < $1.position }
    }
    private var visibleReport: TaskReport? {
        guard let report, report.id != dismissedReport,
              report.state.isActive || features.finishingTask || !report.changedPaths.isEmpty else { return nil }
        return report
    }

    var body: some View {
        if visibleReport != nil || !pending.isEmpty {
            VStack(spacing: 0) {
                if let report = visibleReport {
                    HStack(spacing: 10) {
                        if report.state.isActive || features.finishingTask { ProgressView().controlSize(.small) }
                        else { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.changedPaths.isEmpty ? status(report) : "\(report.changedPaths.count) \(report.changedPaths.count == 1 ? "file" : "files") changed")
                                .font(.system(size: 12, weight: .medium))
                            Text(report.state.isActive ? "Provider-reported · \(status(report))" : "Latest task · tracked files")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let counts = report.changeSummary, counts.countedFiles > 0 {
                            HStack(spacing: 5) {
                                Text("+\(counts.additions)").foregroundStyle(.green)
                                Text("−\(counts.deletions)").foregroundStyle(.red)
                            }.font(.system(size: 12, design: .monospaced))
                                .help("Line changes in \(counts.countedFiles) readable snapshots. Other files may not have line counts. Review shows snapshot coverage and provider-reported changes.")
                        }
                        Spacer(minLength: 4)
                        Button("Review") { Task { await features.openReport(report.id) } }.foregroundStyle(Studio.accent)
                        if !report.state.isActive && !features.finishingTask {
                            Button { dismissedReport = report.id } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Hide change summary").foregroundStyle(.secondary)
                        }
                    }.padding(12)
                }
                if !pending.isEmpty {
                    if visibleReport != nil { Divider() }
                    HStack {
                        Label("\(pending.filter { $0.state == .queued }.count) queued", systemImage: "text.line.first.and.arrowtriangle.forward")
                        Text(features.queuePaused ? "Paused" : "After current turn").foregroundStyle(.secondary)
                        Spacer()
                        Button(features.queuePaused ? "Resume" : "Pause") {
                            if features.queuePaused { Task { await features.startQueue() } } else { features.pauseQueue() }
                        }
                        Button("All tasks") { features.execute(.queue) }
                    }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 9)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(pending) { item in queueRow(item) }
                        }
                    }.frame(height: min(CGFloat(pending.count) * 46, 138))
                }
            }.buttonStyle(.plain)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Studio.line))
                .sheet(item: $editing) { item in
                    QueuedPromptEditor(item: item, features: features)
                }
        }
    }

    private func status(_ report: TaskReport) -> String {
        if features.finishingTask { return "Checking file changes…" }
        switch report.state {
        case .awaitingApproval: return "Waiting for approval"
        case .awaitingInput: return "Waiting for your answer"
        case .running: return "Working…"
        default: return "Task \(report.state.rawValue)"
        }
    }

    private func queueRow(_ item: QueuedWork) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.state.isActive ? "arrow.triangle.2.circlepath" : "arrow.turn.down.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.prompt).font(.system(size: 12)).lineLimit(1).help(item.prompt)
                Text(item.failure ?? "\(item.provider.title) · \(item.modelID) · \(item.state.rawValue)")
                    .font(.system(size: 10)).foregroundStyle(item.failure == nil ? Color.secondary : .orange).lineLimit(1)
            }
            Spacer(minLength: 2)
            if item.state == .queued {
                Button("Run next") { Task { await features.prioritizeQueue(item) } }
                    .font(.caption).help("Move to the front of the queue. The current turn finishes first.")
                Button { editing = item } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit queued prompt")
            }
            if !item.state.isActive {
                Button { Task { await features.removeQueue(item) } } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove queued prompt")
            }
        }.padding(.horizontal, 12).frame(height: 46)
    }
}

private struct QueuedPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: QueuedWork
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit queued prompt").font(.title2)
            Text("The queue is paused while you edit. Resume when you’re ready.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt).frame(height: 160)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var updated = item; updated.prompt = prompt
                    Task { await features.editQueue(updated); dismiss() }
                }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
            .onAppear { features.pauseQueue(); prompt = item.prompt }
    }
}

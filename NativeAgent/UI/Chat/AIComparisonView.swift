import SwiftUI

struct AIComparisonView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var assistant: WorkspaceAIAssistant
    @State private var entries: [TimelineEntry] = []
    @State private var fullTexts: [UUID: String] = [:]
    @State private var request: AIAssistanceRequest?
    @State private var loading = false
    @State private var error: String?
    private var selected: [TimelineEntry] { entries.filter { assistant.comparisonSelection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose two to six saved answers to compare. This list includes the latest 200 messages and answers in the history you currently have open.")
                .font(.callout).foregroundStyle(.secondary)
            if entries.isEmpty {
                ContentUnavailableView("No saved answers", systemImage: "bubble.left.and.bubble.right", description: Text("Ask your configured AIs in this chat first. Completed replies can be compared here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            Toggle(isOn: Binding(get: { assistant.comparisonSelection.contains(entry.id) }, set: { enabled in
                                if enabled { assistant.comparisonSelection.insert(entry.id) } else { assistant.comparisonSelection.remove(entry.id) }
                            })) {
                                HStack {
                                    VStack(alignment: .leading) { Text(entry.title).font(.callout.weight(.medium)); Text(entry.text.prefix(90)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(); Text(entry.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(loading || (!assistant.comparisonSelection.contains(entry.id) && selected.count >= 6))
                        }
                    }
                }.frame(height: 125)
                HStack {
                    Button("View side by side") { Task { await loadSelected() } }.disabled(selected.isEmpty || loading)
                    Menu("Ask AI") {
                        Button("Combine selected answers") { Task { await prepare(.combine) } }
                        Button("Find disagreements") { Task { await prepare(.disagreements) } }
                    }.disabled(selected.count < 2 || loading || model.isWorking)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                  ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(selected.filter { fullTexts[$0.id] != nil }) { entry in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(entry.title).font(.headline)
                                LongMessageView(text: fullTexts[entry.id] ?? "", fontSize: 13).frame(maxHeight: .infinity)
                                Button("Original message") { Task { await model.navigateToMessage(entry.id); model.features.panel = nil } }
                            }.padding(14).frame(width: 310).frame(maxHeight: .infinity).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.frame(height: geometry.size.height)
                  }
                }.frame(maxHeight: .infinity)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .task(id: model.selectedConversation?.id) { await loadAnswers(); if !selected.isEmpty { await loadSelected() } }
        .sheet(item: $request) { value in AIAssistanceView(assistant: assistant, request: value).environmentObject(model) }
    }

    private func loadAnswers() async {
        entries = []; fullTexts = [:]; error = nil
        guard let chat = model.selectedConversation?.id else { return }
        do {
            let values = try await model.database.timeline(conversationID: chat, limit: 200, previewCharacters: 300, messagesOnly: true)
            guard model.selectedConversation?.id == chat, !Task.isCancelled else { return }
            var byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            for entry in model.timeline where entry.kind == .agentMessage && !entry.isStreaming { byID[entry.id] = entry }
            entries = byID.values.filter { $0.kind == .agentMessage && !$0.isStreaming }.sorted { $0.createdAt > $1.createdAt }
            assistant.comparisonSelection.formIntersection(Set(entries.map(\.id)))
            if assistant.comparisonSelection.isEmpty, let turn = entries.first?.turnID {
                assistant.comparisonSelection = Set(entries.filter { $0.turnID == turn }.prefix(6).map(\.id))
            }
        } catch { self.error = error.localizedDescription }
    }
    private func loadSelected() async {
        let chat = model.selectedConversation?.id, values = selected
        loading = true; error = nil
        defer { loading = false }
        var loaded: [UUID: String] = [:]
        for value in values {
            guard let text = await model.fullMessageText(value.id) else { error = "An answer is no longer available. Refresh this conversation."; return }
            guard model.selectedConversation?.id == chat, !Task.isCancelled else { return }
            loaded[value.id] = text
        }
        fullTexts = loaded
    }
    private func prepare(_ purpose: AIAssistanceRequest.Purpose) async {
        await loadSelected()
        guard error == nil, selected.allSatisfy({ fullTexts[$0.id] != nil }) else { return }
        do {
            let content = try AIAnswerComparison.content(selected.map { (title: $0.title, text: fullTexts[$0.id] ?? "") })
            request = .init(purpose: purpose, source: model.selectedConversation?.title ?? "Selected answers", content: content, projectPath: model.selectedProject?.canonicalPath)
        } catch { self.error = error.localizedDescription }
    }
}

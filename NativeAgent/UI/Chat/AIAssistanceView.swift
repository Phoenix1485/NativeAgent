import AppKit
import SwiftUI

struct AIAssistanceView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var assistant: WorkspaceAIAssistant
    let request: AIAssistanceRequest
    var onUse: ((String) -> Void)?
    @State private var showSource: Bool

    init(assistant: WorkspaceAIAssistant, request: AIAssistanceRequest, onUse: ((String) -> Void)? = nil, sourceExpanded: Bool = false) {
        self.assistant = assistant; self.request = request; self.onUse = onUse
        _showSource = State(initialValue: sourceExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(request.purpose.rawValue, systemImage: "sparkles").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(assistant.isRunning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(request.source).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    if model.aiRecipients.isEmpty {
                        ContentUnavailableView("Add an AI connection", systemImage: "key", description: Text("Connect ChatGPT or Grok, or add Claude and other API connections in Settings."))
                        Button("Open Settings") { openSettings() }
                    } else { connectionControls }
                    if let notice = assistant.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: assistant.answers.isEmpty ? .infinity : (showSource ? 320 : 260))
            if !assistant.answers.isEmpty { answerCards }
        }.padding(24).frame(width: 820, height: 700).background(Studio.canvas)
            .tint(model.settings.accent.color).preferredColorScheme(model.settings.theme.scheme)
            .task(id: request.id) { assistant.prepare(request) }
            .interactiveDismissDisabled(assistant.isRunning)
            .onDisappear { assistant.cancel() }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.aiRecipients) { recipient in
                    Toggle(isOn: Binding(get: { assistant.selectedRecipients.contains(recipient.id) }, set: { selected in
                        if selected { assistant.selectedRecipients.insert(recipient.id) } else { assistant.selectedRecipients.remove(recipient.id) }
                    })) {
                        HStack { Text(recipient.name).fontWeight(.medium); Text(recipient.model + " · " + recipient.detail).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(assistant.isRunning)
                }
            }
            Text("Send the source shown below to the selected connections. API usage is billed separately. Grok account reviews may read the chosen folder; write requests are denied.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Review source · \(request.content.utf8.count.formatted()) bytes", isExpanded: $showSource) {
                LongMessageView(text: request.prompt, fontSize: 11, monospaced: true).frame(height: 170)
            }
            HStack {
                Button(assistant.answers.isEmpty ? "Send to selected AIs" : "Run again") { assistant.run() }
                    .buttonStyle(.borderedProminent).disabled(assistant.isRunning || assistant.selectedRecipients.isEmpty || model.isWorking)
                if assistant.isRunning { ProgressView().controlSize(.small); Button("Stop") { assistant.cancel() } }
                Spacer()
            }
        }
    }

    private var answerCards: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(assistant.answers) { answer in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(answer.name).font(.headline)
                            Text(answer.model).font(.caption).foregroundStyle(.secondary)
                            if let text = answer.text {
                                LongMessageView(text: text, fontSize: 13).frame(maxHeight: .infinity)
                                HStack {
                                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                                    if let onUse { Button("Use this draft") { onUse(text); dismiss() }.disabled(assistant.isRunning) }
                                }
                            } else if let error = answer.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            else { Text(assistant.isRunning ? "Waiting for answer…" : "No completed answer").foregroundStyle(.secondary) }
                        }.padding(14).frame(width: 340).frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(height: geometry.size.height)
            }
        }.frame(maxHeight: .infinity)
    }
}

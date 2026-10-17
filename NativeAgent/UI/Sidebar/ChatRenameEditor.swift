import SwiftUI

struct ChatRenameEditor: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let chat: Conversation
    @State private var title = ""
    @State private var request: UUID?
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                error = nil; request = UUID()
            } label: {
                HStack(spacing: 5) {
                    if request != nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "sparkles") }
                    Text(request == nil ? "Suggest name with AI" : "Reading conversation…")
                }.font(.system(size: 11, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Studio.accent)
                .disabled(request != nil || saving || model.titleSuggestionUnavailableReason != nil)
                .help(model.titleSuggestionUnavailableReason ?? "Use your connected ChatGPT model to name this conversation from its saved messages.")
            TextField(chat.title, text: $title)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(6).background(Studio.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Studio.accent.opacity(0.5)))
                .focused($focused).disabled(saving)
                .accessibilityLabel("New chat name")
                .onSubmit { save() }
                .onChange(of: title) { if request != nil { request = nil } }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let reason = model.titleSuggestionUnavailableReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { model.renamingConversationID = nil }.disabled(saving)
                Spacer(minLength: 4)
                Button(saving ? "Saving…" : "Save") { save() }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 11)).buttonStyle(.plain)
        }.padding(.leading, 37).padding(.trailing, 8).padding(.vertical, 9)
            .background(Studio.hover, in: RoundedRectangle(cornerRadius: 7))
            .onAppear { focused = true }
            .onExitCommand { if !saving { model.renamingConversationID = nil } }
            .task(id: request) {
                guard let token = request else { return }
                do {
                    let suggestion = try await model.suggestConversationTitle(chat)
                    try Task.checkCancellation()
                    guard request == token, model.renamingConversationID == chat.id else { return }
                    request = nil; title = suggestion; focused = true
                } catch {
                    guard !Task.isCancelled, request == token else { return }
                    request = nil; self.error = error.localizedDescription
                }
            }
    }

    private func save() {
        guard !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        request = nil; saving = true; error = nil
        Task {
            do {
                try await model.saveConversationTitle(chat.id, title: title)
                if model.renamingConversationID == chat.id { model.renamingConversationID = nil }
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

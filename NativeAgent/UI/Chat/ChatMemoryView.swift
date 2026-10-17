import SwiftUI

struct ChatMemoryView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var pins = ""
    @State private var memory = ConversationMemory()
    @State private var status: String?
    @State private var loaded = false
    let chat: UUID
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pinned instructions").font(.headline)
                Text("These stay with this chat and are sent with every request. Up to 8,000 characters.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pins).frame(height: 130).border(.quaternary)
                Button("Save pinned instructions") {
                    Task {
                        do {
                            try await model.database.saveFeature(pins, kind: "chat-pins", id: chat.uuidString, conversationID: chat)
                            status = "Pinned instructions saved."
                        } catch { status = error.localizedDescription }
                    }
                }.disabled(!loaded || model.isWorking || pins.count > 8_000)
                Divider()
                Text("Older conversation summary").font(.headline)
                Text("ChatGPT refreshes this automatically before sending when history outgrows the recent-message window. Summaries can lose details; pin exact requirements above. Summary requests use your connected model.").font(.caption).foregroundStyle(.secondary)
                Text(memory.summary.isEmpty ? "No summary needed yet." : memory.summary).textSelection(.enabled)
                Button("Clear summary and rebuild on next send") {
                    Task {
                        do { try await model.database.removeFeature(kind: "chat-memory", id: chat.uuidString); memory = ConversationMemory(); status = "Summary cleared. Original messages are unchanged." }
                        catch { status = error.localizedDescription }
                    }
                }.disabled(model.isWorking || !loaded)
                if let status { Text(status).font(.caption).textSelection(.enabled) }
            }.padding(2)
        }.task(id: chat) {
            loaded = false
            do {
                pins = try await model.database.feature(String.self, kind: "chat-pins", id: chat.uuidString) ?? ""
                memory = try await model.database.feature(ConversationMemory.self, kind: "chat-memory", id: chat.uuidString) ?? ConversationMemory()
                loaded = true
            } catch { status = error.localizedDescription }
        }
    }
}

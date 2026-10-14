import SwiftUI

struct ArchiveView: View {
    var automaticallyLoad = true
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox").font(.system(size: 25, weight: .light)).foregroundStyle(Studio.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archived chats").font(.title2.weight(.semibold))
                    Text("A little room to change your mind.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Restore a chat within 30 days of archiving. After that, its messages and draft are permanently deleted from this app’s library. Cleanup runs while the app is open or when it next launches. Provider histories and external backups are separate.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.archivedConversations.isEmpty && !model.archiveLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 32, weight: .light))
                            Text("Nothing archived").font(.headline)
                            Text("Right-click any chat and choose Archive chat.").font(.caption)
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    ForEach(model.archivedConversations) { chat in
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let expiry = chat.archiveExpiresAt {
                                    Text("Permanently deleted \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Restore") { Task { await model.restoreArchived(chat) } }.buttonStyle(.bordered)
                        }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.archiveLoading { ProgressView().controlSize(.small).padding() }
                    if model.archiveHasMore {
                        Button("Load older archived chats") { Task { await model.loadArchive(more: true) } }.disabled(model.archiveLoading).padding()
                    }
                }
            }
        }.padding(28).frame(width: 640, height: 520).background(Studio.canvas)
            .task { if automaticallyLoad { await model.loadArchive() } }
    }
}

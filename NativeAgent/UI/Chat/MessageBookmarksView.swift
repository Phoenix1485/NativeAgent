import SwiftUI

struct MessageBookmarkButton: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let entry: TimelineEntry
    let conversationID: UUID

    var body: some View {
        MessageBookmarkControl(tools: model.libraryTools, entry: entry, conversationID: conversationID)
            .tint(model.settings.accent.color)
    }
}

private struct MessageBookmarkControl: View {
    @ObservedObject var tools: LibraryToolsController
    let entry: TimelineEntry
    let conversationID: UUID
    @State private var editing = false
    @State private var label = ""
    private var existing: MessageBookmark? { tools.savedBookmarks[entry.id] }
    private var busy: Bool { tools.bookmarkOperationIDs.contains(entry.id) }

    var body: some View {
        Button {
            let defaultLabel = String(entry.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
            label = existing?.label ?? (defaultLabel.isEmpty ? entry.title : defaultLabel)
            editing = true
        } label: { Image(systemName: existing == nil ? "bookmark" : "bookmark.fill") }
            .buttonStyle(.borderless)
            .help(existing == nil ? "Bookmark this message" : "Edit message bookmark")
            .accessibilityLabel(existing == nil ? "Bookmark message" : "Edit bookmark")
            .disabled(entry.isStreaming || busy)
            .task(id: entry.id) { await tools.loadBookmark(entry.id) }
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(existing == nil ? "Bookmark message" : "Edit bookmark").font(.headline)
                    TextField("Label", text: $label).textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Text("Saved labels help you return to this exact message.").font(.caption).foregroundStyle(.secondary)
                    if let notice = tools.bookmarkNotice { Text(notice).font(.caption).foregroundStyle(.red) }
                    HStack {
                        if existing != nil {
                            Button("Remove", role: .destructive) { Task { await tools.removeBookmark(entry.id); editing = false } }
                        }
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Save") { save() }.buttonStyle(.borderedProminent)
                            .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 160)
                    }.disabled(busy)
                }.padding(18).frame(width: 340)
            }
    }

    private func save() {
        Task {
            if await tools.saveBookmark(messageID: entry.id, conversationID: conversationID, label: label) { editing = false }
        }
    }
}

struct MessageBookmarksView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject private var tools: LibraryToolsController
    @State private var search = ""

    init(model: WorkspaceViewModel) {
        self.model = model
        self.tools = model.libraryTools
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search labels, message excerpts, or chats", text: $search).textFieldStyle(.roundedBorder)
                Button { Task { await tools.loadBookmarks(search: search) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh bookmarks").disabled(tools.bookmarkLoading)
            }
            if let notice = tools.bookmarkNotice {
                HStack {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { tools.bookmarkNotice = nil }.buttonStyle(.borderless)
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if tools.bookmarks.isEmpty && !tools.bookmarkLoading {
                        VStack(spacing: 10) {
                            Image(systemName: "bookmark").font(.system(size: 28)).foregroundStyle(model.settings.accent.color)
                            Text(search.isEmpty ? "No saved messages yet" : "No bookmarks match your search").font(.headline)
                            Text("Use the bookmark button on a message to save it with a label.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(tools.bookmarks) { entry in
                        MessageBookmarkRow(entry: entry, model: model, tools: tools)
                    }
                    if tools.bookmarkLoading { ProgressView().controlSize(.small).padding() }
                    if tools.bookmarksHaveMore {
                        Button("Load more bookmarks") { Task { await tools.loadBookmarks(search: search, more: true) } }
                            .disabled(tools.bookmarkLoading)
                    }
                }
            }
            Text("Bookmarks stay with their chat and are removed when the chat is permanently deleted.").font(.caption).foregroundStyle(.secondary)
        }.tint(model.settings.accent.color)
            .task(id: search) { await tools.loadBookmarks(search: search) }
    }
}

private struct MessageBookmarkRow: View {
    let entry: MessageBookmarkEntry
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var tools: LibraryToolsController
    @State private var label = ""
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bookmark.fill").foregroundStyle(model.settings.accent.color)
                TextField("Bookmark label", text: $label).textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button("Save label") { save() }
                    .disabled(label == entry.bookmark.label || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 160)
            }
            Text(entry.bookmark.preview).lineLimit(3).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text(entry.conversationTitle + (entry.archived ? " · Archived" : "")).font(.caption).lineLimit(1)
                Spacer()
                if !entry.messageExists { Text("Original message unavailable").font(.caption).foregroundStyle(.secondary) }
                Button(entry.archived ? "Restore chat and open" : "Open original message") {
                    opening = true
                    Task { await tools.openBookmark(entry.bookmark, model: model); opening = false }
                }.disabled(!entry.messageExists || opening)
                Button("Remove", role: .destructive) { Task { await tools.removeBookmark(entry.id) } }
            }.controlSize(.small)
        }
        .padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
        .disabled(tools.bookmarkOperationIDs.contains(entry.id))
        .onAppear { label = entry.bookmark.label }
        .onChange(of: entry.bookmark.label) { label = entry.bookmark.label }
    }

    private func save() {
        Task { await tools.saveBookmark(messageID: entry.id, conversationID: entry.bookmark.conversationID, label: label) }
    }
}

import SwiftUI

struct StorageManagerView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject private var tools: LibraryToolsController
    @State private var query = ChatStorageQuery()
    @State private var section = "Chats"
    @State private var selectedChats: Set<UUID> = []
    @State private var selectedFiles: Set<String> = []
    @State private var visibleFiles = 50
    @State private var pending: StorageCleanupRequest?
    @State private var cleaning = false

    init(model: WorkspaceViewModel) {
        self.model = model
        self.tools = model.libraryTools
    }

    private var busy: Bool { cleaning || tools.storageBusy }
    private var selectedRows: [ChatStorageEntry] { tools.storageEntries.filter { selectedChats.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            HStack {
                Picker("Storage", selection: $section) {
                    ForEach(["Chats", "Backups & cache", "Upcoming deletions"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh storage sizes").disabled(busy || tools.storageRefreshing)
            }
            if let notice = tools.storageNotice {
                HStack {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { tools.storageNotice = nil }.buttonStyle(.borderless)
                }
            }
            switch section {
            case "Backups & cache": diskFiles
            case "Upcoming deletions": upcoming
            default: chats
            }
        }
        .tint(model.settings.accent.color)
        .task { await tools.refreshStorage() }
        .task(id: query) { selectedChats = []; await tools.loadStorage(query: query) }
        .alert(pending?.title ?? "Clean up storage?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { request in
            Button("Cancel", role: .cancel) { pending = nil }
            Button(request.action, role: request.kind == .archive ? nil : .destructive) {
                pending = nil
                Task { await perform(request) }
            }
        } message: { request in Text(request.message) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                metric("Chat payloads", bytes: tools.storageSummary.chatBytes)
                metric("Attachment payloads", bytes: tools.storageSummary.attachmentPayloadBytes)
                metric("Backups", bytes: tools.diskStorage.backupBytes)
                metric("Cache", bytes: tools.diskStorage.cacheBytes)
            }
            HStack {
                Text("\(tools.storageSummary.chatCount) chats · \(tools.storageSummary.archivedCount) archived · Database on disk: \(bytes(tools.diskStorage.databaseBytes))")
                Spacer()
                if tools.storageRefreshing { ProgressView().controlSize(.mini) }
            }.font(.caption).foregroundStyle(.secondary)
            Text("Attachment payloads are included in chats. Database size includes indexes and reusable free space; deleting chats makes that space available to new chats.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, bytes value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(bytes(value)).font(.system(size: 19, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Studio.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search chats", text: $query.search).textFieldStyle(.roundedBorder)
                Picker("Scope", selection: $query.scope) { ForEach(ChatStorageScope.allCases) { Text($0.title).tag($0) } }.frame(width: 125)
                Picker("Sort", selection: $query.sort) { ForEach(ChatStorageSort.allCases) { Text($0.title).tag($0) } }.frame(width: 165)
            }
            HStack {
                Button("Select loaded") {
                    selectedChats = Set(tools.storageEntries.filter { !protected($0.id) }.prefix(100).map(\.id))
                }
                Button("Clear") { selectedChats = [] }.disabled(selectedChats.isEmpty)
                Spacer()
                Text("\(selectedChats.count) selected").font(.caption)
                Button("Archive selected") {
                    pending = .init(kind: .archive, chats: selectedRows.filter { $0.conversation.archivedAt == nil })
                }.disabled(!selectedRows.contains { $0.conversation.archivedAt == nil })
                Button("Delete permanently…", role: .destructive) {
                    pending = .init(kind: .deleteChats, chats: selectedRows.filter { $0.conversation.archivedAt != nil })
                }.disabled(!selectedRows.contains { $0.conversation.archivedAt != nil })
            }.controlSize(.small).disabled(busy)
            ScrollView {
                LazyVStack(spacing: 7) {
                    if tools.storageEntries.isEmpty && !tools.storageLoading { empty("No chats match these filters.") }
                    ForEach(tools.storageEntries) { entry in
                        HStack(spacing: 10) {
                            Toggle("Select \(entry.conversation.title)", isOn: Binding(get: { selectedChats.contains(entry.id) }, set: { selected in
                                if selected && selectedChats.count < 100 { selectedChats.insert(entry.id) } else { selectedChats.remove(entry.id) }
                            })).labelsHidden().toggleStyle(.checkbox).disabled(busy || protected(entry.id))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.conversation.title).lineLimit(1)
                                Text(entry.conversation.archivedAt == nil ? "Active · Updated \(entry.conversation.updatedAt.formatted(date: .abbreviated, time: .omitted))" : "Archived · \(entry.conversation.archivedAt!.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if protected(entry.id) { Text("In use").font(.caption).foregroundStyle(.secondary) }
                            Text(bytes(entry.storedBytes)).font(.system(.caption, design: .monospaced))
                        }.padding(10).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if tools.storageLoading { ProgressView().controlSize(.small).padding() }
                    if tools.storageHasMore { Button("Load more chats") { Task { await tools.loadStorage(more: true) } }.disabled(tools.storageLoading) }
                }
            }
            Text("Archive active chats before deleting them permanently. The open chat and working chats are protected.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diskFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose individual backup or cache files to remove.").font(.callout)
                Spacer()
                Button("Clear selection") { selectedFiles = [] }.disabled(selectedFiles.isEmpty)
                Button("Delete \(selectedFiles.count) files…", role: .destructive) {
                    pending = .init(kind: .deleteFiles, files: tools.diskStorage.files.filter { selectedFiles.contains($0.id) })
                }.disabled(selectedFiles.isEmpty || busy || model.isWorking)
            }
            if tools.diskStorage.isPartial { Text("Showing a bounded scan of up to 10,000 entries. Sizes shown are a lower bound.").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 7) {
                    if tools.diskStorage.files.isEmpty { empty("No managed backup or cache files.") }
                    ForEach(Array(tools.diskStorage.files.prefix(visibleFiles))) { file in
                        HStack(spacing: 10) {
                            Toggle("Select \(file.url.lastPathComponent)", isOn: Binding(get: { selectedFiles.contains(file.id) }, set: { selected in
                                if selected && selectedFiles.count < 100 { selectedFiles.insert(file.id) } else { selectedFiles.remove(file.id) }
                            })).labelsHidden().toggleStyle(.checkbox).disabled(busy)
                            Image(systemName: file.kind == .backup ? "externaldrive" : "doc")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.url.lastPathComponent).lineLimit(1).help(file.url.path)
                                Text("\(file.kind.rawValue.capitalized) · \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bytes(file.bytes)).font(.system(.caption, design: .monospaced))
                        }.padding(10).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if visibleFiles < tools.diskStorage.files.count { Button("Load more files") { visibleFiles += 50 } }
                }
            }
            Text("Backup deletion removes that recovery copy. Cache files can be recreated. Select up to 100 files per cleanup.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next 20 archive cleanup dates. Large-chat dates depend on the archive count at cleanup; restoring chats can change them.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 7) {
                    if tools.upcomingDeletions.isEmpty { empty("No archived chats are scheduled for cleanup.") }
                    ForEach(tools.upcomingDeletions) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.conversation.title).lineLimit(1)
                                if let date = entry.deletionDate { Text("Eligible \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(bytes(entry.storedBytes)).font(.caption)
                            Button("Restore") { Task { await model.restoreArchived(entry.conversation); await refresh() } }
                                .disabled(busy || model.archiveOperationIDs.contains(entry.id))
                        }.padding(10).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let error = model.archiveError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func protected(_ id: UUID) -> Bool { model.selectedConversation?.id == id || model.chatIsWorking(id) }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(35) }

    private func refresh() async {
        await tools.refreshStorage()
        await tools.loadStorage(query: query)
    }

    private func perform(_ request: StorageCleanupRequest) async {
        cleaning = true
        defer { cleaning = false; selectedChats = []; selectedFiles = [] }
        switch request.kind {
        case .archive:
            for entry in request.chats where !protected(entry.id) { await model.archive(entry.conversation) }
            await refresh()
        case .deleteChats:
            let protectedIDs = Set(request.chats.filter { protected($0.id) }.map(\.id))
            await tools.deleteArchivedChats(request.chats, protectedIDs: protectedIDs)
            await model.loadArchive()
        case .deleteFiles:
            guard !model.isWorking else { tools.storageNotice = "Wait for the current task before cleaning up files."; return }
            await tools.deleteStorageFiles(request.files)
        }
    }
}

private struct StorageCleanupRequest {
    enum Kind { case archive, deleteChats, deleteFiles }
    var kind: Kind
    var chats: [ChatStorageEntry] = []
    var files: [LibraryStorageFile] = []
    var count: Int { kind == .deleteFiles ? files.count : chats.count }
    var title: String {
        switch kind { case .archive: "Archive \(count) chats?"; case .deleteChats: "Permanently delete \(count) chats?"; case .deleteFiles: "Permanently delete \(count) storage files?" }
    }
    var action: String { kind == .archive ? "Archive \(count) chats" : "Delete \(count) permanently" }
    var message: String {
        let names = kind == .deleteFiles ? files.map { $0.url.lastPathComponent } : chats.map { $0.conversation.title }
        let list = names.prefix(8).map { "• " + $0 }.joined(separator: "\n") + (count > 8 ? "\n…and \(count - 8) more" : "")
        let explanation: String
        switch kind {
        case .archive: explanation = "These chats will leave the sidebar and follow the archive recovery policy."
        case .deleteChats: explanation = "Their saved messages, drafts, bookmarks, and attachment copies will be removed permanently. Original workspace files and backups are kept."
        case .deleteFiles: explanation = "These exact backup or cache files will be removed. This cannot be undone."
        }
        return explanation + "\n\n" + list
    }
}

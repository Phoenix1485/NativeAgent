import SwiftUI

enum ArchiveDateFilter: String, CaseIterable, Identifiable {
    case any, lastWeek, lastTwoWeeks, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any date"
        case .lastWeek: "Last 7 days"
        case .lastTwoWeeks: "Last 14 days"
        case .custom: "Date range…"
        }
    }

    func query(search: String, from: Date, through: Date, now: Date, calendar: Calendar = .current) -> ArchiveQuery {
        let today = calendar.startOfDay(for: now)
        let start: Date?
        let end: Date?
        switch self {
        case .any:
            start = nil; end = nil
        case .lastWeek, .lastTwoWeeks:
            start = calendar.date(byAdding: .day, value: self == .lastWeek ? -6 : -13, to: today)
            end = calendar.date(byAdding: .day, value: 1, to: today)
        case .custom:
            start = calendar.startOfDay(for: from)
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through))
        }
        return ArchiveQuery(search: search.trimmingCharacters(in: .whitespacesAndNewlines), archivedFrom: start, archivedBefore: end)
    }
}

struct ArchiveView: View {
    var automaticallyLoad = true
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var dateFilter: ArchiveDateFilter = .any
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now
    @State private var throughDate = Date.now
    @State private var filterNow = Date.now
    @State private var ready = false
    @State private var pendingDeletion: Conversation?

    private var accent: Color { model.settings.accent.color }
    private var query: ArchiveQuery { dateFilter.query(search: search, from: fromDate, through: throughDate, now: filterNow) }
    private var isFiltered: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dateFilter != .any }
    private var sizeThreshold: String { ByteCountFormatter.string(fromByteCount: ArchiveRetention.largeChatBytes, countStyle: .memory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Chats are kept for up to 30 days. When more than 30 are archived, chats with at least \(sizeThreshold) of stored content can be deleted after 20 days, oldest first, until 30 remain. Cleanup runs on launch and while the app is open.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            filters
            Divider()
            if let error = model.archiveError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await model.loadArchive(query: query) } }.disabled(model.archiveLoading)
                }.font(.caption).foregroundStyle(.red)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.archiveEntries.isEmpty && !model.archiveLoading {
                        emptyState
                    }
                    ForEach(model.archiveEntries) { entry in archiveRow(entry) }
                    if model.archiveLoading { ProgressView().controlSize(.small).padding() }
                    if model.archiveHasMore {
                        Button("Load more archived chats") { Task { await model.loadArchive(query: query, more: true) } }
                            .disabled(model.archiveLoading).padding(8)
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                Text(isFiltered ? "\(model.archiveEntries.count) matching chats loaded" : "\(model.archiveEntries.count) of \(model.archiveTotalCount) archived chats")
                Spacer()
                Text("Provider history and backups are separate.")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 700, height: 620).background(Studio.canvas)
        .tint(accent).accentColor(accent).preferredColorScheme(model.settings.theme.scheme)
        .task {
            guard automaticallyLoad else { return }
            await model.openArchive()
            ready = true
        }
        .task(id: ready ? query : nil) {
            guard ready, automaticallyLoad else { return }
            await model.loadArchive(query: query)
        }
        .alert("Permanently delete this chat?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { chat in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete permanently", role: .destructive) {
                pendingDeletion = nil
                Task { await model.deleteArchived(chat) }
            }
        } message: { chat in
            Text("“\(chat.title)” and its saved messages, draft, and attachment copies will be removed from this app’s library. This cannot be undone. Original files, provider history, and backups are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox").font(.system(size: 25, weight: .light)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Archived chats").font(.title2.weight(.semibold))
                Text("Find, restore, or permanently delete a chat.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ArchiveActionStyle(color: accent))
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search archived chat titles", text: $search)
                        .textFieldStyle(.plain).accessibilityLabel("Search archived chat titles")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear archive search")
                    }
                }.padding(9).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                Picker("Archived", selection: $dateFilter) {
                    ForEach(ArchiveDateFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }.pickerStyle(.menu).fixedSize()
            }.font(.system(size: 12))
            if dateFilter == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $fromDate, in: ...throughDate, displayedComponents: .date)
                    DatePicker("Through", selection: $throughDate, in: fromDate..., displayedComponents: .date)
                    Spacer()
                    Button("Clear filters") { search = ""; dateFilter = .any }.buttonStyle(.borderless)
                }.font(.caption)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isFiltered ? "magnifyingglass" : "tray").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
            Text(isFiltered ? "No matching chats" : "Nothing archived").font(.headline)
            Text(isFiltered ? "Try another title or archive date." : "Right-click a chat and choose Archive chat.").font(.caption)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 65)
    }

    private func archiveRow(_ entry: ArchivedConversation) -> some View {
        let chat = entry.conversation
        let busy = model.archiveOperationIDs.contains(chat.id)
        return HStack(spacing: 12) {
            Image(systemName: "bubble.left").foregroundStyle(accent.opacity(0.8))
            VStack(alignment: .leading, spacing: 5) {
                Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1).help(chat.title)
                if let archivedAt = chat.archivedAt {
                    Text("Archived \(archivedAt.formatted(date: .abbreviated, time: .omitted)) · \(ByteCountFormatter.string(fromByteCount: entry.storedBytes, countStyle: .memory))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    let expiry = ArchiveRetention.deletionDate(archivedAt: archivedAt, storedBytes: entry.storedBytes, archiveCount: model.archiveTotalCount)
                    Text("Automatic deletion from \(expiry.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            if busy { ProgressView().controlSize(.small) }
            Button("Restore") { Task { await model.restoreArchived(chat) } }
                .buttonStyle(ArchiveActionStyle(color: accent)).disabled(busy)
            Button(role: .destructive) { pendingDeletion = chat } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(busy)
                .help("Permanently delete this chat now").accessibilityLabel("Permanently delete \(chat.title)")
        }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ArchiveActionStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.45)
    }
}

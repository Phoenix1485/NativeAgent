import Combine
import Foundation

@MainActor
final class LibraryToolsController: ObservableObject {
    let database: DatabaseActor
    private let cacheRoot: URL?
    private var fileService: LibraryStorageFiles?
    @Published private(set) var storageSummary = LibraryStorageSummary()
    @Published private(set) var diskStorage = LibraryDiskStorage()
    @Published private(set) var storageEntries: [ChatStorageEntry] = []
    @Published private(set) var upcomingDeletions: [ChatStorageEntry] = []
    @Published private(set) var storageQuery = ChatStorageQuery()
    @Published private(set) var storageLoading = false
    @Published private(set) var storageRefreshing = false
    @Published private(set) var storageHasMore = false
    @Published private(set) var storageBusy = false
    @Published var storageNotice: String?
    @Published private(set) var bookmarks: [MessageBookmarkEntry] = []
    @Published private(set) var savedBookmarks: [UUID: MessageBookmark] = [:]
    @Published private(set) var bookmarkLoading = false
    @Published private(set) var bookmarksHaveMore = false
    @Published private(set) var bookmarkOperationIDs: Set<UUID> = []
    @Published var bookmarkNotice: String?
    private var storageVersion = UUID()
    private var bookmarkVersion = UUID()
    private var bookmarkQuery = ""
    private let storageSummaryLoader: @Sendable () async throws -> LibraryStorageSummary
    private var storageRefreshTask: Task<Void, Never>?
    private var storageRefreshRequested = false

    init(database: DatabaseActor, cacheRoot: URL? = nil, storageSummaryLoader: (@Sendable () async throws -> LibraryStorageSummary)? = nil) {
        self.database = database
        self.cacheRoot = cacheRoot
        self.storageSummaryLoader = storageSummaryLoader ?? { try await database.libraryStorageSummary() }
    }

    func refreshStorage() async {
        storageRefreshRequested = true
        if let storageRefreshTask {
            await storageRefreshTask.value
            return
        }
        storageRefreshing = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStorageRefreshes()
        }
        storageRefreshTask = task
        await task.value
    }

    private func performStorageRefreshes() async {
        defer { storageRefreshTask = nil; storageRefreshing = false }
        repeat {
            storageRefreshRequested = false
            do {
                storageSummary = try await storageSummaryLoader()
                upcomingDeletions = try await database.upcomingArchiveDeletions()
                let files = await storageFiles()
                diskStorage = try await files.inventory()
            } catch is CancellationError { }
            catch { storageNotice = error.localizedDescription }
        } while storageRefreshRequested && !Task.isCancelled
    }

    func loadStorage(query: ChatStorageQuery? = nil, more: Bool = false) async {
        let request = query ?? storageQuery
        if more && (storageLoading || !storageHasMore || request != storageQuery) { return }
        let changed = request != storageQuery
        let version = UUID(); storageVersion = version; storageQuery = request
        let cursor = more ? storageEntries.last : nil
        if changed { storageEntries = [] }
        if !more { storageHasMore = false }
        storageLoading = true
        defer { if version == storageVersion { storageLoading = false } }
        do {
            if changed { try await Task.sleep(for: .milliseconds(250)) }
            let page = try await database.chatStoragePage(query: request, after: cursor)
            guard !Task.isCancelled, storageVersion == version else { return }
            if !more { storageEntries = [] }
            let existing = Set(storageEntries.map(\.id))
            storageEntries += page.filter { !existing.contains($0.id) }
            storageHasMore = page.count == 50
        } catch is CancellationError { }
        catch { if version == storageVersion { storageNotice = error.localizedDescription } }
    }

    func deleteArchivedChats(_ chats: [ChatStorageEntry], protectedIDs: Set<UUID>) async {
        guard !storageBusy else { return }
        guard chats.count <= 100 else { storageNotice = "Select at most 100 chats at a time."; return }
        storageBusy = true
        defer { storageBusy = false }
        var removed = 0
        do {
            for chat in chats where chat.conversation.archivedAt != nil && !protectedIDs.contains(chat.id) {
                if try await database.deleteArchivedConversation(id: chat.id) { removed += 1 }
            }
            storageNotice = "Permanently deleted \(removed) archived \(removed == 1 ? "chat" : "chats")."
        } catch { storageNotice = "Deleted \(removed) chats. \(error.localizedDescription)" }
        await loadStorage()
        await refreshStorage()
        await loadBookmarks()
    }

    func deleteStorageFiles(_ files: [LibraryStorageFile]) async {
        guard !storageBusy else { return }
        storageBusy = true
        defer { storageBusy = false }
        do {
            let service = await storageFiles()
            let deleted = try await service.delete(files)
            storageNotice = "Deleted \(deleted) selected storage \(deleted == 1 ? "file" : "files")."
        } catch { storageNotice = error.localizedDescription }
        await refreshStorage()
    }

    private func storageFiles() async -> LibraryStorageFiles {
        if let fileService { return fileService }
        let service = LibraryStorageFiles(databaseURL: await database.libraryStorageURL(), cacheRoot: cacheRoot)
        fileService = service
        return service
    }

    func loadBookmark(_ messageID: UUID) async {
        do {
            savedBookmarks[messageID] = try await database.feature(MessageBookmark.self, kind: "message-bookmark", id: messageID.uuidString)
        } catch { bookmarkNotice = error.localizedDescription }
    }

    func loadBookmarks(search: String? = nil, more: Bool = false, preservingLoadedPages: Bool = false) async {
        let query = search ?? bookmarkQuery
        if more && (bookmarkLoading || !bookmarksHaveMore || query != bookmarkQuery) { return }
        let changed = query != bookmarkQuery
        let version = UUID(); bookmarkVersion = version; bookmarkQuery = query
        let cursor = more ? bookmarks.last?.bookmark : nil
        let pageCount = preservingLoadedPages && !changed && !more ? max(1, (bookmarks.count + 49) / 50) : 1
        if changed { bookmarks = [] }
        if !more { bookmarksHaveMore = false }
        bookmarkLoading = true
        defer { if bookmarkVersion == version { bookmarkLoading = false } }
        do {
            if changed { try await Task.sleep(for: .milliseconds(250)) }
            var entries: [MessageBookmarkEntry] = []
            var nextCursor = cursor
            var hasMore = false
            for _ in 0..<pageCount {
                let page = try await database.messageBookmarkPage(search: query, after: nextCursor)
                guard !Task.isCancelled, version == bookmarkVersion else { return }
                entries += page
                hasMore = page.count == 50
                if !hasMore { break }
                nextCursor = page.last?.bookmark
            }
            if !more { bookmarks = [] }
            let existing = Set(bookmarks.map(\.id))
            bookmarks += entries.filter { !existing.contains($0.id) }
            for entry in entries { savedBookmarks[entry.id] = entry.bookmark }
            bookmarksHaveMore = hasMore
        } catch is CancellationError { }
        catch { if version == bookmarkVersion { bookmarkNotice = error.localizedDescription } }
    }

    @discardableResult
    func saveBookmark(messageID: UUID, conversationID: UUID, label: String) async -> Bool {
        guard !bookmarkOperationIDs.contains(messageID) else { return false }
        bookmarkOperationIDs.insert(messageID)
        defer { bookmarkOperationIDs.remove(messageID) }
        do {
            savedBookmarks[messageID] = try await database.saveMessageBookmark(conversationID: conversationID, messageID: messageID, label: label)
            bookmarkNotice = nil
            await loadBookmarks(preservingLoadedPages: true)
            return true
        } catch { bookmarkNotice = error.localizedDescription; return false }
    }

    func removeBookmark(_ messageID: UUID) async {
        guard !bookmarkOperationIDs.contains(messageID) else { return }
        bookmarkOperationIDs.insert(messageID)
        defer { bookmarkOperationIDs.remove(messageID) }
        do {
            try await database.removeFeature(kind: "message-bookmark", id: messageID.uuidString)
            savedBookmarks[messageID] = nil
            bookmarks.removeAll { $0.id == messageID }
            bookmarkNotice = nil
            await loadBookmarks(preservingLoadedPages: true)
        } catch { bookmarkNotice = error.localizedDescription }
    }

    func openBookmark(_ bookmark: MessageBookmark, model: WorkspaceViewModel) async {
        do {
            guard let chat = try await database.bookmarkedConversation(messageID: bookmark.messageID, conversationID: bookmark.conversationID) else {
                bookmarkNotice = "The original message was removed. You can remove this bookmark."
                await loadBookmarks()
                return
            }
            if chat.archivedAt != nil {
                await model.restoreArchived(chat)
                guard let restored = try await database.conversation(id: chat.id), restored.archivedAt == nil else {
                    bookmarkNotice = model.archiveError ?? "This chat can no longer be restored."
                    return
                }
            }
            await model.features.openConversation(chat.id)
            guard model.selectedConversation?.id == chat.id else { bookmarkNotice = "The original chat could not be opened."; return }
            await model.navigateToMessage(bookmark.messageID)
            model.features.panel = nil
            bookmarkNotice = nil
        } catch { bookmarkNotice = error.localizedDescription }
    }
}

import Foundation
import XCTest
import CSQLite
@testable import NativeAgent

final class LibraryTests: XCTestCase {
    func testNestedGroupsStandaloneChatsAndMovesSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite3")
        let database = try DatabaseActor(url: url)
        let project = Project(name: "App", canonicalPath: directory.path)
        try await database.save(project: project)
        let root = ChatGroup(projectID: project.id, name: "My app")
        let child = ChatGroup(parentID: root.id, name: "Frontend")
        let nested = ChatGroup(parentID: child.id, name: "Design")
        try await database.save(group: root)
        try await database.save(group: child)
        try await database.save(group: nested)
        let standalone = Conversation(title: "Loose ideas")
        var grouped = Conversation(projectID: project.id, groupID: root.id, title: "Build it")
        try await database.save(conversation: standalone)
        try await database.save(conversation: grouped)
        try await database.saveDraft("draft before move", conversationID: grouped.id)
        grouped.groupID = nested.id
        try await database.save(conversation: grouped)
        let reopened = try DatabaseActor(url: url)
        let groups = try await reopened.groups()
        let chats = try await reopened.conversations()
        let draft = try await reopened.draft(conversationID: grouped.id)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.id == nested.id }?.parentID, child.id)
        XCTAssertEqual(chats.first { $0.id == grouped.id }?.groupID, nested.id)
        XCTAssertEqual(chats.first { $0.id == grouped.id }?.projectID, project.id)
        XCTAssertNil(chats.first { $0.id == standalone.id }?.projectID)
        XCTAssertNil(chats.first { $0.id == standalone.id }?.groupID)
        XCTAssertEqual(draft, "draft before move")
        grouped.groupID = nil
        try await reopened.save(conversation: grouped)
        let movedBack = try await reopened.conversations()
        XCTAssertNil(movedBack.first { $0.id == grouped.id }?.groupID)
    }

    func testCyclesAndRemovingPopulatedGroupsAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        var parent = ChatGroup(name: "Parent")
        let child = ChatGroup(parentID: parent.id, name: "Child")
        try await database.save(group: parent)
        try await database.save(group: child)
        parent.parentID = child.id
        do { try await database.save(group: parent); XCTFail("Must reject cycles") } catch { }
        do { try await database.removeEmptyGroup(id: parent.id); XCTFail("Must preserve children") } catch { }
        try await database.removeEmptyGroup(id: child.id)
        let remaining = try await database.groups()
        XCTAssertEqual(remaining.map(\.id), [parent.id])
    }

    @MainActor
    func testChatsInheritFolderAndStandaloneDraftSurvivesNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let suite = "NativeAgentTests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: CodexProvider(binaryPath: "/does-not-exist"), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: preferences)
        let saved = await model.saveGroup(name: "App", parentID: nil, folder: directory)
        XCTAssertTrue(saved)
        let root = try XCTUnwrap(model.groups.first)
        let childSaved = await model.saveGroup(name: "Frontend", parentID: root.id, folder: nil)
        XCTAssertTrue(childSaved)
        let child = try XCTUnwrap(model.groups.first { $0.parentID == root.id })
        await model.newConversation(in: child.id)
        XCTAssertEqual(model.selectedConversation?.projectID, root.projectID)
        XCTAssertEqual(model.selectedProject?.canonicalPath, directory.resolvingSymlinksInPath().path)
        let grouped = try XCTUnwrap(model.selectedConversation)
        // The global action creates a standalone chat even when a group has an empty chat.
        await model.newConversation()
        XCTAssertNotEqual(model.selectedConversation?.id, grouped.id)
        XCTAssertNil(model.selectedConversation?.groupID)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Start this chat"), conversationID: grouped.id)
        await model.newConversation()
        let standalone = try XCTUnwrap(model.selectedConversation)
        XCTAssertNil(standalone.groupID)
        XCTAssertNil(standalone.projectID)
        model.draft = "Do not lose this"
        await model.selectGroup(root.id)
        await model.select(standalone)
        XCTAssertEqual(model.draft, "Do not lose this")
        XCTAssertEqual(model.connectionStatus, .disconnected)
    }

    func testV1MigrationPreservesExistingChatHistoryAndDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite3")
        let projectID = UUID(), chatID = UUID(), entryID = UUID()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let fixture = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY,applied_at REAL NOT NULL);
        INSERT INTO schema_migrations VALUES(1,1);
        CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,canonical_path TEXT NOT NULL UNIQUE,created_at REAL NOT NULL,last_opened_at REAL NOT NULL);
        CREATE TABLE conversations(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,remote_thread_id TEXT,title TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL);
        CREATE TABLE drafts(conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,text TEXT NOT NULL,updated_at REAL NOT NULL);
        CREATE TABLE timeline_items(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,turn_id TEXT,kind TEXT,title TEXT,display_text TEXT,metadata_json TEXT,received_order INTEGER,created_at REAL,is_streaming INTEGER);
        CREATE TABLE provider_profiles(id TEXT PRIMARY KEY,provider_kind TEXT NOT NULL,display_name TEXT NOT NULL,binary_path TEXT,account_namespace TEXT,last_known_version TEXT);
        CREATE TABLE turns(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,remote_turn_id TEXT,status TEXT NOT NULL,started_at REAL NOT NULL,finished_at REAL,error_code TEXT);
        CREATE TABLE approval_records(id TEXT PRIMARY KEY,turn_id TEXT,provider_request_id TEXT NOT NULL,kind TEXT NOT NULL,summary TEXT,decision TEXT,resolved_at REAL);
        CREATE TABLE context_references(id TEXT PRIMARY KEY,timeline_item_id TEXT NOT NULL,relative_path TEXT NOT NULL,start_line INTEGER,end_line INTEGER,content_hash TEXT,snippet TEXT);
        CREATE TABLE attachments(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,file_name TEXT NOT NULL,mime_type TEXT,relative_storage_path TEXT NOT NULL,size_bytes INTEGER NOT NULL,content_hash TEXT);
        INSERT INTO projects VALUES('\(projectID)','Legacy','/tmp/legacy',1,1);
        INSERT INTO conversations VALUES('\(chatID)','\(projectID)','remote-123','Existing chat',1,1);
        INSERT INTO drafts VALUES('\(chatID)','Keep this draft',1);
        INSERT INTO timeline_items VALUES('\(entryID)','\(chatID)',NULL,'userMessage','You','Keep this history',NULL,1,1,0);
        """
        XCTAssertEqual(sqlite3_exec(connection, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        let database = try DatabaseActor(url: url)
        let chats = try await database.conversations()
        let history = try await database.timeline(conversationID: chatID)
        let draft = try await database.draft(conversationID: chatID)
        XCTAssertEqual(chats.first?.remoteThreadID, "remote-123")
        XCTAssertEqual(chats.first?.projectID, projectID)
        XCTAssertEqual(history.first?.text, "Keep this history")
        XCTAssertEqual(draft, "Keep this draft")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("legacy.before-library-v2.sqlite3").path))
        try await database.save(conversation: Conversation(title: "New standalone chat"))
        let updated = try await database.conversations()
        XCTAssertEqual(updated.count, 2)
        try await database.archiveConversation(id: chatID)
        let archive = try await database.archivePage()
        XCTAssertEqual(archive.first?.storedBytes, Int64("YouKeep this historyKeep this draft".utf8.count))
        let restored = try await database.restoreConversation(id: chatID)
        XCTAssertTrue(restored)
    }
}

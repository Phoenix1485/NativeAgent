import SwiftUI
import AppKit

struct BackupSettingsView: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var automatic = true
    @State private var backups: [URL] = []
    @State private var status: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library backups").font(.headline)
            Toggle("Automatic daily local backups", isOn: $automatic)
                .onChange(of: automatic) { model.features.defaults.set(automatic, forKey: "automaticLibraryBackups") }
            Text("Keeps 7 daily copies while the app is running. Manual and pre-restore copies are kept until you remove them. Backups include chats, drafts, attachments and project profiles—not Keychain login credentials. They are not encrypted; store them privately.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back up now") { Task { await backup() } }
                Button("Restore backup…") { chooseRestore() }
                if let latest = backups.first { Button("Show backups in Finder") { NSWorkspace.shared.activateFileViewerSelecting([latest]) } }
            }.disabled(busy || model.isWorking || model.features.editorHasChanges || model.features.fileSaveInProgress)
            if let latest = backups.first {
                Text("Latest: \(latest.lastPathComponent)").font(.caption).textSelection(.enabled)
            } else { Text("No local backups yet.").font(.caption) }
            if let status { Text(status).font(.caption).textSelection(.enabled) }
        }.task {
            automatic = model.features.defaults.object(forKey: "automaticLibraryBackups") as? Bool ?? true
            do { backups = try await model.database.libraryBackups() } catch { status = error.localizedDescription }
        }
    }
    private func backup() async {
        busy = true; defer { busy = false }
        await model.saveDraft()
        await model.flushPendingPersistence()
        do { backups = try await model.database.backupLibrary(); status = "Backup verified and saved locally." }
        catch { status = error.localizedDescription }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a NativeAgent .sqlite3 backup. Restore takes effect on the next launch."
        if let latest = backups.first { panel.directoryURL = latest.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Restore this library on next launch?"
        alert.informativeText = "The backup will replace chats, drafts and project data. A safety backup of your current library will be kept. Login credentials are unchanged. Quit and reopen NativeAgent after staging the restore."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Stage restore")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await model.database.stageLibraryRestore(from: url); status = "Restore staged. Quit and reopen NativeAgent to apply it. Current library is unchanged until then." }
            catch { status = error.localizedDescription }
        }
    }
}

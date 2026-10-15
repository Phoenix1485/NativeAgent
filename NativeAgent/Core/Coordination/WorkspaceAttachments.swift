import AppKit
import Foundation

extension WorkspaceFeaturesController {
    func chooseAttachments() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Attach UTF-8 text or code files (up to 1 MiB total). Contents are sent with your next message."
        guard panel.runModal() == .OK else { return }
        await attachURLs(panel.urls)
    }

    func attachURLs(_ urls: [URL]) async {
        guard !importingFiles, let model, !model.isWorking else { return }
        importingFiles = true
        defer { importingFiles = false }
        if model.selectedConversation == nil { await model.newConversation() }
        guard let owner = model.selectedConversation?.id else { return }
        guard urls.count <= 24 else { notice = "Attach at most 24 files at once."; return }
        for url in urls {
            do {
                let file = try await attachedFiles.load(url)
                guard model.selectedConversation?.id == owner, contextOwner == owner else {
                    notice = "Conversation changed. Remaining files were not attached."; return
                }
                if context.contains(where: { $0.sourceURL == file.url.path }) { continue }
                await addContext(.init(kind: .attachment, title: file.url.lastPathComponent, text: file.text,
                    path: file.url.path, sourceHash: file.hash, metadata: "UTF-8 · \(file.data.count) bytes · user-selected file",
                    sourceURL: file.url.path, allowEdits: false))
            } catch { notice = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    func setFileEditable(_ id: UUID, enabled: Bool) async {
        guard model?.isWorking == false, let index = context.firstIndex(where: { $0.id == id }), context[index].sourceURL != nil else { return }
        context[index].allowEdits = enabled
        do { try await saveContext() } catch { fail(error) }
    }

    func openFileEditor(_ url: URL) async {
        do { editingFile = try await attachedFiles.load(url); editorHasChanges = false }
        catch { fail(error) }
    }

    func refreshAttachment(_ file: AttachedFileSnapshot, owner: UUID?) async throws {
        guard let owner else { return }
        var values = owner == contextOwner ? context : (try await database.feature([ContextAttachment].self, kind: "context", id: owner.uuidString) ?? [])
        for index in values.indices where values[index].sourceURL == file.url.path {
            values[index].text = file.text; values[index].sourceHash = file.hash; values[index].stale = false
            values[index].metadata = "UTF-8 · \(file.data.count) bytes · saved by NativeAgent"
        }
        guard values.reduce(0, { $0 + $1.text.utf8.count }) <= 1_048_576 else {
            throw NativeAgentError.unsupported("File saved, but refreshed attachments exceed 1 MiB. Remove an attachment and reattach before sending.")
        }
        try await database.saveFeature(values, kind: "context", id: owner.uuidString, conversationID: owner)
        if contextOwner == owner { context = values }
    }

    func nativeTools(access: WorkspaceAccess, attachments: [ContextAttachment], owner: UUID?) async throws -> [NativeTool] {
        var result = mcp.toolBindings()
        if access == .workspaceWrite {
            for item in attachments where item.allowEdits == true {
                guard let path = item.sourceURL else { continue }
                let snapshot = try await attachedFiles.load(URL(fileURLWithPath: path))
                guard snapshot.hash == item.sourceHash else { throw NativeAgentError.unsupported("\(item.title) changed on disk. Reattach before allowing edits.") }
                let session = AttachedEditSession(snapshot: snapshot, service: attachedFiles) { [weak self] saved in
                    try await self?.refreshAttachment(saved, owner: owner)
                }
                result.append(NativeTool(name: "edit_" + item.id.uuidString.replacingOccurrences(of: "-", with: ""),
                    description: "Replace one unique exact text segment in the explicitly attached file \(item.title) (\(path)). Requires user review. No other files can be edited.",
                    schema: .object(["type": .string("object"), "properties": .object([
                        "old_text": .object(["type": .string("string")]), "new_text": .object(["type": .string("string")])]),
                        "required": .array([.string("old_text"), .string("new_text")]), "additionalProperties": .bool(false)])) { arguments in
                        try await session.prepare(arguments)
                    })
            }
        }
        guard result.count <= 128 else { throw NativeAgentError.unsupported("Disconnect some MCP servers: at most 128 tools can be exposed in one request.") }
        return result
    }
}

private actor AttachedEditSession {
    private var snapshot: AttachedFileSnapshot
    private let service: AttachedFileService
    private let saved: @Sendable (AttachedFileSnapshot) async throws -> Void
    init(snapshot: AttachedFileSnapshot, service: AttachedFileService, saved: @escaping @Sendable (AttachedFileSnapshot) async throws -> Void) {
        self.snapshot = snapshot; self.service = service; self.saved = saved
    }
    func prepare(_ arguments: JSONValue) throws -> PreparedNativeTool {
        guard let old = arguments["old_text"]?.stringValue, let new = arguments["new_text"]?.stringValue,
              Set(arguments.objectValue?.keys.map { $0 } ?? []) == Set(["old_text", "new_text"]) else {
            throw NativeAgentError.unsupported("File edits require only old_text and new_text strings.")
        }
        let baseline = snapshot
        let replacement = try AttachedFileService.replacing(baseline, old: old, new: new)
        return PreparedNativeTool(title: "Edit \(baseline.url.lastPathComponent)",
            review: "File: \(baseline.url.path)\n\nREPLACE THIS EXACT TEXT:\n\(old)\n\nWITH:\n\(new)\n\nSaving checks that the complete file has not changed since it was attached.", changedPath: baseline.url.path) {
                try Task.checkCancellation()
                return try await self.apply(baseline, replacement: replacement)
            }
    }
    private func apply(_ baseline: AttachedFileSnapshot, replacement: String) async throws -> String {
        let updated = try await service.save(baseline, text: replacement)
        snapshot = updated
        do { try await saved(updated) }
        catch { return "File saved: \(updated.url.path). Attachment refresh needs attention: \(error.localizedDescription)" }
        return "File saved: \(updated.url.path). SHA-256: \(updated.hash)"
    }
}

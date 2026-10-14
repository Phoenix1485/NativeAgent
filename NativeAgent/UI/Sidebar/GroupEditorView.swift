import AppKit
import SwiftUI

struct GroupEditorView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let request: GroupEditorRequest
    @State private var name = ""
    @State private var folder: URL?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "folder.badge.plus").font(.system(size: 24)).foregroundStyle(Studio.accent)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(request.editing != nil ? "Edit group" : (request.parentID == nil ? "Create a group" : "Add a folder")).font(.system(size: 23, weight: .semibold))
                Text(request.parentID.map { "Inside \(model.groupPath($0))" } ?? "A home for related chats and folders.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("NAME").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                TextField("e.g. My app, Frontend, Ideas", text: $name).textFieldStyle(.plain).padding(12)
                    .background(Studio.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.line)).focused($focused)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("WORKING FOLDER").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Button(action: chooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(Studio.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder?.lastPathComponent ?? inherited?.name ?? "Choose a folder…").font(.system(size: 13, weight: .medium))
                            Text(folder?.path ?? inherited?.canonicalPath ?? "Optional · choose one now or in a chat").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
                    }.padding(13).background(Studio.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.line))
                }.buttonStyle(.plain)
                Text(request.parentID == nil ? "Chats and nested folders inherit this location." : "Uses the parent folder unless you select another location.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : (request.editing == nil ? "Create" : "Save changes")) {
                    saving = true
                    Task {
                        if await model.saveGroup(name: name, parentID: request.parentID, folder: folder, editing: request.editing) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }.padding(28).frame(width: 430).background(Studio.canvas).tint(Studio.accent)
            .onAppear { name = request.editing?.name ?? ""; focused = true }
    }

    private var inherited: Project? { model.project(for: request.editing?.id ?? request.parentID) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if let inherited { panel.directoryURL = URL(fileURLWithPath: inherited.canonicalPath) }
        if panel.runModal() == .OK { folder = panel.url; if name.isEmpty { name = folder?.lastPathComponent ?? "" } }
    }
}

import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var model: WorkspaceViewModel

    var body: some View {
        VSplitView {
            List {
                ForEach(model.rootFiles) { node in FileTreeNodeView(node: node) }
            }
            .frame(minHeight: 160)

            if let preview = model.filePreview {
                VStack(spacing: 0) {
                    HStack {
                        Text(preview.relativePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Edit…") {
                            guard let root = model.selectedProject?.canonicalPath else { return }
                            Task { await model.features.openFileEditor(URL(fileURLWithPath: root).appendingPathComponent(preview.relativePath)) }
                        }.disabled(model.isWorking).help("Open the complete UTF-8 file in the editor (up to 1 MiB)")
                        Menu("Code actions") {
                            ForEach(["Explain this code", "Review for bugs", "Suggest improvements", "Refactor", "Generate tests", "Generate documentation"], id: \.self) { action in
                                Button(action) { Task { await model.features.prepareCodeAction(action) } }
                            }
                        }.disabled(model.features.selectedCode.isEmpty || !model.providerCapabilities.structuredStreaming)
                        Text("\(preview.encodingName) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                    }.padding(7)
                    Divider()
                    CodeTextView(text: preview.text) { text, lines in model.features.selectedCode = text; model.features.selectedLines = lines }
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

private struct FileTreeNodeView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let node: FileNode
    @State private var expanded = false
    @State private var children: [FileNode]?

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children ?? []) { child in FileTreeNodeView(node: child) }
            } label: {
                Label(node.name, systemImage: node.isSymbolicLink ? "folder.badge.questionmark" : "folder")
            }
            .onChange(of: expanded) {
                if expanded && children == nil { Task { children = await model.loadChildren(of: node) } }
            }
        } else {
            Button { Task { await model.selectFile(node) } } label: {
                Label(node.name, systemImage: node.isSymbolicLink ? "doc.badge.ellipsis" : "doc")
                    .foregroundStyle(model.selectedFile?.id == node.id ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

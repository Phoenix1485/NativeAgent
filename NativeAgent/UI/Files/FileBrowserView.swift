import SwiftUI

@MainActor
final class FileBrowserState: ObservableObject {
    @Published var tabOpen = false
    @Published var showingTab = false
    @Published var query = ""
    @Published var filter: FileBrowserFilter = .all
    @Published var expandedPaths: Set<String> = []

    func openTab() { tabOpen = true; showingTab = true }
    func closeTab() { showingTab = false; tabOpen = false }

    func reset() {
        query = ""
        filter = .all
        expandedPaths = []
    }
}

struct FileBrowserView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var browser: FileBrowserState
    var expanded = false
    var active = true
    var onExpand: (() -> Void)?

    var body: some View {
        if expanded {
            HSplitView {
                FilePreviewPane(active: active).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                navigator.frame(minWidth: 240, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            }
        } else {
            VSplitView {
                navigator.frame(minHeight: 160, idealHeight: 280)
                FilePreviewPane(active: active).frame(minHeight: 180, maxHeight: .infinity)
            }
        }
    }

    private var navigator: some View {
        FileNavigatorView(browser: browser, active: active, onExpand: onExpand)
            .id(model.selectedProject?.id)
            .background(Studio.sidebar)
    }
}

private struct FileSearchRequest: Hashable {
    let root: String?
    let query: String
    let filter: FileBrowserFilter
    let active: Bool

    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all }
}

private struct FileNavigatorView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var browser: FileBrowserState
    var active: Bool
    var onExpand: (() -> Void)?
    @State private var results: FileSearchResult?
    @State private var searching = false
    @State private var searchError: String?

    private var request: FileSearchRequest {
        .init(root: model.selectedProject?.canonicalPath, query: browser.query, filter: browser.filter, active: active)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Files", systemImage: "folder").font(.headline)
                    Spacer()
                    if let onExpand {
                        Button(action: onExpand) { Label("Open in tab", systemImage: "arrow.up.left.and.arrow.down.right") }
                            .font(.caption).buttonStyle(.borderless)
                            .help("Open a larger code view with files on the right")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files or paths", text: $browser.query)
                        .textFieldStyle(.plain).accessibilityLabel("Search workspace files by name or path")
                    if !browser.query.isEmpty {
                        Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear file search")
                    }
                }.padding(7).background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
                Picker("File type", selection: $browser.filter) {
                    ForEach(FileBrowserFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }.pickerStyle(.menu).font(.caption)
            }.padding(12)
            Divider()
            if request.isFiltering {
                searchResults
            } else {
                List {
                    ForEach(model.rootFiles) { node in FileTreeNodeView(node: node, browser: browser) }
                }.listStyle(.sidebar)
            }
            Divider()
            Text(model.selectedProject?.canonicalPath ?? "Choose a working folder")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .help(model.selectedProject?.canonicalPath ?? "")
        }
        .task(id: request) { await search(request) }
    }

    @ViewBuilder
    private var searchResults: some View {
        if searching {
            ProgressView("Searching files…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if let results, !results.files.isEmpty {
            List(results.files) { node in FileRow(node: node, showsPath: true) }.listStyle(.sidebar)
            Text(results.isTruncated ? "\(results.files.count) files · partial results" : "\(results.files.count) matching files")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .help(results.isTruncated ? "Some files may be omitted because this project is large or a folder could not be read. Browse folders to find more files." : "")
        } else {
            ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass", description: Text(results?.isTruncated == true ? "Some files may be omitted because this project is large or a folder could not be read. Try browsing its folders." : "Try a different name, path, or file type."))
        }
    }

    @MainActor
    private func search(_ request: FileSearchRequest) async {
        guard request.active else { return }
        results = nil
        searchError = nil
        searching = request.isFiltering
        guard request.isFiltering, let root = request.root else { searching = false; return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let found = try await model.searchFiles(root: root, query: request.query, filter: request.filter)
            try Task.checkCancellation()
            results = found
            searching = false
        } catch is CancellationError {
            // The next query owns the loading state.
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
            searching = false
        }
    }
}

private struct FilePreviewPane: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    var active: Bool
    @State private var findRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            if let file = model.selectedFile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.relativePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(file.relativePath).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Button { findRequest += 1 } label: { Label("Find", systemImage: "magnifyingglass") }
                            .disabled(model.filePreview == nil).help("Find in this file (⌘F)")
                        Button("Edit…") {
                            guard let root = model.selectedProject?.canonicalPath else { return }
                            Task { await model.features.openFileEditor(URL(fileURLWithPath: root).appendingPathComponent(file.relativePath)) }
                        }.disabled(model.isWorking || model.filePreview == nil)
                            .help("Open the complete UTF-8 file in the editor (up to 1 MiB)")
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(["Explain this code", "Review for bugs", "Suggest improvements", "Refactor", "Generate tests", "Generate documentation"], id: \.self) { action in
                                Button(action) { Task { await model.features.prepareCodeAction(action) } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Code actions")
                            .disabled(model.features.selectedCode.isEmpty || !model.providerCapabilities.structuredStreaming)
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(10)
                Divider()
            }
            if model.filePreviewLoading {
                ProgressView("Loading file…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.filePreviewError {
                ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(error))
            } else if let preview = model.filePreview {
                if preview.text.isEmpty {
                    ContentUnavailableView("Empty file", systemImage: "doc", description: Text("This file does not contain any text yet."))
                } else {
                    CodeTextView(text: preview.text, onSelection: { text, lines in
                        guard active else { return }
                        model.features.selectedCode = text
                        model.features.selectedLines = lines
                    }, findRequest: findRequest)
                    .id(preview.relativePath)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Contents of \(preview.relativePath)")
                }
                Divider()
                Text("\(preview.encodingName) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass", description: Text("Choose a file to read its contents."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Studio.surface)
    }
}

private struct FileTreeNodeView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let node: FileNode
    @ObservedObject var browser: FileBrowserState
    @State private var children: [FileNode]?

    private var expanded: Binding<Bool> {
        Binding(get: { browser.expandedPaths.contains(node.relativePath) }, set: { value in
            if value { browser.expandedPaths.insert(node.relativePath) }
            else { browser.expandedPaths.remove(node.relativePath) }
        })
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expanded) {
                if let children {
                    ForEach(children) { child in FileTreeNodeView(node: child, browser: browser) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Label(node.name, systemImage: node.isSymbolicLink ? "folder.badge.questionmark" : "folder")
                    .lineLimit(1).truncationMode(.middle).help(node.relativePath)
            }
            .task(id: expanded.wrappedValue) {
                guard expanded.wrappedValue, children == nil else { return }
                let loaded = await model.loadChildren(of: node)
                guard !Task.isCancelled else { return }
                children = loaded
            }
        } else {
            FileRow(node: node)
        }
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let node: FileNode
    var showsPath = false

    var body: some View {
        Button { Task { await model.selectFile(node) } } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: node.isSymbolicLink ? "doc.badge.ellipsis" : "doc.text")
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if showsPath {
                        Text(node.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .foregroundStyle(model.selectedFile?.id == node.id ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain).help(node.relativePath)
        .listRowBackground(model.selectedFile?.id == node.id ? Studio.accent.opacity(0.12) : Color.clear)
        .accessibilityLabel(node.relativePath)
        .accessibilityAddTraits(model.selectedFile?.id == node.id ? .isSelected : [])
    }
}

import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var browser: FileBrowserState
    var expanded = false
    var active = true
    var onExpand: (() -> Void)?
    var onDetach: (() -> Void)?
    var viewportScope = "workspace"

    var body: some View {
        Group {
            if expanded {
                HSplitView {
                    FilePreviewPane(browser: browser, active: active, onDetach: onDetach, viewportScope: viewportScope)
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    navigator.frame(minWidth: 240, idealWidth: 260, maxWidth: 420, maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    navigator.frame(minHeight: 160, idealHeight: 280)
                    FilePreviewPane(browser: browser, active: active, onDetach: onDetach, viewportScope: viewportScope)
                        .frame(minHeight: 180, maxHeight: .infinity)
                }
            }
        }
        .onReceive(model.$selectedFile) { node in if let node { browser.remember(node) } }
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
            List(results.files) { node in FileRow(node: node, browser: browser, showsPath: true) }.listStyle(.sidebar)
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
    @ObservedObject var browser: FileBrowserState
    var active: Bool
    var onDetach: (() -> Void)?
    var viewportScope: String
    @State private var findRequest = 0
    @State private var goToLineRequest = 0
    @State private var requestedLine: Int?
    @State private var lineInput = ""
    @State private var showingLinePicker = false
    @State private var aiRequest: AIAssistanceRequest?

    var body: some View {
        VStack(spacing: 0) {
            if !browser.openFiles.isEmpty { fileTabs; Divider() }
            if let file = model.selectedFile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.relativePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(file.relativePath).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Button { findRequest += 1 } label: { Label("Find", systemImage: "magnifyingglass") }
                            .disabled(model.filePreview?.text.isEmpty != false).help("Find in this file (⌘F)")
                        Menu {
                            Button("Go to line…") { lineInput = ""; showingLinePicker = true }
                                .keyboardShortcut("l", modifiers: [.command])
                                .disabled(model.filePreview?.text.isEmpty != false)
                            Divider()
                            Toggle("Syntax highlighting", isOn: $browser.syntaxHighlighting)
                            Toggle("Wrap long lines", isOn: $browser.wrapsLines)
                            Menu("Text size · \(Int(browser.fontSize)) pt") {
                                ForEach([9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28], id: \.self) { size in
                                    Button("\(size) pt") { browser.fontSize = Double(size) }
                                }
                            }
                            Button("Increase text size") { browser.fontSize = min(28, browser.fontSize + 1) }
                            Button("Decrease text size") { browser.fontSize = max(9, browser.fontSize - 1) }
                            if let onDetach { Divider(); Button("Open in separate window", action: onDetach) }
                        } label: { Image(systemName: "textformat.size") }
                            .menuStyle(.borderlessButton).fixedSize().help("Code appearance and go to line")
                            .accessibilityLabel("Code appearance").disabled(!active)
                        Button("Edit…") {
                            guard let root = model.selectedProject?.canonicalPath else { return }
                            Task { await model.features.openFileEditor(URL(fileURLWithPath: root).appendingPathComponent(file.relativePath)) }
                        }.disabled(model.isWorking || model.filePreview == nil)
                            .help("Open the complete UTF-8 file in the editor (up to 1 MiB)")
                        Spacer(minLength: 0)
                        Menu {
                            ForEach([AIAssistanceRequest.Purpose.explain, .review, .improve, .refactor, .tests, .documentation]) { purpose in
                                Button(purpose.rawValue) {
                                    let lines = model.features.selectedLines.map { ":\($0.lowerBound)–\($0.upperBound)" } ?? ""
                                    aiRequest = AIAssistanceRequest(purpose: purpose, source: file.relativePath + lines,
                                        content: model.features.selectedCode, projectPath: model.selectedProject?.canonicalPath)
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Code actions")
                            .disabled(model.features.selectedCode.isEmpty || model.isWorking)
                            .help(model.features.selectedCode.isEmpty ? "Select code to ask your configured AIs about it" : "Ask your configured AIs about the selected code")
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
                    }, findRequest: findRequest, filePath: preview.relativePath,
                       fontSize: browser.fontSize, wrapsLines: browser.wrapsLines,
                       syntaxHighlighting: browser.syntaxHighlighting,
                       documentState: browser.documentState(for: preview.relativePath, scope: viewportScope),
                       goToLine: requestedLine, goToLineRequest: goToLineRequest)
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
            .sheet(item: $aiRequest) { request in AIAssistanceView(assistant: model.assistant, request: request).environmentObject(model) }
            .popover(isPresented: $showingLinePicker) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Go to line").font(.headline)
                    TextField("Line number", text: $lineInput).textFieldStyle(.roundedBorder).onSubmit(jumpToLine)
                    if !lineInput.isEmpty, validLine == nil { Text("Enter a line number in this file.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Cancel") { showingLinePicker = false }
                        Spacer()
                        Button("Go", action: jumpToLine).disabled(validLine == nil).keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 260)
            }
    }

    private var validLine: Int? {
        guard let line = Int(lineInput.trimmingCharacters(in: .whitespaces)), let text = model.filePreview?.text,
              CodeTextView.range(ofLine: line, in: text) != nil else { return nil }
        return line
    }

    private func jumpToLine() {
        guard let line = validLine else { return }
        requestedLine = line; goToLineRequest += 1; showingLinePicker = false
    }

    private var fileTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(browser.openFiles) { node in
                    HStack(spacing: 5) {
                        Button { Task { await model.selectFile(node) } } label: {
                            Text(node.name).lineLimit(1).padding(.leading, 10).padding(.vertical, 9)
                        }.help(node.relativePath)
                        Button {
                            let wasSelected = model.selectedFile?.relativePath == node.relativePath
                            let next = browser.closeFile(node, selectedPath: model.selectedFile?.relativePath)
                            if let next { Task { await model.selectFile(next) } }
                            else if wasSelected {
                                model.clearSelectedFile()
                            }
                        } label: { Image(systemName: "xmark").font(.system(size: 9)).padding(6) }
                            .help("Close \(node.name)").accessibilityLabel("Close \(node.name)")
                    }.padding(.trailing, 4)
                        .background(model.selectedFile?.id == node.id ? Studio.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
            }.padding(5)
        }.font(.caption).buttonStyle(.plain).background(Studio.sidebar)
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
            FileRow(node: node, browser: browser)
        }
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let node: FileNode
    @ObservedObject var browser: FileBrowserState
    var showsPath = false

    var body: some View {
        Button { browser.remember(node); Task { await model.selectFile(node) } } label: {
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

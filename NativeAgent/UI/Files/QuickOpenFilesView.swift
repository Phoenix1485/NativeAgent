import SwiftUI

struct QuickOpenFilesView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: FileBrowserState
    var showWorkspaceTab = true
    @State private var query = ""
    @State private var results: [FileNode] = []
    @State private var selectedID: String?
    @State private var loading = true
    @State private var isTruncated = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private var request: String { (model.selectedProject?.canonicalPath ?? "") + "\u{0}" + query }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Quick Open · file name or path", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit(openSelected)
                    .onMoveCommand { direction in
                        if direction == .down { moveSelection(by: 1) }
                        if direction == .up { moveSelection(by: -1) }
                    }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            if model.selectedProject == nil {
                ContentUnavailableView("Choose a working folder", systemImage: "folder", description: Text("Open a project before searching its files."))
            } else if loading {
                ProgressView("Finding files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass", description: Text("Try a different file name or path."))
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedID) {
                        ForEach(results) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name).font(.system(size: 13, weight: .medium))
                                    Text(file.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if browser.openFiles.contains(where: { $0.id == file.id }) { Text("Open").font(.caption2).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4).tag(file.id).id(file.id)
                                .contentShape(Rectangle()).onTapGesture(count: 2) { selectedID = file.id; openSelected() }
                        }
                    }.listStyle(.plain)
                        .onChange(of: selectedID) { if let selectedID { proxy.scrollTo(selectedID) } }
                }
            }
            Divider()
            HStack {
                Text(isTruncated ? "Partial results · narrow your search to find more files" : "↑↓ Select · Return to open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open file", action: openSelected).disabled(selectedID == nil).keyboardShortcut(.defaultAction)
            }.padding(12)
        }.frame(width: 620, height: 430).background(Studio.canvas)
            .task(id: request) { await search() }
            .onAppear { searchFocused = true }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let index = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        selectedID = results[min(results.count - 1, max(0, index + offset))].id
    }

    private func openSelected() {
        guard let file = results.first(where: { $0.id == selectedID }), !loading else { return }
        browser.remember(file)
        if showWorkspaceTab { browser.openTab() }
        dismiss()
        Task { await model.selectFile(file) }
    }

    @MainActor
    private func search() async {
        loading = true; error = nil; selectedID = nil
        guard let root = model.selectedProject?.canonicalPath else { loading = false; return }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let found = try await model.searchFiles(root: root, query: query, filter: .all)
            try Task.checkCancellation()
            let openIDs = Set(browser.openFiles.map(\.id))
            results = found.files.sorted {
                if openIDs.contains($0.id) != openIDs.contains($1.id) { return openIDs.contains($0.id) }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            isTruncated = found.isTruncated; selectedID = results.first?.id; loading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}

import SwiftUI
import PDFKit

struct AttachmentStrip: View {
    @ObservedObject var features: WorkspaceFeaturesController
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var preview: ContextAttachment?
    var body: some View {
        if !features.context.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(features.context) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.stale ? "exclamationmark.triangle" : "doc.text")
                            if item.isMedia {
                                Button(item.title) { preview = item }.help("Preview the saved attachment snapshot")
                            } else if let path = item.sourceURL {
                                Button(item.title) { Task { await features.openFileEditor(URL(fileURLWithPath: path)) } }
                                    .help("Preview or edit \(path)")
                                Menu {
                                    Button("Preview / edit…") { Task { await features.openFileEditor(URL(fileURLWithPath: path)) } }
                                    Toggle("Allow AI edits (review each change)", isOn: Binding(get: { item.allowEdits == true }, set: { enabled in Task { await features.setFileEditable(item.id, enabled: enabled) } }))
                                        .disabled(model.isWorking)
                                    Text("AI edits also require Workspace edits permission.")
                                } label: { Image(systemName: item.allowEdits == true ? "pencil.circle.fill" : "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(item.title)")
                            } else { Text(item.title) }
                            Button { Task { await features.removeContext(item.id) } } label: { Image(systemName: "xmark") }
                                .disabled(model.isWorking).accessibilityLabel("Remove \(item.title)")
                        }.font(.caption).buttonStyle(.plain).padding(8)
                            .background(Studio.hover, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 10)
                .sheet(item: $preview) { item in MediaAttachmentPreview(item: item) }
        }
    }
}

struct MediaAttachmentPreview: View {
    let item: ContextAttachment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(item.title).font(.headline); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(item.metadata).font(.caption).foregroundStyle(.secondary)
            if let data = item.mediaData {
                if item.mimeType == "application/pdf" { PDFSnapshotView(data: data) }
                else if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Text("This saved snapshot is sent with subsequent messages until you remove it. Model support and account limits apply.").font(.caption)
        }.padding(20).frame(width: 740, height: 580)
    }
}

private struct PDFSnapshotView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateNSView(_ view: PDFView, context: Context) { }
}

struct AttachedFileEditor: View {
    @ObservedObject var features: WorkspaceFeaturesController
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AttachedFileSnapshot
    @State private var text: String
    @State private var editing = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false
    private let owner: UUID?
    init(file: AttachedFileSnapshot, features: WorkspaceFeaturesController) {
        self.features = features; owner = features.contextOwner
        _snapshot = State(initialValue: file); _text = State(initialValue: file.text)
    }
    private var dirty: Bool { text != snapshot.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(snapshot.url.lastPathComponent, systemImage: "doc.text").font(.title2)
                Spacer()
                if dirty { Text("Unsaved changes").foregroundStyle(.orange) }
                Button("Close") { if dirty { confirmDiscard = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text(snapshot.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if editing {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).disabled(saving)
                    .accessibilityLabel("File contents")
            } else {
                GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                }
            }
            HStack {
                Text("UTF-8 · up to 1 MiB · saved only when you confirm").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editing {
                    Button("Save file") { Task { await save() } }.keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent).disabled(!dirty || saving || model.isWorking)
                } else {
                    Button("Edit file") { editing = true }.disabled(model.isWorking)
                }
            }
        }.padding(24).frame(minWidth: 660, idealWidth: 820, minHeight: 500, idealHeight: 620)
            .interactiveDismissDisabled(dirty || saving)
            .onChange(of: text) { features.editorHasChanges = dirty }
            .onDisappear { features.editorHasChanges = false }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
    }
    private func save() async {
        saving = true; features.fileSaveInProgress = true; error = nil
        defer { saving = false; features.fileSaveInProgress = false }
        do {
            snapshot = try await features.attachedFiles.save(snapshot, text: text)
            features.editorHasChanges = false
            try await features.refreshAttachment(snapshot, owner: owner)
            if let node = model.selectedFile { await model.selectFile(node) }
        } catch { self.error = error.localizedDescription }
    }
}

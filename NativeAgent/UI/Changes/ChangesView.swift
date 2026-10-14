import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var model: WorkspaceViewModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label(model.gitSnapshot.branch, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button { Task { await model.refreshGit() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                }.padding(8)
                Divider()
                List(model.gitSnapshot.changes) { change in
                    Button { Task { await model.selectChange(change) } } label: {
                        HStack {
                            Text(change.kind.rawValue.prefix(1).uppercased()).font(.caption.monospaced()).foregroundStyle(change.staged ? .green : .orange)
                            Text(change.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if change.staged { Text("staged").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .frame(minHeight: 160)
            if model.diffText.isEmpty { ContentUnavailableView("Select a change", systemImage: "arrow.left.arrow.right") }
            else { CodeTextView(text: model.diffText) }
        }
    }
}

import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater
    @State private var showHighlights = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(updater.installedVersionLabel).font(.headline).textSelection(.enabled)
            Label(updater.status.label, systemImage: "arrow.triangle.2.circlepath").textSelection(.enabled)
            Text(updater.lastChecked.map { "Last checked: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No update check recorded yet.")
                .font(.caption).foregroundStyle(.secondary)
            if updater.status == .downloading {
                if let fraction = updater.downloadFraction {
                    ProgressView(value: fraction)
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                } else { ProgressView("Downloading…") }
                Text("Download and installation controls are also available in the updater window.").font(.caption).foregroundStyle(.secondary)
            }
            Button(updater.availableVersion == nil ? "Check for Updates…" : "Show available update…") { updater.checkForUpdates() }
                .buttonStyle(.borderedProminent).disabled(!updater.canCheckForUpdates)
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks).disabled(!updater.configured)
            Toggle("Download updates automatically", isOn: $updater.automaticallyDownloads).disabled(!updater.configured)
            Text("Updates replace this app in place. Relaunch waits for active work and unsaved file edits. A development build cannot install release updates.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Download NativeAgent on GitHub Pages", destination: AppUpdater.downloadPageURL)
            Button("What’s New") { showHighlights = true }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showHighlights) { WhatsNewView().environmentObject(updater) }
    }
}

struct WhatsNewView: View {
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    private let highlights = [
        ("Code you can see", "File previews now display code correctly. Open a larger Files tab with a resizable file list on the right, and switch back to your chat whenever you need it."),
        ("Find the right file", "Search filenames and paths, filter by file type, and use Find or ⌘F to search within the open file."),
        ("Your archive, easier to browse", "Archived chats use your selected accent color. Search chat titles, filter by archive date, and load more results as needed."),
        ("Delete when you choose", "Permanently delete an individual archived chat after confirmation, including its saved messages, draft and attachment copies. Original files and provider histories stay separate."),
        ("Keep large archives manageable", "Chats normally remain recoverable for 30 days. When more than 30 chats are archived, chats containing at least 10 MiB of stored content can be deleted after 20 days, oldest first, until 30 remain.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What’s New").font(.largeTitle.weight(.semibold))
            Text(updater.installedVersionLabel).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(highlights, id: \.0) { title, detail in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.headline)
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { updater.acknowledgeWhatsNew(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(28).frame(width: 570, height: 600).background(Studio.canvas)
    }
}

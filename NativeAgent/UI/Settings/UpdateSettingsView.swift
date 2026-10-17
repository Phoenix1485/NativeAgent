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
        ("Long-chat memory", "Older messages get a rolling summary; pinned instructions stay with your chat."),
        ("Images and PDFs", "Preview attachments and send their actual contents through the direct ChatGPT connection."),
        ("Edit, regenerate and retry", "Start a separate retry branch while keeping the original conversation."),
        ("Backups and exports", "Daily local backups, safe restore, and full-message Markdown or PDF exports."),
        ("Find your important chats", "Pinned chats, persistent unread replies, and a working indicator."),
        ("Visible update status", "Last-check time, download progress, errors and these release highlights."),
        ("Project memory", "Save frameworks, conventions, goals, decisions and things to avoid for every chat in a project.")
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

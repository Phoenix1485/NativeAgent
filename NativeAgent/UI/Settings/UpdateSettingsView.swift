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
        ("Automatic connection", "Saved accounts connect on launch. Turn this off in Settings → Configuration; no prompts are sent automatically."),
        ("Lighter chat loading", "Skeleton placeholders, newest messages first, and older pages loaded as you scroll. The timeline keeps at most 200 items loaded."),
        ("Model and effort picker", "A redesigned picker with an effort slider for models that advertise supported thinking levels."),
        ("Clearer AI naming", "AI naming requires five user messages and checks the saved chat, even when older messages are not loaded on screen."),
        ("Subtle navigation highlights", "Only the clicked prompt marker is highlighted, using your selected accent color before fading away.")
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

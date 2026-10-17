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
        ("Your API connections", "Add up to ten API tokens in Settings → API connections, securely stored in Keychain. Use OpenAI, Claude, Grok, DeepSeek or compatible custom endpoints."),
        ("Quick actions with @", "Type @ or use the composer’s @ button to attach files, choose plan mode, open templates or select your AIs."),
        ("Multiple AIs, one chat", "Ask selected AIs for independent, labeled answers using recent chat context. Review destinations before sending; API usage is billed separately."),
        ("Controlled parallel replies", "At most two requests run at once. Stop cancels pending work, and one provider’s error does not discard other answers."),
        ("Official account sign-in", "Grok account connections use its official runtime. Claude subscription conversations stay in official Claude Code; use a Claude API key for shared-chat replies.")
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

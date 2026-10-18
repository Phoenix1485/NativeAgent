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
        ("Follow the work in chat", "Compact activity rows reveal commands, plans and agent updates. Review the latest task’s tracked file changes and snapshot line counts above the composer. Queue follow-ups in the same chat, edit or remove them, choose what runs next, and pause or resume execution."),
        ("Organized chat actions", "Chat menus now group Markdown and PDF under Export, with dividers separating Rename and Pin, Export, Archive chat, and Move to."),
        ("New chat works where you expect", "New chat and ⌘N open a blank composer in the requested location. Existing drafts and attachments stay saved, group chats no longer block standalone chats, and New chat returns from Files to the main AI conversation."),
        ("CLI and model update checks", "Check Claude and Grok versions at startup and at :00 and :30 each hour. Refresh the connected ChatGPT model catalog, see installed/latest CLI versions, or check manually in Settings → Updates."),
        ("Your own specialist agents", "Configure agents with their own AI connection, instructions and references. Add them through @mentions, or let direct ChatGPT delegate using your chosen approval mode and call limit."),
        ("GitHub in your workspace", "Sign in through GitHub CLI, clone or create repositories, stage and commit changes, push and pull, compare branches, and review or merge pull requests."),
        ("Your configured AIs, where you need them", "Review a diff or selected code, draft a commit or pull request, and compare saved answers with ChatGPT, Grok, Claude API or your custom AI connections. Choose the source and recipients before sending."),
        ("A larger code workspace", "Open multiple file tabs, split code beside your chat, or use a separate window. Add syntax highlighting, change text size and wrapping, jump to a line with ⌘L, and find files with ⌘P."),
        ("Manage library storage", "See chat, attachment, backup and cache sizes. Sort by size, archive selected chats, permanently delete selected archived chats, and review upcoming automatic deletions."),
        ("Keep useful answers close", "Bookmark messages with labels, search them, and jump to the original conversation. View saved AI answers side by side, combine them, or ask an AI to explain disagreements.")
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

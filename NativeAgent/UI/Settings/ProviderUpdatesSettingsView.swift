import SwiftUI

struct ProviderUpdatesSettingsView: View {
    @ObservedObject var controller: ProviderUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("CLI & model updates", systemImage: "terminal").font(.headline)
                Spacer()
                if controller.checking { ProgressView().controlSize(.small) }
                Button(controller.checking ? "Checking…" : "Check now") { controller.checkNow() }
                    .buttonStyle(.borderedProminent).disabled(controller.checking)
                    .accessibilityIdentifier("check-provider-updates")
            }
            Toggle("Check at startup and every hour at :00 and :30", isOn: $controller.automaticallyChecks)
            Text("Uses your Mac’s local time while NativeAgent is open. A missed check runs once after wake. Manual checks keep the same schedule.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Text(controller.lastChecked.map { "Last check: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No check recorded yet")
                if let next = controller.nextCheck { Text("Next: " + next.formatted(date: .omitted, time: .shortened)) }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            VStack(alignment: .leading, spacing: 8) {
                Label("ChatGPT · direct connection", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                Text(controller.modelMessage).font(.caption).foregroundStyle(.secondary)
                Text("Account access determines which models are available. Checks refresh the catalog without switching your chosen model during a task.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            ForEach(CheckedCLI.allCases) { cli in
                ProviderUpdateRow(cli: cli, result: controller.results.first { $0.cli == cli })
            }
            Text("Checks read installation metadata or run a version-only command, then read the provider’s public release feed. They do not install software. Use the provider’s update guide for your installation, then reconnect to use the updated CLI. Codex is never launched by this checker.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderUpdateRow: View {
    let cli: CheckedCLI
    let result: CLIUpdateResult?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(cli.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(result?.status ?? "Not checked").font(.caption).foregroundStyle(result?.updateAvailable == true ? Studio.accent : .secondary)
            }
            HStack(spacing: 18) {
                Text("Installed: " + (result?.installed ?? "Unknown"))
                Text(cli.channel + ": " + (result?.latest ?? "Unknown"))
            }.font(.caption.monospaced()).foregroundStyle(.secondary)
            if let path = result?.path { Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled) }
            if let issue = result?.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text(cli == .claude ? "Native install: claude update" : "Native install: grok update")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Link("Update guide ↗", destination: cli.provider.setupURL).font(.caption).foregroundStyle(Studio.accent)
            }
            if cli == .claude { Text("Homebrew installations use brew upgrade for their installed cask. A stable channel or managed version may intentionally lag the latest release.").font(.caption2).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
    }
}

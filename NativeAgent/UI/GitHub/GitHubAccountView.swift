import AppKit
import SwiftUI

struct GitHubAccountView: View {
    @ObservedObject var controller: GitHubController
    @State private var confirmSignOut = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.auth.login.map { "GitHub · @" + $0 } ?? "Connect GitHub").font(.headline)
                    Text(controller.auth.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if controller.auth.isAuthenticated {
                    Button("Sign out…") { confirmSignOut = true }.disabled(controller.busy)
                } else {
                    Button("Sign in with GitHub") { Task { await controller.login() } }.buttonStyle(.borderedProminent)
                        .disabled(controller.busy || !controller.auth.isInstalled)
                }
                Button { Task { await controller.refreshAuth() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh GitHub account").disabled(controller.busy)
            }
            if !controller.auth.isInstalled {
                Text("Install GitHub CLI to authorize this Mac in your browser, then choose its executable. NativeAgent uses that GitHub account for repository actions.").font(.callout)
                HStack {
                    Link("Get GitHub CLI", destination: URL(string: "https://cli.github.com/")!)
                    Button("Choose GitHub CLI…") { chooseCLI() }
                }
            } else {
                DisclosureGroup("Connection details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.auth.executablePath ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        Text("Authorization is managed by GitHub CLI and shared with other apps that use it. AI connections do not receive your GitHub credentials.").font(.caption).foregroundStyle(.secondary)
                        Button("Choose another GitHub CLI…") { chooseCLI() }.disabled(controller.busy)
                    }
                }.font(.caption)
            }
            if !controller.loginOutput.isEmpty {
                Text(controller.loginOutput).font(.callout.monospaced()).textSelection(.enabled).frame(maxHeight: 100, alignment: .topLeading)
            }
        }
        .alert("Sign out of GitHub CLI?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { Task { await controller.logout() } }
        } message: { Text("This removes the shared GitHub CLI login on this Mac. Your repositories and local files remain available.") }
    }
    private func chooseCLI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "Use GitHub CLI"; panel.message = "Select the official gh executable."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.configureCLI(path: url.path) }
    }
}

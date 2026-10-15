import SwiftUI

@main
enum NativeAgentLauncher {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--official-claude-terminal" {
            let code = await OfficialClaudeTerminal.runHelper(directory: URL(fileURLWithPath: arguments[2]))
            exit(code)
        }
        NativeAgentApp.main()
    }
}

struct NativeAgentApp: App {
    @NSApplicationDelegateAdaptor(NativeAgentApplicationDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            LaunchView(model: container.viewModel, settings: container.viewModel.settings)
                .environmentObject(container.viewModel)
                .frame(minWidth: 840, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
                .onAppear { appDelegate.viewModel = container.viewModel; updater.start(model: container.viewModel) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                Menu("Automatic Updates") {
                    Toggle("Check automatically", isOn: $updater.automaticallyChecks)
                    Toggle("Download and install on quit", isOn: $updater.automaticallyDownloads)
                }.disabled(!updater.configured)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { container.viewModel.features.execute(.newChat) }
                    .keyboardShortcut("n")
                Button("Open Project…") { container.viewModel.openProject() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Agent") {
                Button("Command Palette…") { container.viewModel.features.paletteVisible = true }.keyboardShortcut("k")
                Button("Search Local History…") { container.viewModel.features.execute(.search) }.keyboardShortcut("f", modifiers: [.command, .shift])
                ForEach(WorkspaceCommand.allCases.filter { ![.newChat, .search, .settings].contains($0) }) { command in
                    Button(command.title) { container.viewModel.features.execute(command) }.disabled(!container.viewModel.features.canExecute(command))
                }
                Divider()
                Button("Send") { Task { await container.viewModel.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!container.viewModel.canSend)
                Button("Stop") { Task { await container.viewModel.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        Settings {
            ProviderSettingsView()
                .environmentObject(container.viewModel)
                .frame(width: 940, height: 690)
        }
    }
}

@MainActor
final class NativeAgentApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: WorkspaceViewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        if viewModel.features.fileSaveInProgress {
            let alert = NSAlert(); alert.messageText = "A file is being saved. Please quit again after it finishes."; alert.runModal()
            return .terminateCancel
        }
        if viewModel.features.editorHasChanges {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved file changes and quit?"
            alert.informativeText = "Your file editor has unsaved changes. Choose Keep editing to save them first."
            alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard and quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task { await viewModel.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

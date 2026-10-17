import AppKit
import SwiftUI

@MainActor
final class DetachedFilesWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var window: NSWindow?

    func open(model: WorkspaceViewModel, browser: FileBrowserState) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Files — NativeAgent"
        window.minSize = NSSize(width: 650, height: 440)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NativeAgentFilesWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: DetachedFilesContent(browser: browser).environmentObject(model))
        self.window = window; isVisible = true
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        window = nil
    }
}

private struct DetachedFilesContent: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var browser: FileBrowserState
    @State private var quickOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.selectedProject?.name ?? "Files", systemImage: "folder")
                Spacer()
                Button { quickOpen = true } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                    .keyboardShortcut("p", modifiers: .command).disabled(model.selectedProject == nil)
            }.font(.caption).padding(12)
            Divider()
            if model.selectedProject != nil {
                FileBrowserView(browser: browser, expanded: true, viewportScope: "detached")
            } else {
                ContentUnavailableView("Choose a working folder", systemImage: "folder", description: Text("Open a project in the main window to browse its files here."))
            }
        }.background(Studio.canvas).tint(model.settings.accent.color).accentColor(model.settings.accent.color)
            .preferredColorScheme(model.settings.theme.scheme)
            .sheet(isPresented: $quickOpen) { QuickOpenFilesView(browser: browser, showWorkspaceTab: false).environmentObject(model) }
    }
}

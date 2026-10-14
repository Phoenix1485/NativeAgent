import AppKit
import SwiftUI

/// One action definition drives the context menu and the hover/click menu.
@MainActor
struct SidebarChatMenu: NSViewRepresentable {
    struct Item: Identifiable {
        let id: String
        var title = ""
        var symbol: String?
        var children: [Item]?
        var action: (() -> Void)?
        var isSeparator = false
    }

    let items: [Item]
    let label: String
    let rowHovered: Bool
    let request: UUID

    static func items(chat: Conversation, model: WorkspaceViewModel) -> [Item] {
        [Item(id: "rename", title: "Rename…", symbol: "pencil", action: { model.renameConversation(chat) }),
         Item(id: "move", title: "Move to", children:
            [Item(id: "standalone", title: "Standalone chats", action: { Task { await model.moveConversation(chat, to: nil) } })] +
            model.groups.map { group in
                Item(id: group.id.uuidString, title: model.groupPath(group.id), action: { Task { await model.moveConversation(chat, to: group.id) } })
            }),
         Item(id: "divider", isSeparator: true),
         Item(id: "archive", title: "Archive chat", symbol: "archivebox", action: { Task { await model.archive(chat) } })]
    }

    static func nativeMenu(_ items: [Item]) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let entry = ActionMenuItem(title: item.title, callback: item.action)
            if let symbol = item.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let children = item.children { entry.submenu = nativeMenu(children) }
            menu.addItem(entry)
        }
        return menu
    }

    func makeNSView(context: Context) -> HoverMenuButton {
        let button = HoverMenuButton()
        button.lastRequest = request
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: HoverMenuButton, context: Context) {
        button.items = items
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.rowHovered = rowHovered
        button.refreshAppearance()
        if button.lastRequest != request {
            button.lastRequest = request
            // NSMenu tracking must start outside SwiftUI's update pass.
            DispatchQueue.main.async { [weak button] in button?.showMenu() }
        }
    }

    final class HoverMenuButton: NSButton {
        var items: [Item] = []
        var lastRequest = UUID()
        var rowHovered = false
        var presentMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
            menu.popUp(positioning: nil, at: point, in: view)
        }
        private var tracking: NSTrackingArea?
        private var menuVisible = false
        private var pointerInside = false
        private var keyboardFocused = false

        init() {
            super.init(frame: .zero)
            isBordered = false
            image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            imagePosition = .imageOnly
            target = self; action = #selector(openMenu)
            setAccessibilityRole(.popUpButton)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); keyboardFocused = result; refreshAppearance(); return result }
        override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { keyboardFocused = false }; refreshAppearance(); return result }
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) {
            guard !pointerInside else { return }
            pointerInside = true
            showMenu()
        }
        override func mouseExited(with event: NSEvent) { pointerInside = false; refreshAppearance() }
        override func keyDown(with event: NSEvent) {
            if [36, 49, 125, 126].contains(event.keyCode) { showMenu() }
            else { super.keyDown(with: event) }
        }
        @objc private func openMenu() { showMenu() }
        func refreshAppearance() {
            contentTintColor = rowHovered || pointerInside || menuVisible || keyboardFocused ? .secondaryLabelColor : .clear
        }
        func showMenu() {
            guard !menuVisible, window != nil else { return }
            menuVisible = true; refreshAppearance()
            presentMenu(SidebarChatMenu.nativeMenu(items), NSPoint(x: bounds.maxX, y: bounds.minY), self)
            menuVisible = false
            // Tracking consumes some exit events. Reconcile once, with no timer.
            if let window { pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
            refreshAppearance()
        }
    }

    private final class ActionMenuItem: NSMenuItem {
        private let callback: (() -> Void)?
        init(title: String, callback: (() -> Void)?) {
            self.callback = callback
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func invoke() { callback?() }
    }
}

struct SidebarChatMenuContent: View {
    let items: [SidebarChatMenu.Item]
    var body: some View {
        ForEach(items) { item in
            if item.isSeparator { Divider() }
            else if let children = item.children { Menu(item.title) { AnyView(SidebarChatMenuContent(items: children)) } }
            else {
                Button(action: { item.action?() }) {
                    if let symbol = item.symbol { Label(item.title, systemImage: symbol) }
                    else { Text(item.title) }
                }
            }
        }
    }
}

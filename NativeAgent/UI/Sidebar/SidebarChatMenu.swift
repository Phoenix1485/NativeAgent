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
    var hoverRegion: SidebarHoverRegion? = nil

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
        button.hoverRegion = hoverRegion
        button.refreshAppearance()
        if button.lastRequest != request {
            button.lastRequest = request
            // Presentation must start outside SwiftUI's update pass.
            DispatchQueue.main.async { [weak button] in button?.showMenu() }
        }
    }

    static func dismantleNSView(_ button: HoverMenuButton, coordinator: ()) { button.closeMenu() }

    final class HoverMenuButton: NSButton, NSPopoverDelegate {
        private static weak var activeButton: HoverMenuButton?
        var items: [Item] = []
        var lastRequest = UUID()
        var rowHovered = false
        var hoverRegion: SidebarHoverRegion?
        // Injection keeps interaction tests independent of the window server.
        var presentMenu: ((NSMenu, NSPoint, NSView) -> Void)?
        private var tracking: NSTrackingArea?
        private(set) var menuVisible = false
        private var pointerInside = false
        private var keyboardFocused = false
        private var popover: NSPopover?
        private var pointerMonitor: Any?
        private var outsideMonitor: Any?
        private weak var trackingWindow: NSWindow?
        private var previouslyAcceptedMouseMoved = false
        private var closeTask: DispatchWorkItem?

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
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
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
            Self.activeButton?.closeMenu()
            Self.activeButton = self
            menuVisible = true; refreshAppearance()
            if let presentMenu {
                presentMenu(SidebarChatMenu.nativeMenu(items), NSPoint(x: bounds.maxX, y: bounds.minY), self)
                menuVisible = false; refreshAppearance(); return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: SidebarHoverMenuContent(items: items) { [weak self] action in
                self?.closeMenu()
                action?()
            })
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
            trackingWindow = window
            previouslyAcceptedMouseMoved = window?.acceptsMouseMovedEvents ?? false
            window?.acceptsMouseMovedEvents = true
            popover.contentViewController?.view.window?.acceptsMouseMovedEvents = true
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
                self?.pointerMoved(to: NSEvent.mouseLocation)
                return event
            }
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.pointerMoved(to: NSEvent.mouseLocation)
            }
        }
        static func containsPointer(_ point: NSPoint, row: NSRect, popup: NSRect) -> Bool {
            row.contains(point) || popup.insetBy(dx: -6, dy: -6).contains(point)
        }
        func pointerMoved(to point: NSPoint) {
            guard let window, let popoverWindow = popover?.contentViewController?.view.window else { closeMenu(); return }
            let row = hoverRegion?.screenFrame ?? window.convertToScreen(convert(bounds, to: nil))
            if Self.containsPointer(point, row: row, popup: popoverWindow.frame) {
                closeTask?.cancel(); closeTask = nil
            } else if closeTask == nil {
                // A short grace period lets the pointer cross the popover's arrow.
                let task = DispatchWorkItem { [weak self] in self?.closeMenu() }
                closeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
            }
        }
        func closeMenu() {
            stopMonitoring()
            popover?.close(); popover = nil
            menuVisible = false
            if let window { pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
            refreshAppearance()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { closeMenu() }
        }
        func popoverDidClose(_ notification: Notification) {
            stopMonitoring()
            menuVisible = false; refreshAppearance()
        }
        private func stopMonitoring() {
            closeTask?.cancel(); closeTask = nil
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
            trackingWindow?.acceptsMouseMovedEvents = previouslyAcceptedMouseMoved
            trackingWindow = nil
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

/// The actual row bounds, in screen coordinates, including nested group indentation.
final class SidebarHoverRegion: ObservableObject {
    weak var view: NSView?
    var screenFrame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct SidebarHoverRegionView: NSViewRepresentable {
    let region: SidebarHoverRegion
    func makeNSView(context: Context) -> NSView { let view = RegionView(); region.view = view; return view }
    func updateNSView(_ nsView: NSView, context: Context) { region.view = nsView }
    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct SidebarHoverMenuContent: View {
    let items: [SidebarChatMenu.Item]
    let invoke: ((() -> Void)?) -> Void
    @State private var expanded: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                if item.isSeparator { Divider().padding(.vertical, 3) }
                else if let children = item.children {
                    Button { expanded = expanded == item.id ? nil : item.id } label: {
                        HStack { Text(item.title); Spacer(); Image(systemName: expanded == item.id ? "chevron.down" : "chevron.right") }
                    }.buttonStyle(SidebarMenuActionStyle())
                    if expanded == item.id {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(children) { child in
                                    Button(child.title) { invoke(child.action) }.buttonStyle(SidebarMenuActionStyle())
                                }
                            }
                        }.frame(height: min(CGFloat(children.count) * 30, 210)).padding(.leading, 10)
                    }
                } else {
                    Button { invoke(item.action) } label: {
                        Label(item.title, systemImage: item.symbol ?? "circle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(SidebarMenuActionStyle())
                }
            }
        }.font(.system(size: 12)).padding(8).frame(width: 205)
    }
}

private struct SidebarMenuActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(configuration: configuration)
    }
    private struct ActionLabel: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered || configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
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

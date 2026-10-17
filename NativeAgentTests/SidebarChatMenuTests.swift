import AppKit
import XCTest
@testable import NativeAgent

@MainActor
final class SidebarChatMenuTests: XCTestCase {
    func testRealPopoverClosesAfterLeavingAndCanReopen() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 240, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
        let region = SidebarHoverRegion(); region.view = row
        let button = SidebarChatMenu.HoverMenuButton()
        button.frame = NSRect(x: 205, y: 10, width: 28, height: 30)
        button.hoverRegion = region
        button.items = [.init(id: "rename", title: "Rename…", action: {})]
        row.addSubview(button); window.contentView = row
        window.orderFront(nil)
        defer { button.closeMenu(); window.orderOut(nil) }
        button.showMenu()
        XCTAssertTrue(button.menuVisible)
        let frame = try XCTUnwrap(region.screenFrame)
        button.pointerMoved(to: NSPoint(x: frame.midX, y: frame.midY))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(button.menuVisible)
        button.pointerMoved(to: NSPoint(x: -10_000, y: -10_000))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(button.menuVisible)
        button.showMenu()
        XCTAssertTrue(button.menuVisible)
    }

    func testPopupHoverScopeExcludesOtherChatsButIncludesItsOwnActions() {
        let row = NSRect(x: 20, y: 100, width: 220, height: 36)
        let popup = NSRect(x: 244, y: 20, width: 205, height: 116)
        XCTAssertTrue(SidebarChatMenu.HoverMenuButton.containsPointer(NSPoint(x: 50, y: 118), row: row, popup: popup))
        XCTAssertTrue(SidebarChatMenu.HoverMenuButton.containsPointer(NSPoint(x: 300, y: 55), row: row, popup: popup))
        XCTAssertFalse(SidebarChatMenu.HoverMenuButton.containsPointer(NSPoint(x: 50, y: 150), row: row, popup: popup))
        XCTAssertFalse(SidebarChatMenu.HoverMenuButton.containsPointer(NSPoint(x: 50, y: 80), row: row, popup: popup))
    }

    func testRowHoverOnlyRevealsDotsAndNeverPresentsPopup() {
        let button = SidebarChatMenu.HoverMenuButton()
        var presented = false
        button.presentMenu = { _, _, _ in presented = true }
        button.rowHovered = true; button.refreshAppearance()
        XCTAssertFalse(presented)
        XCTAssertFalse(button.menuVisible)
    }

    func testHoverClickAndKeyboardOpenTheSameMenuWithoutSelectingChat() throws {
        _ = NSApplication.shared
        let button = SidebarChatMenu.HoverMenuButton()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = button
        var presentations: [[String]] = []
        button.items = [.init(id: "rename", title: "Rename…", action: {}), .init(id: "archive", title: "Archive chat", action: {})]
        button.presentMenu = { menu, _, _ in presentations.append(menu.items.map(\.title)) }
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseEntered(with: hover)
        button.performClick(nil)
        let keyboard = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: keyboard)
        XCTAssertEqual(presentations, Array(repeating: ["Rename…", "Archive chat"], count: 3))
        window.orderOut(nil)
    }

    func testNativeMenuPreservesSharedItemsAndDispatchesCorrectAction() throws {
        var invoked: [String] = []
        let items: [SidebarChatMenu.Item] = [
            .init(id: "rename", title: "Rename…", symbol: "pencil", action: { invoked.append("rename") }),
            .init(id: "move", title: "Move to", children: [
                .init(id: "root", title: "Standalone chats", action: { invoked.append("root") }),
                .init(id: "group", title: "App / Frontend", action: { invoked.append("group") })]),
            .init(id: "divider", isSeparator: true),
            .init(id: "archive", title: "Archive chat", action: { invoked.append("archive") })
        ]
        let menu = SidebarChatMenu.nativeMenu(items)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Rename…", "Move to", "Archive chat"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        let submenu = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Standalone chats", "App / Frontend"])
        menu.performActionForItem(at: 0)
        submenu.performActionForItem(at: 1)
        menu.performActionForItem(at: 3)
        XCTAssertEqual(invoked, ["rename", "group", "archive"])
    }

    func testEllipsisRemainsKeyboardAndAccessibilityReachableWhenNotHovered() {
        _ = NSApplication.shared
        let button = SidebarChatMenu.HoverMenuButton()
        button.setAccessibilityLabel("Actions for Example chat")
        button.rowHovered = false
        button.refreshAppearance()
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertEqual(button.accessibilityRole(), .popUpButton)
        XCTAssertEqual(button.accessibilityLabel(), "Actions for Example chat")
        XCTAssertEqual(button.contentTintColor, .clear)
        button.rowHovered = true
        button.refreshAppearance()
        XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)
    }
}

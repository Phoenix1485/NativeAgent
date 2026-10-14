import AppKit
import XCTest
@testable import NativeAgent

@MainActor
final class SidebarChatMenuTests: XCTestCase {
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

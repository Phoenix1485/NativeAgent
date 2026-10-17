import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

@MainActor
final class CodeTextViewTests: XCTestCase {
    func testCodeHasVisibleGlyphsInLightAndDarkAppearance() async throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let window = makeWindow(CodeTextView(text: "let answer = 42\nprint(answer)"))
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: name)
            await settle(window)
            let scroll = try XCTUnwrap(find(NSScrollView.self, in: window.contentView!))
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            let layout = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            layout.ensureLayout(for: container)
            XCTAssertGreaterThan(layout.numberOfGlyphs, 0)
            XCTAssertGreaterThan(text.bounds.width, layout.usedRect(for: container).maxX)
            XCTAssertGreaterThan(text.bounds.height, layout.usedRect(for: container).maxY)

            var foreground: NSColor?, background: NSColor?
            text.effectiveAppearance.performAsCurrentDrawingAppearance {
                foreground = text.textColor?.usingColorSpace(.deviceRGB)
                background = text.backgroundColor.usingColorSpace(.deviceRGB)
            }
            let foregroundColor = try XCTUnwrap(foreground)
            let backgroundColor = try XCTUnwrap(background)
            XCTAssertGreaterThan(abs(foregroundColor.redComponent - backgroundColor.redComponent), 0.5)

            // Capture the complete scroll-view composition, then inspect the code
            // area beyond the ruler. The ruler previously painted over this text.
            let rect = NSRect(x: 60, y: 0, width: 240, height: 55)
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: rect))
            scroll.cacheDisplay(in: rect, to: bitmap)
            let backgroundPixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.usingColorSpace(.deviceRGB))
            var distinctPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(pixel.redComponent - backgroundPixel.redComponent) > 0.2 { distinctPixels += 1 }
                }
            }
            XCTAssertGreaterThan(distinctPixels, 40, "Code must actually paint in \(name.rawValue)")
            XCTAssertGreaterThanOrEqual(text.convert(NSPoint(x: 8, y: 8), to: scroll).x,
                                       try XCTUnwrap(scroll.verticalRulerView).frame.maxX)
        }
    }

    func testLongLinesAndFilesAreScrollableAndFollowViewportResizing() async throws {
        let code = Array(repeating: String(repeating: "wide code ", count: 40), count: 100).joined(separator: "\n")
        let window = makeWindow(CodeTextView(text: code))
        defer { window.orderOut(nil) }
        await settle(window)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: window.contentView!))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertGreaterThan(text.frame.width, scroll.contentSize.width * 2)
        XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height * 2)
        scroll.contentView.scroll(to: NSPoint(x: 500, y: 500))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)

        window.setContentSize(NSSize(width: 1000, height: 700))
        await settle(window)
        XCTAssertGreaterThanOrEqual(text.frame.width, viewportSize(scroll).width)
        XCTAssertGreaterThanOrEqual(text.frame.height, viewportSize(scroll).height)
    }

    func testNarrowHostKeepsFirstGlyphBeyondRulerAndPreservesUserScroll() async throws {
        let code = "import SwiftUI\n" + String(repeating: "long source line ", count: 40)
        let window = makeWindow(CodeTextView(text: code), size: NSSize(width: 300, height: 220))
        defer { window.orderOut(nil) }
        await settle(window)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: window.contentView!))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let ruler = try XCTUnwrap(scroll.verticalRulerView)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let glyphOrigin = text.convert(NSPoint(x: glyph.minX + text.textContainerOrigin.x,
                                               y: glyph.minY + text.textContainerOrigin.y), to: scroll)
        XCTAssertGreaterThan(text.frame.width, scroll.contentSize.width)
        XCTAssertGreaterThanOrEqual(glyphOrigin.x, ruler.frame.maxX)
        XCTAssertEqual(scroll.contentView.bounds.minX, -scroll.contentView.contentInsets.left, accuracy: 1)

        scroll.contentView.scroll(to: NSPoint(x: 250, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.setContentSize(NSSize(width: 320, height: 240))
        await settle(window)
        XCTAssertEqual(scroll.contentView.bounds.minX, 250, accuracy: 1, "Resizing must preserve manual horizontal scrolling.")
    }

    func testReplacingFileResetsScrollAndSelectionAndShrinksDocument() async throws {
        let large = Array(repeating: String(repeating: "source ", count: 80), count: 100).joined(separator: "\n")
        let window = makeWindow(CodeTextView(text: large))
        defer { window.orderOut(nil) }
        await settle(window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CodeTextView>)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        text.setSelectedRange(NSRange(location: 20, length: 10))
        scroll.contentView.scroll(to: NSPoint(x: 500, y: 500))
        hosting.rootView = CodeTextView(text: "let replacement = true")
        await settle(window)
        XCTAssertEqual(text.string, "let replacement = true")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(scroll.contentView.bounds.minX, -scroll.contentView.contentInsets.left, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.contentView.contentInsets.top, accuracy: 1)
        XCTAssertEqual(text.frame.width, viewportSize(scroll).width, accuracy: 1)
        XCTAssertEqual(text.frame.height, viewportSize(scroll).height, accuracy: 1)
    }

    func testFindRequestAndCommandFOpenInlineFindBarWithoutReplacingText() async throws {
        let window = makeWindow(CodeTextView(text: "first match\nsecond match", findRequest: 3))
        defer { window.orderOut(nil) }
        await settle(window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CodeTextView>)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertFalse(scroll.isFindBarVisible)
        hosting.rootView = CodeTextView(text: text.string, findRequest: 4)
        await settle(window)
        XCTAssertTrue(scroll.isFindBarVisible)
        XCTAssertEqual(text.string, "first match\nsecond match")
        scroll.isFindBarVisible = false
        window.makeFirstResponder(text)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(text.performKeyEquivalent(with: event))
        XCTAssertTrue(scroll.isFindBarVisible)
    }

    func testSelectionStillReportsUnicodeTextAndLineNumbers() async throws {
        let source = "let face = \"🙂\"\nlet answer = 42\nprint(answer)"
        var selection: String?, lines: ClosedRange<Int>?
        let window = makeWindow(CodeTextView(text: source, onSelection: { selection = $0; lines = $1 }))
        defer { window.orderOut(nil) }
        await settle(window)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: window.contentView!))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let selected = "🙂\"\nlet answer = 42"
        text.setSelectedRange((source as NSString).range(of: selected))
        XCTAssertEqual(selection, selected)
        XCTAssertEqual(lines, 1...2)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(selection, "")
        XCTAssertNil(lines)
    }

    func testAppearanceControlsWrapWithoutLosingTextAndApplySyntaxColors() async throws {
        let code = "let greeting = \"https://example.com🙂\" // a comment\n" + String(repeating: "print(greeting); ", count: 70)
        let window = makeWindow(CodeTextView(text: code, filePath: "Example.swift"))
        defer { window.orderOut(nil) }
        await settle(window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CodeTextView>)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let initialHeight = text.frame.height
        text.setSelectedRange((code as NSString).range(of: "greeting"))
        hosting.rootView = CodeTextView(text: code, filePath: "Example.swift", fontSize: 18, wrapsLines: true)
        await settle(window)
        XCTAssertEqual(text.string, code)
        XCTAssertEqual(text.font?.pointSize, 18)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(text.frame.width, viewportSize(scroll).width, accuracy: 1)
        XCTAssertGreaterThan(text.frame.height, initialHeight)
        XCTAssertEqual(text.selectedRange(), (code as NSString).range(of: "greeting"))
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemPurple)
        let urlOffset = (code as NSString).range(of: "https://").location
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: urlOffset, effectiveRange: nil) as? NSColor, .systemGreen)
        hosting.rootView = CodeTextView(text: code, filePath: "Example.swift", fontSize: 18, wrapsLines: true, syntaxHighlighting: false)
        await settle(window)
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
    }

    func testRecreatingFileViewRestoresItsOwnViewportAndSelection() async throws {
        let source = Array(repeating: String(repeating: "file contents ", count: 60), count: 120).joined(separator: "\n")
        let state = CodeDocumentState()
        let first = makeWindow(CodeTextView(text: source, documentState: state))
        await settle(first)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: first.contentView!))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        text.setSelectedRange(NSRange(location: 15, length: 12))
        scroll.contentView.scroll(to: NSPoint(x: 220, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        XCTAssertEqual(state.scrollOrigin, origin)
        first.orderOut(nil)
        first.contentView = nil

        let restored = makeWindow(CodeTextView(text: source, documentState: state))
        defer { restored.orderOut(nil) }
        await settle(restored)
        let restoredScroll = try XCTUnwrap(find(NSScrollView.self, in: restored.contentView!))
        let restoredText = try XCTUnwrap(restoredScroll.documentView as? NSTextView)
        XCTAssertEqual(restoredScroll.contentView.bounds.minX, origin.x, accuracy: 1)
        XCTAssertEqual(restoredScroll.contentView.bounds.minY, origin.y, accuracy: 1)
        XCTAssertEqual(restoredText.selectedRange(), NSRange(location: 15, length: 12))
    }

    func testEnablingWrapAfterHorizontalScrollKeepsFirstColumnVisible() async throws {
        let source = Array(repeating: "let value = \"" + String(repeating: "long source ", count: 60) + "\"", count: 100).joined(separator: "\n")
        let window = makeWindow(CodeTextView(text: source))
        defer { window.orderOut(nil) }
        await settle(window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CodeTextView>)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let selected = NSRange(location: 0, length: 9)
        text.setSelectedRange(selected)
        scroll.contentView.scroll(to: NSPoint(x: 500, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.rootView = CodeTextView(text: source, wrapsLines: true)
        await settle(window)
        XCTAssertEqual(scroll.contentView.bounds.minX, -scroll.contentView.contentInsets.left, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Wrapping must not jump back to the top.")
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertGreaterThanOrEqual(text.convert(NSPoint(x: 8, y: 8), to: scroll).x,
                                   try XCTUnwrap(scroll.verticalRulerView).frame.maxX)
        XCTAssertEqual(text.frame.width, viewportSize(scroll).width, accuracy: 1)
    }

    func testGoToLineUsesUTF16RangesAndScrollsToRequestedLine() async throws {
        let source = (1...120).map { "line \($0) 🙂" }.joined(separator: "\n")
        let window = makeWindow(CodeTextView(text: source))
        defer { window.orderOut(nil) }
        await settle(window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CodeTextView>)
        hosting.rootView = CodeTextView(text: source, goToLine: 90, goToLineRequest: 1)
        await settle(window)
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual((source as NSString).substring(with: text.selectedRange()), "line 90 🙂\n")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500)
        XCTAssertNil(CodeTextView.range(ofLine: 0, in: source))
        XCTAssertNil(CodeTextView.range(ofLine: 121, in: source))
        XCTAssertEqual(CodeTextView.range(ofLine: 2, in: "one\n"), NSRange(location: 4, length: 0))
        XCTAssertEqual(CodeTextView.range(ofLine: 2, in: "🙂\r\ntwo"), NSRange(location: 4, length: 3))
    }

    private func makeWindow(_ view: CodeTextView, size: NSSize = NSSize(width: 480, height: 220)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func viewportSize(_ scroll: NSScrollView) -> NSSize {
        let insets = scroll.contentView.contentInsets
        return NSSize(width: scroll.contentView.bounds.width - insets.left - insets.right,
                      height: scroll.contentView.bounds.height - insets.top - insets.bottom)
    }
}

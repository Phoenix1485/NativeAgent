import AppKit
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    let text: String
    var onSelection: ((String, ClosedRange<Int>?) -> Void)?
    var findRequest: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection, findRequest: findRequest) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: ((String, ClosedRange<Int>?) -> Void)?
        var lastFindRequest: Int
        init(onSelection: ((String, ClosedRange<Int>?) -> Void)?, findRequest: Int) {
            self.onSelection = onSelection
            lastFindRequest = findRequest
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange(), text = view.string as NSString
            guard range.length > 0, NSMaxRange(range) <= text.length else { onSelection?("", nil); return }
            let start = text.substring(to: range.location).filter { $0 == "\n" }.count + 1
            let end = text.substring(to: NSMaxRange(range) - 1).filter { $0 == "\n" }.count + 1
            onSelection?(text.substring(with: range), start...max(start, end))
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.findBarPosition = .aboveContent
        let textView = SearchableCodeTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRulerView(textView: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
        guard let textView = scroll.documentView as? SearchableCodeTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            (scroll as? CodeScrollView)?.sizeDocumentToFit()
            (scroll as? CodeScrollView)?.resetToBeginningAfterLayout()
            scroll.verticalRulerView?.needsDisplay = true
        }
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            DispatchQueue.main.async { [weak textView] in textView?.showFindBar() }
        }
    }
}

private final class CodeScrollView: NSScrollView {
    private var sizingDocument = false
    private var pendingScrollReset = false

    override func layout() {
        super.layout()
        sizeDocumentToFit()
        if pendingScrollReset {
            pendingScrollReset = false
            let insets = contentView.contentInsets
            contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
            reflectScrolledClipView(contentView)
        }
    }

    func resetToBeginningAfterLayout() {
        // The ruler's inset is installed during native layout, after SwiftUI's
        // initial content update. Resetting earlier can hide the first columns.
        pendingScrollReset = true
        needsLayout = true
    }

    func sizeDocumentToFit() {
        guard !sizingDocument, let textView = documentView as? NSTextView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        sizingDocument = true
        defer { sizingDocument = false }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).union(layout.extraLineFragmentUsedRect)
        let insets = contentView.contentInsets
        let viewport = NSSize(width: max(0, contentView.bounds.width - insets.left - insets.right),
                              height: max(0, contentView.bounds.height - insets.top - insets.bottom))
        textView.minSize = viewport
        // Text layout and the document frame must agree. AppKit's initial frame can be
        // smaller than the laid-out code, especially when SwiftUI starts at zero size.
        let size = NSSize(
            width: max(viewport.width, ceil(used.maxX) + 2 * textView.textContainerInset.width + container.lineFragmentPadding),
            height: max(viewport.height, ceil(used.maxY) + 2 * textView.textContainerInset.height)
        )
        if textView.frame.size != size { textView.setFrameSize(size) }
    }
}

private final class SearchableCodeTextView: NSTextView {
    func showFindBar() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        window?.makeFirstResponder(self)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(action)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            showFindBar()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in self?.needsDisplay = true })
        if let content = textView.enclosingScrollView?.contentView {
            content.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: content, queue: .main) { [weak self] _ in self?.needsDisplay = true })
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        // AppKit can invalidate a rect wider than this gutter. Clip explicitly so
        // its background cannot paint over the code or neighboring SwiftUI views.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString
        var line = 1
        if characterRange.location > 0 {
            line += string.substring(to: characterRange.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        var index = characterRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while index < NSMaxRange(characterRange), index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyph, in: container)
            let y = box.minY + textView.textContainerInset.height - visible.minY
            let value = "\(line)" as NSString
            let size = value.size(withAttributes: attributes)
            value.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: y), withAttributes: attributes)
            line += 1
            index = NSMaxRange(lineRange)
        }
    }
}

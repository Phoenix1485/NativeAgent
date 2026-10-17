import AppKit
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    let text: String
    var onSelection: ((String, ClosedRange<Int>?) -> Void)?
    var findRequest: Int = 0
    var filePath = ""
    var fontSize: Double = 12
    var wrapsLines = false
    var syntaxHighlighting = true
    var documentState: CodeDocumentState?
    var goToLine: Int?
    var goToLineRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection, findRequest: findRequest) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: ((String, ClosedRange<Int>?) -> Void)?
        var lastFindRequest: Int
        var lastGoToLineRequest = 0
        var documentState: CodeDocumentState?
        var isUpdatingDocument = false
        var hasLoadedDocument = false
        var highlightTask: Task<Void, Never>?
        var styleKey = ""
        deinit { highlightTask?.cancel() }
        init(onSelection: ((String, ClosedRange<Int>?) -> Void)?, findRequest: Int) {
            self.onSelection = onSelection
            lastFindRequest = findRequest
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            guard !isUpdatingDocument else { return }
            reportSelection(in: view)
        }
        @MainActor func reportSelection(in view: NSTextView) {
            let range = view.selectedRange(), text = view.string as NSString
            documentState?.selection = range
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
        let coordinator = context.coordinator
        coordinator.documentState = documentState
        let codeScroll = scroll as? CodeScrollView
        codeScroll?.trackDocument(documentState)
        let changed = textView.string != text || !coordinator.hasLoadedDocument
        if changed {
            coordinator.isUpdatingDocument = true
            let saved = coordinator.hasLoadedDocument ? nil : documentState?.scrollOrigin
            let selection = saved == nil ? NSRange(location: 0, length: 0) : documentState?.selection ?? NSRange(location: 0, length: 0)
            codeScroll?.restoreAfterLayout(saved)
            textView.string = text
            textView.setSelectedRange(NSMaxRange(selection) <= (text as NSString).length ? selection : NSRange(location: 0, length: 0))
            coordinator.hasLoadedDocument = true
            coordinator.isUpdatingDocument = false
            if selection.length > 0 {
                DispatchQueue.main.async { [weak textView, weak coordinator] in
                    guard let textView, textView.window?.isKeyWindow == true else { return }
                    coordinator?.reportSelection(in: textView)
                }
            }
            scroll.verticalRulerView?.needsDisplay = true
        }
        codeScroll?.wrapsLines = wrapsLines
        scroll.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        let safeFontSize = min(28, max(9, fontSize))
        let styleKey = "\(filePath)|\(safeFontSize)|\(syntaxHighlighting)"
        if changed || coordinator.styleKey != styleKey {
            coordinator.styleKey = styleKey
            coordinator.highlightTask?.cancel()
            textView.font = .monospacedSystemFont(ofSize: safeFontSize, weight: .regular)
            textView.textColor = .textColor
            textView.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: safeFontSize, weight: .regular), .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: (text as NSString).length))
            if syntaxHighlighting, !filePath.isEmpty {
                let source = text, path = filePath
                coordinator.highlightTask = Task { @MainActor [weak textView] in
                    let work = Task.detached(priority: .utility) { CodeSyntaxHighlighter.tokens(in: source, path: path) }
                    let tokens = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                    guard !Task.isCancelled, let textView, textView.string == source, let storage = textView.textStorage else { return }
                    storage.beginEditing()
                    for token in tokens { storage.addAttribute(.foregroundColor, value: CodeSyntaxHighlighter.color(for: token.kind), range: token.range) }
                    storage.endEditing()
                }
            }
        }
        codeScroll?.sizeDocumentToFit()
        if coordinator.lastGoToLineRequest != goToLineRequest {
            coordinator.lastGoToLineRequest = goToLineRequest
            if let goToLine, let range = Self.range(ofLine: goToLine, in: text) {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window != nil else { return }
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            DispatchQueue.main.async { [weak textView] in textView?.showFindBar() }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        (scroll as? CodeScrollView)?.saveViewport()
    }

    static func range(ofLine requested: Int, in text: String) -> NSRange? {
        guard requested > 0 else { return nil }
        let source = text as NSString
        var line = 1, offset = 0
        while line < requested, offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
        guard line == requested, offset < source.length || (offset == source.length && (text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\r"))) else { return nil }
        let range = source.lineRange(for: NSRange(location: offset, length: 0))
        return NSRange(location: range.location, length: range.length)
    }
}

private final class CodeScrollView: NSScrollView {
    private var sizingDocument = false
    private var pendingScrollRestore = false
    private var pendingOrigin: NSPoint?
    private var documentState: CodeDocumentState?
    private var boundsObserver: NSObjectProtocol?
    private var observedViewportSize: NSSize?
    private var viewportLayoutScheduled = false
    var wrapsLines = false

    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func trackDocument(_ state: CodeDocumentState?) {
        documentState = state
        guard boundsObserver == nil else { return }
        observedViewportSize = viewportSize
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in self?.clipBoundsDidChange() }
    }

    private var viewportSize: NSSize {
        let insets = contentView.contentInsets
        return NSSize(width: max(0, contentView.bounds.width - insets.left - insets.right),
                      height: max(0, contentView.bounds.height - insets.top - insets.bottom))
    }

    private func clipBoundsDidChange() {
        saveViewport()
        let viewport = viewportSize
        guard observedViewportSize != viewport else { return }
        observedViewportSize = viewport
        guard !viewportLayoutScheduled else { return }
        viewportLayoutScheduled = true
        // A legacy scrollbar can appear after document sizing, taking another
        // 15 points from the clip view. Reflow after AppKit finishes tiling;
        // ordinary scrolling changes only the origin and does not schedule work.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportLayoutScheduled = false
            self.sizeDocumentToFit()
            self.needsLayout = true
        }
    }

    func saveViewport() {
        guard !pendingScrollRestore, contentView.bounds.width > 80, contentView.bounds.height > 40 else { return }
        documentState?.scrollOrigin = contentView.bounds.origin
        if let textView = documentView as? NSTextView { documentState?.selection = textView.selectedRange() }
    }

    override func tile() {
        super.tile()
        // Scroller tiling can change contentInsets without changing the clip
        // view's bounds, so bounds notifications alone miss that adjustment.
        clipBoundsDidChange()
    }

    override func layout() {
        super.layout()
        sizeDocumentToFit()
        if pendingScrollRestore, contentView.bounds.width > 80, contentView.bounds.height > 40 {
            let insets = contentView.contentInsets
            contentView.scroll(to: pendingOrigin ?? NSPoint(x: -insets.left, y: -insets.top))
            reflectScrolledClipView(contentView)
            pendingScrollRestore = false
            saveViewport()
        }
    }

    func restoreAfterLayout(_ origin: NSPoint?) {
        // The ruler's inset is installed during native layout, after SwiftUI's
        // initial content update. Resetting earlier can hide the first columns.
        pendingOrigin = origin
        pendingScrollRestore = true
        needsLayout = true
    }

    func sizeDocumentToFit() {
        guard !sizingDocument, let textView = documentView as? NSTextView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        sizingDocument = true
        defer { sizingDocument = false }
        let viewport = viewportSize
        // Hidden tabs can temporarily have no viewport. Keep their existing
        // layout until visible rather than wrapping a large file at one point.
        guard viewport.width > 0, viewport.height > 0 else { return }
        let width = wrapsLines ? max(1, viewport.width - 2 * textView.textContainerInset.width) : CGFloat.greatestFiniteMagnitude
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).union(layout.extraLineFragmentUsedRect)
        textView.minSize = viewport
        // Text layout and the document frame must agree. AppKit's initial frame can be
        // smaller than the laid-out code, especially when SwiftUI starts at zero size.
        let size = NSSize(
            width: wrapsLines ? viewport.width : max(viewport.width, ceil(used.maxX) + 2 * textView.textContainerInset.width + container.lineFragmentPadding),
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

import AppKit
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    let text: String
    var onSelection: ((String, ClosedRange<Int>?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: ((String, ClosedRange<Int>?) -> Void)?
        init(onSelection: ((String, ClosedRange<Int>?) -> Void)?) { self.onSelection = onSelection }
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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
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
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        scroll.verticalRulerView?.needsDisplay = true
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
        NSColor.windowBackgroundColor.setFill(); rect.fill()
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

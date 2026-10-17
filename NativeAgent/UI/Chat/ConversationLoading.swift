import AppKit
import SwiftUI

enum HistoryPageDirection { case older, newer }

/// Layout changes alone never fetch another page. Every fetch consumes actual scroll intent.
struct HistoryPagingIntent {
    private(set) var direction: HistoryPageDirection?
    mutating func scroll(_ direction: HistoryPageDirection) { self.direction = direction }
    mutating func reset() { direction = nil }
    mutating func take(nearTop: Bool, nearBottom: Bool, hasOlder: Bool, hasNewer: Bool, busy: Bool) -> HistoryPageDirection? {
        guard !busy, let direction else { return nil }
        guard direction == .older ? nearTop && hasOlder : nearBottom && hasNewer else { return nil }
        self.direction = nil
        return direction
    }
}

/// Static placeholders: no timer or continuous shimmer competes with history loading.
struct ConversationSkeleton: View {
    var rows = 3
    var label = "Loading recent messages…"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<rows, id: \.self) { index in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 7).frame(width: 26, height: 26)
                        Capsule().frame(width: index.isMultiple(of: 2) ? 64 : 92, height: 10)
                    }
                    RoundedRectangle(cornerRadius: 5).frame(height: 11)
                    RoundedRectangle(cornerRadius: 5).frame(maxWidth: index.isMultiple(of: 2) ? 290 : 400).frame(height: 11)
                }.foregroundStyle(.secondary.opacity(0.12))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// Observes only the enclosing timeline's user scrolling, not programmatic scrollTo/layout.
struct TimelineScrollActivity: NSViewRepresentable {
    var onScroll: (HistoryPageDirection) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll; view.attach() }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        var onScroll: ((HistoryPageDirection) -> Void)?
        private weak var scrollView: NSScrollView?
        private var previousY: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() }
            else { DispatchQueue.main.async { [weak self] in self?.attach() } }
        }
        func attach() {
            guard let enclosingScrollView, scrollView !== enclosingScrollView else { return }
            detach(); scrollView = enclosingScrollView
            previousY = enclosingScrollView.documentVisibleRect.minY
            NotificationCenter.default.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: enclosingScrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didLiveScrollNotification, object: enclosingScrollView)
        }
        func detach() { NotificationCenter.default.removeObserver(self); scrollView = nil }
        @objc private func started(_ notification: Notification) {
            if let scrollView { previousY = scrollView.documentVisibleRect.minY }
        }
        @objc private func scrolled(_ notification: Notification) {
            guard let scrollView else { return }
            let y = scrollView.documentVisibleRect.minY
            let delta = (y - previousY) * (scrollView.documentView?.isFlipped == true ? 1 : -1)
            previousY = y
            guard abs(delta) > 0.1 else { return }
            onScroll?(delta < 0 ? .older : .newer)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

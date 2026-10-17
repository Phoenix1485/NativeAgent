import SwiftUI
import AppKit

/// Only a hovered, overflowing title schedules animation frames.
struct ScrollingChatTitle: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var started = Date.now
    private var textWidth: CGFloat {
        (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
    }

    static func offset(elapsed: TimeInterval, width: CGFloat) -> CGFloat {
        let distance = width + 32
        let cycle = 0.7 + Double(distance / 30)
        let time = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        return -min(distance, CGFloat(max(0, time - 0.7)) * 30)
    }

    var body: some View {
        GeometryReader { geometry in
            let overflowing = textWidth > geometry.size.width
            Group {
                if hovered && overflowing && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        HStack(spacing: 32) {
                            Text(title).fixedSize()
                            Text(title).fixedSize()
                        }
                        .offset(x: Self.offset(elapsed: context.date.timeIntervalSince(started), width: textWidth))
                        .frame(width: geometry.size.width, alignment: .leading)
                    }
                } else {
                    Text(title).lineLimit(1).truncationMode(.tail)
                        .frame(width: geometry.size.width, alignment: .leading)
                }
            }
            .font(.system(size: 13))
            .frame(height: geometry.size.height)
            .mask {
                if overflowing {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0.3)], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    }
                } else { Color.black }
            }
            .clipped().contentShape(Rectangle())
            .onHover { inside in hovered = inside; started = .now }
            .onChange(of: title) { started = .now }
            .onDisappear { hovered = false }
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .help(title)
        }.frame(height: 18)
    }
}

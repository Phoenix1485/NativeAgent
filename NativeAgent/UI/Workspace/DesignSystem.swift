import AppKit
import SwiftUI

enum Studio {
    static let accent = Color.accentColor
    static let canvas = adaptive(light: 0xFAFAF9, dark: 0x19191C)
    static let sidebar = adaptive(light: 0xF0F0EF, dark: 0x121214)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x222225)
    static let hover = adaptive(light: 0xE7E7E6, dark: 0x2C2C30)
    static let line = Color.primary.opacity(0.07)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.secondary).padding(7)
            .background(configuration.isPressed ? Studio.hover : Color.clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    var selected = false
    var tint: Color = .secondary
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(selected ? Studio.accent : tint).frame(width: 18)
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 9)
            .background(selected ? Studio.accent.opacity(0.12) : (hovering ? Studio.hover : .clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

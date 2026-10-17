import AppKit
import CoreText

enum ChatExport {
    static func pdf(_ text: String) throws -> Data {
        let output = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: output as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw NativeAgentError.unsupported("Could not create PDF.") }
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: page.insetBy(dx: 40, dy: 40), transform: nil)
        var offset = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            offset += visible.length
        } while offset < attributed.length
        context.closePDF()
        return output as Data
    }
}

import XCTest
import PDFKit
@testable import NativeAgent

final class MediaAttachmentTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhOQAAAAASUVORK5CYII=")!

    func testImageRoundTripsAndUsesActualBinaryInput() throws {
        let item = try MediaAttachmentService.attachment(data: png, name: "screenshot.png")
        let restored = try JSONDecoder().decode(ContextAttachment.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.mediaData, png)
        XCTAssertEqual(restored.mimeType, "image/png")
        XCTAssertEqual(restored.allowEdits, false)
        let parts = try MediaAttachmentService.inputParts([restored])
        XCTAssertEqual(parts.last?["type"]?.stringValue, "input_image")
        XCTAssertEqual(parts.last?["image_url"]?.stringValue, "data:image/png;base64," + png.base64EncodedString())
        XCTAssertThrowsError(try MediaAttachmentService.attachment(data: Data("not an image".utf8), name: "fake.png"))
        XCTAssertThrowsError(try MediaAttachmentService.attachment(data: Data(repeating: 0, count: MediaAttachmentService.fileLimit + 1), name: "huge.png"))
    }

    @MainActor
    func testPDFIsPreviewableAndSentInlineWithoutUploadAPI() throws {
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: NSImage(data: png)!)), at: 0)
        let data = try XCTUnwrap(pdf.dataRepresentation())
        let item = try MediaAttachmentService.attachment(data: data, name: "document.pdf")
        XCTAssertEqual(item.mimeType, "application/pdf")
        let parts = try MediaAttachmentService.inputParts([item])
        XCTAssertEqual(parts.last?["type"]?.stringValue, "input_file")
        XCTAssertEqual(parts.last?["filename"]?.stringValue, "document.pdf")
        XCTAssertTrue(parts.last?["file_data"]?.stringValue?.hasPrefix("data:application/pdf;base64,") == true)
    }

    func testOlderTextAttachmentsRemainReadable() throws {
        let item = ContextAttachment(kind: .attachment, title: "Old file", text: "contents")
        let restored = try JSONDecoder().decode(ContextAttachment.self, from: JSONEncoder().encode(item))
        XCTAssertFalse(restored.isMedia)
        XCTAssertTrue(try MediaAttachmentService.inputParts([restored]).isEmpty)
    }
}

import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum MediaAttachmentService {
    static let fileLimit = 8 * 1_048_576
    static let totalLimit = 12 * 1_048_576
    static func supports(_ url: URL) -> Bool { ["png", "jpg", "jpeg", "webp", "gif", "pdf"].contains(url.pathExtension.lowercased()) }

    static func load(_ url: URL) throws -> ContextAttachment {
        guard url.isFileURL, supports(url) else { throw NativeAgentError.unsupported("Choose a PNG, JPEG, WebP, GIF or PDF file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= fileLimit else {
            throw NativeAgentError.unsupported("Media must be a regular file up to 8 MiB; symbolic links are not accepted.")
        }
        let data = try Data(contentsOf: url)
        return try attachment(data: data, name: url.lastPathComponent, source: url.path)
    }

    static func attachment(data: Data, name: String, source: String? = nil) throws -> ContextAttachment {
        guard !data.isEmpty, data.count <= fileLimit else { throw NativeAgentError.unsupported("Media files must be between 1 byte and 8 MiB.") }
        let mime: String
        var detail: String
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 50 else {
                throw NativeAgentError.unsupported("Choose an unlocked PDF with 1–50 pages.")
            }
            mime = "application/pdf"; detail = "PDF · \(pdf.pageCount) pages"
        } else {
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) == 1,
                  let type = CGImageSourceGetType(image) as String?, let contentType = UTType(type),
                  let mediaType = contentType.preferredMIMEType, ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mediaType),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000 else {
                throw NativeAgentError.unsupported("Choose a valid, non-animated image up to 40 megapixels and 16,384 pixels per side.")
            }
            mime = mediaType; detail = "Image · \(width) × \(height)"
        }
        detail += " · \(data.count) bytes · snapshot sent to the selected ChatGPT model"
        return ContextAttachment(kind: .attachment, title: name, text: "", sourceHash: TaskFileService.hash(data), metadata: detail,
                                 sourceURL: source, allowEdits: false, mediaData: data, mimeType: mime)
    }

    static func inputParts(_ attachments: [ContextAttachment]) throws -> [JSONValue] {
        let media = attachments.filter(\.isMedia)
        guard media.reduce(0, { $0 + ($1.mediaData?.count ?? 0) }) <= totalLimit else { throw NativeAgentError.unsupported("Image/PDF attachments exceed 12 MiB total.") }
        return try media.flatMap { item -> [JSONValue] in
            guard let data = item.mediaData, let mime = item.mimeType else { throw NativeAgentError.unsupported("Invalid media attachment.") }
            let checked = try attachment(data: data, name: item.title)
            guard checked.mimeType == mime else { throw NativeAgentError.unsupported("Attachment format does not match its content.") }
            let encoded = "data:\(mime);base64,\(data.base64EncodedString())"
            let part: JSONValue = mime == "application/pdf"
                ? .object(["type": .string("input_file"), "filename": .string(item.title), "file_data": .string(encoded)])
                : .object(["type": .string("input_image"), "image_url": .string(encoded), "detail": .string("auto")])
            return [.object(["type": .string("input_text"), "text": .string("User-attached file: \(item.title)")]), part]
        }
    }
}

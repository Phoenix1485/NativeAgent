// Public-key-only verification, shared by local releases and GitHub Pages CI.
// Sparkle 2.10's signed-feed format appends a signature comment to the XML bytes.
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct VerificationError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func verifyUpdate(publicKey: String, feedPath: String, archivePath: String) throws {
    guard let rawKey = Data(base64Encoded: publicKey), rawKey.count == 32 else {
        throw VerificationError("Invalid Ed25519 public key")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: URL(fileURLWithPath: feedPath))
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let start = feed.range(of: prefix, options: .backwards),
          let block = String(data: feed[start.upperBound...], encoding: .utf8) else {
        throw VerificationError("Missing signed-feed block")
    }
    let pattern = #"\AedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\z"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
          let signatureRange = Range(match.range(at: 1), in: block),
          let lengthRange = Range(match.range(at: 2), in: block),
          let signature = Data(base64Encoded: String(block[signatureRange])),
          Int(block[lengthRange]) == start.lowerBound else {
        throw VerificationError("Malformed feed signature or length")
    }
    let content = Data(feed[..<start.lowerBound])
    guard key.isValidSignature(signature, for: content) else {
        throw VerificationError("Feed signature verification failed")
    }
    let xml = try XMLDocument(data: content, options: .nodeLoadExternalEntitiesNever)
    let enclosures = try xml.nodes(forXPath: "/rss/channel/item/enclosure")
    guard enclosures.count == 1, let enclosure = enclosures.first as? XMLElement,
          let encoded = enclosure.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue,
          let archiveSignature = Data(base64Encoded: encoded),
          let length = enclosure.attribute(forName: "length")?.stringValue else {
        throw VerificationError("Expected one signed archive")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: archivePath), options: .mappedIfSafe)
    guard Int(length) == archive.count, key.isValidSignature(archiveSignature, for: archive) else {
        throw VerificationError("Archive signature or length verification failed")
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw VerificationError("Usage: swift verify-update.swift PUBLIC_KEY APPCAST ARCHIVE")
    }
    try verifyUpdate(publicKey: CommandLine.arguments[1], feedPath: CommandLine.arguments[2], archivePath: CommandLine.arguments[3])
    print("Verified Ed25519 feed and archive signatures using only the public key.")
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}

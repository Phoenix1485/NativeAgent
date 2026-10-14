// Real Ed25519 round-trip and tamper tests. Test keys exist only in memory.
import CryptoKit
import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nativeagent-signature-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let verifier = directory.appendingPathComponent("verify-update")
func process(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    return task.terminationStatus
}
guard try process("/usr/bin/xcrun", ["swiftc", "Scripts/verify-update.swift", "-o", verifier.path]) == 0 else {
    fputs("Could not compile signature verifier\n", stderr)
    exit(1)
}
let key = Curve25519.Signing.PrivateKey()
let archive = Data("signed test archive".utf8)
let archivePath = directory.appendingPathComponent("NativeAgent.zip")
let feedPath = directory.appendingPathComponent("appcast.xml")
let signature = try key.signature(for: archive).base64EncodedString()
let xml = Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><enclosure length=\"\(archive.count)\" sparkle:edSignature=\"\(signature)\"/></item></channel></rss>\n".utf8)
let feed = xml + Data("<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: xml).base64EncodedString())\nlength: \(xml.count)\n-->\n".utf8)
func check(_ label: String, feed input: Data, archive bytes: Data, publicKey: Data? = nil, succeeds: Bool) throws {
    try input.write(to: feedPath)
    try bytes.write(to: archivePath)
    let status = try process(verifier.path, [(publicKey ?? key.publicKey.rawRepresentation).base64EncodedString(), feedPath.path, archivePath.path])
    guard (status == 0) == succeeds else { fatalError("Unexpected verification result: \(label)") }
    print("PASS: \(label)")
}
try check("valid feed and archive", feed: feed, archive: archive, succeeds: true)
try check("archive tampering", feed: feed, archive: archive + Data([0]), succeeds: false)
try check("feed tampering", feed: Data(" ".utf8) + feed, archive: archive, succeeds: false)
try check("unsigned feed", feed: xml, archive: archive, succeeds: false)
try check("unsigned trailing content", feed: feed + Data("<item/>".utf8), archive: archive, succeeds: false)
try check("wrong public key", feed: feed, archive: archive, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, succeeds: false)
print("All 6 public-key signature checks passed.")

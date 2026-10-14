import AppKit
import WebKit
import XCTest
@testable import NativeAgent

final class LocalAuthenticationPageTests: XCTestCase {
    func testAllPagesRenderOfflineWithAccessibleResponsiveMarkup() throws {
        for state in LocalAuthenticationPage.State.allCases {
            let html = try LocalAuthenticationPage.html(for: state, nonce: "fixture")
            XCTAssertTrue(html.hasPrefix("<!doctype html>"))
            XCTAssertTrue(html.contains("NativeAgent"))
            XCTAssertTrue(html.contains("<html lang=\"en\">"))
            XCTAssertTrue(html.contains("aria-labelledby=\"heading\""))
            XCTAssertTrue(html.contains("prefers-reduced-motion: reduce"))
            XCTAssertTrue(html.contains("prefers-color-scheme: light"))
            XCTAssertTrue(html.contains("max-width: 520px"))
            XCTAssertTrue(html.contains("summary:focus-visible"))
            XCTAssertTrue(html.contains("history.replaceState"))
            XCTAssertFalse(html.contains("{{"))
            for forbidden in ["https://", "http://", "fetch(", "setInterval(", "setTimeout(", "window.close(", "<iframe", "<form"] {
                XCTAssertFalse(html.contains(forbidden), forbidden)
            }
        }
        let received = try LocalAuthenticationPage.html(for: .received, nonce: "fixture")
        XCTAssertTrue(received.contains("still needs to verify"))
        XCTAssertFalse(received.contains("You’re connected"))
    }

    func testResponseUsesMatchingNonceAndByteLengthAndNoCaching() throws {
        var nonces = Set<String>()
        for state in LocalAuthenticationPage.State.allCases {
            let response = String(decoding: try LocalAuthenticationPage.response(for: state), as: UTF8.self)
            let parts = response.components(separatedBy: "\r\n\r\n")
            XCTAssertEqual(parts.count, 2)
            let headers = parts[0], html = parts[1]
            XCTAssertTrue(headers.hasPrefix(state == .notFound ? "HTTP/1.1 404 Not Found" : "HTTP/1.1 200 OK"))
            XCTAssertTrue(headers.contains("Content-Type: text/html; charset=utf-8"))
            XCTAssertTrue(headers.contains("Content-Length: \(html.utf8.count)"))
            for policy in ["Cache-Control: no-store", "Referrer-Policy: no-referrer", "X-Content-Type-Options: nosniff",
                           "default-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"] {
                XCTAssertTrue(headers.contains(policy), policy)
            }
            let nonce = try XCTUnwrap(html.components(separatedBy: "<style nonce=\"").last?.components(separatedBy: "\"").first)
            XCTAssertEqual(nonce.count, 32)
            XCTAssertTrue(headers.contains("style-src 'nonce-\(nonce)'"))
            XCTAssertTrue(headers.contains("script-src 'nonce-\(nonce)'"))
            XCTAssertTrue(html.contains("<script nonce=\"\(nonce)\">"))
            nonces.insert(nonce)
        }
        XCTAssertEqual(nonces.count, 3)
    }

    func testCallbackPresentationNeverReflectsUntrustedParameters() throws {
        let callback = URL(string: "http://127.0.0.1:54321/auth/callback?error=access_denied&error_description=%3Cscript%3Eattack%3C/script%3E&code=secret-code&state=secret-state")!
        XCTAssertEqual(LocalAuthenticationPage.state(for: callback), .notCompleted)
        XCTAssertEqual(LocalAuthenticationPage.state(for: nil), .notFound)
        XCTAssertEqual(LocalAuthenticationPage.state(for: URL(string: "http://127.0.0.1:54321/auth/callback?code=secret-code")), .received)
        let html = try LocalAuthenticationPage.html(for: LocalAuthenticationPage.state(for: callback), nonce: "fixture")
        for secret in ["attack", "secret-code", "secret-state", "access_denied"] { XCTAssertFalse(html.contains(secret)) }
        XCTAssertTrue(html.contains("Sign-in not completed"))
    }

    func testMissingPageDoesNotConsumeCallbackAndDeniedCallbackIsStyled() async throws {
        let listener = ChatGPTLoopback()
        defer { listener.cancel() }
        let redirect = try await listener.start()
        let missing = redirect.deletingLastPathComponent().appendingPathComponent("missing")
        let (missingData, missingResponse) = try await URLSession.shared.data(from: missing)
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(String(decoding: missingData, as: UTF8.self).contains("Page not found"))
        let callback = URL(string: redirect.absoluteString + "?error=access_denied&state=private-state")!
        let result = Task { try await listener.result() }
        let (data, response) = try await URLSession.shared.data(from: callback)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("Sign-in not completed"))
        XCTAssertFalse(html.contains("private-state"))
        let received = try await result.value
        XCTAssertEqual(received, callback)
    }

    @MainActor
    func testBrowserVisuals() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NATIVEAGENT_AUTH_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_AUTH_SNAPSHOT_DIR to render localhost pages in WebKit.")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let variants: [(String, LocalAuthenticationPage.State, NSSize, NSAppearance.Name)] = [
            ("received-dark", .received, NSSize(width: 1280, height: 900), .darkAqua),
            ("declined-dark", .notCompleted, NSSize(width: 1280, height: 900), .darkAqua),
            ("missing-light", .notFound, NSSize(width: 1280, height: 900), .aqua),
            ("received-mobile", .received, NSSize(width: 375, height: 900), .darkAqua)
        ]
        for (name, state, size, appearance) in variants {
            let webView = WKWebView(frame: NSRect(origin: .zero, size: size))
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = webView
            let loaded = expectation(description: name)
            let delegate = PageNavigationDelegate(loaded: loaded)
            webView.navigationDelegate = delegate
            window.orderFront(nil)
            defer { window.orderOut(nil); webView.navigationDelegate = nil }
            webView.loadHTMLString(try LocalAuthenticationPage.html(for: state, nonce: "preview"), baseURL: URL(string: "http://127.0.0.1/auth/callback"))
            await fulfillment(of: [loaded], timeout: 10)
            // Freeze the one-shot entrance animation for deterministic screenshots.
            _ = try await webView.evaluateJavaScript("document.querySelector('.connection').style.animation = 'none'")
            let overflow = try await webView.evaluateJavaScript("document.documentElement.scrollWidth > window.innerWidth") as? Bool
            XCTAssertEqual(overflow, false, name)
            let visible = try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.card')).borderRadius") as? String
            XCTAssertEqual(visible, size.width < 520 ? "16px" : "20px", name)
            let image = try await webView.takeSnapshot(configuration: nil)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            withExtendedLifetime(delegate) {}
        }
    }
}

private final class PageNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Local page did not load: \(error.localizedDescription)"); loaded.fulfill()
    }
}

import Foundation

/// Presentation only: a browser callback is not proof of a verified account.
/// Never interpolate request parameters, tokens, or provider error descriptions.
enum LocalAuthenticationPage {
    // SwiftPM's generated accessor searches beside the executable. Packaged macOS
    // apps keep resources under Contents/Resources instead; check that first.
    private static let pageBundle = Bundle.main.url(forResource: "NativeAgent_NativeAgent", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? Bundle.module

    enum State: CaseIterable {
        case received, notCompleted, notFound
    }

    static func state(for callback: URL?) -> State {
        guard let callback else { return .notFound }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains(where: { $0.name == "error" }) ? .notCompleted : .received
    }

    static func html(for state: State, nonce: String) throws -> String {
        guard let url = pageBundle.url(forResource: "Authentication", withExtension: "html", subdirectory: "Web") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var html = try String(contentsOf: url, encoding: .utf8)
        let title: String, heading: String, description: String, stepTitle: String, stepCaption: String
        let nextTitle: String, nextCaption: String, help: String
        switch state {
        case .received:
            title = "Continue in the app"
            heading = "Back to your workspace."
            description = "Your browser has handed the sign-in response to NativeAgent. Return to the app to check your connection."
            stepTitle = "Browser response received"
            stepCaption = "This browser step is finished."
            nextTitle = "Account verification"
            nextCaption = "Check the result in NativeAgent."
            help = "NativeAgent still needs to verify the response before your account is connected. The app will show the final result and any next steps in Settings → Accounts. This page does not confirm a successful sign-in."
        case .notCompleted:
            title = "Sign-in not completed"
            heading = "Let’s try that again."
            description = "The provider returned a sign-in error or cancellation. Return to NativeAgent to check the result and start again."
            stepTitle = "Sign-in not completed"
            stepCaption = "The provider did not finish authorization."
            nextTitle = "Try again in the app"
            nextCaption = "Open Settings → Accounts."
            help = "Start a new connection from NativeAgent when you’re ready. For your privacy, provider error details and authorization parameters are not displayed on this page."
        case .notFound:
            title = "Page not found"
            heading = "Your workspace is in the app."
            description = "This local address isn’t a sign-in callback. Return to NativeAgent to continue connecting your account."
            stepTitle = "Page not found"
            stepCaption = "No sign-in response was received here."
            nextTitle = "Continue in the app"
            nextCaption = "Open Settings → Accounts."
            help = "This local page is only used while connecting an account. Follow the sign-in link opened by NativeAgent, or start a new connection from the app."
        }
        let arrow = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M14 5H5v14h9m-3-7h10m-4-4 4 4-4 4\"/></svg>"
        let check = "<svg viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"m3 8 3 3 7-7\"/></svg>"
        let values = ["title": title, "heading": heading, "description": description, "stepTitle": stepTitle,
                      "stepCaption": stepCaption, "nextTitle": nextTitle, "nextCaption": nextCaption, "help": help, "nonce": nonce]
        for (key, value) in values { html = html.replacingOccurrences(of: "{{\(key)}}", with: escape(value)) }
        return html.replacingOccurrences(of: "{{icon}}", with: arrow)
            .replacingOccurrences(of: "{{stepIcon}}", with: state == .received ? check : "!")
    }

    static func response(for state: State) throws -> Data {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let body = try html(for: state, nonce: nonce)
        let status = state == .notFound ? "404 Not Found" : "200 OK"
        let policy = "default-src 'none'; style-src 'nonce-\(nonce)'; script-src 'nonce-\(nonce)'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        let headers = ["HTTP/1.1 \(status)", "Content-Type: text/html; charset=utf-8", "Cache-Control: no-store",
                       "Referrer-Policy: no-referrer", "Content-Security-Policy: \(policy)", "X-Content-Type-Options: nosniff",
                       "Connection: close", "Content-Length: \(body.utf8.count)"]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

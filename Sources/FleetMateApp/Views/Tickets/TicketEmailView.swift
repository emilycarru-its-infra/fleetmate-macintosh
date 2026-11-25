import SwiftUI
import WebKit
import FleetMateCore

/// An Inbox comment drawn as the email TeamDynamix sent for it.
///
/// The page sizes the view to its content so it sits in a list row like an
/// expanded message, and the list keeps scrolling over it. Page scripts are
/// off, and links open in the browser rather than in the row.
struct TicketEmailView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassThroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = PassThroughWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel("Email")
        return view
    }

    func updateNSView(_ view: PassThroughWebView, context: Context) {
        context.coordinator.height = $height
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.initialLoadPending = true
        view.loadHTMLString(Self.restricted(html), baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loadedHTML: String?
        /// Only the page's own load is let through; anything else it tries
        /// to navigate to (refresh, form, frame) is refused.
        var initialLoadPending = false

        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] value, _ in
                guard let self, let number = value as? NSNumber else { return }
                let measured = CGFloat(truncating: number)
                if abs(self.height.wrappedValue - measured) > 1 { self.height.wrappedValue = measured }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if initialLoadPending, action.targetFrame?.isMainFrame == true, action.navigationType == .other {
                initialLoadPending = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
}

extension TicketEmailView {
    /// The page with a policy that allows no scripts, frames, forms or
    /// fetches: only its own inline styles and images over HTTPS or inline.
    static func restricted(_ html: String) -> String {
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; frame-src 'none'">"#
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            var page = html
            page.insert(contentsOf: policy, at: head.upperBound)
            return page
        }
        return policy + html
    }
}

/// Hands scrolling to the list around it: the page is drawn at full height,
/// so it never needs to scroll itself.
final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

extension TicketEmailTemplates {
    /// The comment in a plain page, for Macs without the templates package.
    static func plainCommentPage(_ item: TicketInboxItem) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        body { font: -apple-system-body; font-size: 13px; margin: 8px 0; color: CanvasText;
               background: transparent; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        a { color: -apple-system-control-accent; }
        p:first-child { margin-top: 0; }
        </style></head><body>\(item.body)</body></html>
        """
    }
}

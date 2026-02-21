import SwiftUI
import AppKit

/// Renders HTML (e.g. Azure DevOps descriptions) as styled text using NSAttributedString.
/// Falls back to plain text if HTML parsing fails.
struct HtmlTextView: View {
    let html: String

    var body: some View {
        if let attributed = htmlToAttributedString(html) {
            Text(attributed)
                .font(.body)
        } else {
            // Fallback: strip tags and show plain text
            Text(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.body)
        }
    }

    private func htmlToAttributedString(_ html: String) -> AttributedString? {
        // Wrap in a basic HTML doc with system font styling
        let wrapped = """
        <html><head><style>
        body { font-family: -apple-system, sans-serif; font-size: 13px; color: #333; }
        pre, code { font-family: Menlo, monospace; font-size: 12px; background: #f5f5f5; padding: 2px 4px; border-radius: 3px; }
        img { max-width: 100%; height: auto; }
        </style></head><body>\(html)</body></html>
        """
        guard let data = wrapped.data(using: .utf8) else { return nil }
        guard let nsAttr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else { return nil }
        return try? AttributedString(nsAttr, including: \.appKit)
    }
}

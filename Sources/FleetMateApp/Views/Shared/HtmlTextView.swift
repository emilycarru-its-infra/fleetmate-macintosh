import SwiftUI
import AppKit

private extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

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
        let textColor = NSColor.labelColor.hexString
        let bgColor = NSColor.textBackgroundColor.hexString
        let codeFg = NSColor.secondaryLabelColor.hexString

        let wrapped = """
        <html><head><style>
        body { font-family: -apple-system, sans-serif; font-size: 13px; color: \(textColor); background: \(bgColor); }
        pre, code { font-family: Menlo, monospace; font-size: 12px; color: \(codeFg); }
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

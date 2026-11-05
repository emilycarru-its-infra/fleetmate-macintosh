import AppKit
import FleetMateCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Feed entry body

/// A feed entry's HTML body: its text, with links that click, and its images
/// inline where the HTML put them.
struct FeedBodyView: View {
    @EnvironmentObject private var appState: AppState
    let html: String
    let isReply: Bool

    var body: some View {
        let parsed = FeedBodyCache.body(for: html, webRoot: appState.config.tdxWebRootUrl)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let runs):
                    Text(Self.attributed(runs))
                        .appFont(isReply ? .callout : .body)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let image):
                    FeedBodyImageView(image: image, service: appState.tdxService)
                }
            }
        }
    }

    /// Runs as an AttributedString, links included. `Text` makes `.link`
    /// runs clickable and opens them with the environment's `openURL`.
    static func attributed(_ runs: [TdxTextRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let link = run.link {
                piece.link = link
                piece.underlineStyle = .single
            }
            result += piece
        }
        return result
    }
}

/// Parsing a body runs a data detector over its text, so the result is kept
/// per HTML string rather than redone on every SwiftUI update.
@MainActor
private enum FeedBodyCache {
    private final class Box {
        let value: TdxFeedBody
        init(_ value: TdxFeedBody) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    static func body(for html: String, webRoot: URL?) -> TdxFeedBody {
        let key = "\(webRoot?.absoluteString ?? "")\u{1}\(html)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let parsed = TdxFeedBody.parse(html, webRoot: webRoot)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

// MARK: - Inline image

/// One image from a feed body. Fits the card's width without upscaling,
/// caps its height, and behaves like an image anywhere else on the Mac: click
/// or Space opens Quick Look, it drags out to the Finder or another app,
/// ⌘C copies it, and the context menu copies, saves or opens it.
struct FeedBodyImageView: View {
    let image: TdxBodyImage
    let service: TdxService

    private enum Phase {
        case loading
        case loaded(NSImage, Data)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var previewURL: URL?
    @FocusState private var focused: Bool

    private static let maxHeight: CGFloat = 360

    var body: some View {
        Group {
            switch phase {
            case .loading:
                placeholder
            case .loaded(let nsImage, let data):
                loaded(nsImage, data: data)
            case .failed:
                failure
            }
        }
        .task(id: image.cacheKey) { await load() }
        .quickLookPreview($previewURL)
    }

    // MARK: States

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08))
            .frame(width: 220, height: 124)
            .overlay(ProgressView().controlSize(.small))
            .accessibilityLabel(image.alt ?? "Image")
            .accessibilityValue("Loading")
    }

    private var failure: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("Image couldn’t load")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.link)
                .appFont(.caption)
            if let url = image.remoteURL {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .appFont(.caption)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(image.alt ?? "Image") couldn’t load")
    }

    private func loaded(_ nsImage: NSImage, data: Data) -> some View {
        let natural = nsImage.size
        // Never upscale: a small image stays its own size.
        let height = min(Self.maxHeight, max(natural.height, 1))
        return Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: max(natural.width, 1), maxHeight: height, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.2),
                            lineWidth: focused ? 2 : 1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onTapGesture { focused = true; openPreview(data) }
            .onKeyPress(.space) { openPreview(data); return .handled }
            .onCopyCommand { [NSItemProvider(object: nsImage)] }
            .onDrag { dragProvider(nsImage, data: data) }
            .contextMenu { menu(nsImage, data: data) }
            .help(image.alt ?? "Click to view full size")
            .accessibilityElement()
            .accessibilityLabel(image.alt ?? "Image")
            .accessibilityAddTraits([.isImage, .isButton])
            .accessibilityHint("Opens the image in Quick Look")
            .accessibilityAction { openPreview(data) }
    }

    @ViewBuilder
    private func menu(_ nsImage: NSImage, data: Data) -> some View {
        Button("Open Image") { openPreview(data) }
        Divider()
        Button("Copy Image") { copy(nsImage, data: data) }
        if let url = image.remoteURL {
            Button("Copy Image Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Save Image…") { save(data) }
        if let url = image.remoteURL {
            Divider()
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Loading

    private func load() async {
        phase = .loading
        var loaded = await fetch(image.source)
        if loaded == nil, let fallback = image.fallback {
            loaded = await fetch(fallback)
        }
        if let loaded {
            phase = .loaded(loaded.0, loaded.1)
        } else {
            phase = .failed
        }
    }

    private func fetch(_ source: TdxBodyImage.Source) async -> (NSImage, Data)? {
        let data: Data
        switch source {
        case .inline(let bytes, _):
            data = bytes
        case .remote(let url):
            guard let fetched = try? await service.fetchBodyImage(url) else { return nil }
            data = fetched
        }
        guard let nsImage = NSImage(data: data), nsImage.isValid else { return nil }
        return (nsImage, data)
    }

    // MARK: Actions

    private func openPreview(_ data: Data) {
        previewURL = stage(data)
    }

    private func copy(_ nsImage: NSImage, data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        if let fileURL = stage(data) {
            pasteboard.addTypes([.fileURL], owner: nil)
            pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = image.suggestedFileName
        let ext = (image.suggestedFileName as NSString).pathExtension
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drag as a file (for the Finder, Mail, Messages) and as an image (for
    /// anything that takes pasted pictures).
    private func dragProvider(_ nsImage: NSImage, data: Data) -> NSItemProvider {
        let provider: NSItemProvider
        if let fileURL = stage(data), let fileProvider = NSItemProvider(contentsOf: fileURL) {
            provider = fileProvider
        } else {
            provider = NSItemProvider(object: nsImage)
        }
        provider.suggestedName = (image.suggestedFileName as NSString).deletingPathExtension
        return provider
    }

    /// Write the bytes to a temporary file under the image's own name, which
    /// Quick Look, drags and the pasteboard's file URL all need.
    private func stage(_ data: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetMate-FeedImages", isDirectory: true)
            .appendingPathComponent(String(UInt(bitPattern: image.cacheKey.hashValue), radix: 16), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(image.suggestedFileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }
}

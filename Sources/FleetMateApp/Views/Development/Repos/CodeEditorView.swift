import SwiftUI
import AppKit
import FleetMateCore

/// The Repos editor: an AppKit text view with a line-number gutter, undo,
/// the standard find bar and light syntax colouring (`CodeSyntaxPainter`).
/// The text storage is owned here alone, so a richer highlighter can replace
/// the painter without touching the workspace.
struct CodeEditorView: NSViewRepresentable {
    let document: RepoEditorDocument
    /// Bumped by the model to scroll to `document.revealLine` again.
    let revealToken: Int
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> CodeEditorContainer {
        let container = CodeEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        load(document, into: textView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CodeEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        guard let textView = coordinator.textView else { return }
        if coordinator.documentId != document.id {
            load(document, into: textView, coordinator: coordinator)
        } else if coordinator.revealToken != revealToken {
            coordinator.revealToken = revealToken
            reveal(document, in: textView)
        }
    }

    private func load(_ document: RepoEditorDocument, into textView: CodeTextView, coordinator: Coordinator) {
        coordinator.documentId = document.id
        coordinator.document = document
        coordinator.language = CodeLanguage.detect(path: document.path, source: document.text)
        coordinator.revealToken = revealToken
        textView.isEditable = !document.isReadOnly
        textView.string = document.text
        CodeSyntaxPainter.paint(textView, language: coordinator.language)
        textView.undoManager?.removeAllActions()
        textView.lineNumbers?.invalidateLines()
        reveal(document, in: textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }

    private func reveal(_ document: RepoEditorDocument, in textView: NSTextView) {
        guard let line = document.revealLine else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            return
        }
        document.revealLine = nil
        let range = CodeTextView.range(ofLine: line, in: textView.string as NSString)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: () -> Void
        weak var textView: CodeTextView?
        weak var document: RepoEditorDocument?
        var documentId: UUID?
        var revealToken = 0
        var language: CodeLanguage = .plainText

        init(onChange: @escaping () -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let textView, let document else { return }
            document.text = textView.string
            CodeSyntaxPainter.paint(textView, language: language)
            onChange()
        }
    }
}

/// Paints `CodeHighlighter` tokens onto a text view's storage. Colours avoid
/// red, as everywhere in FleetMate.
enum CodeSyntaxPainter {
    static func paint(_ textView: NSTextView, language: CodeLanguage) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        storage.addAttribute(.font, value: CodeTextView.editorFont, range: whole)
        for token in CodeHighlighter.tokens(in: textView.string, language: language) where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
        }
        storage.endEditing()
    }

    private static func color(_ kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .string: NSColor(calibratedRed: 0.76, green: 0.56, blue: 0.28, alpha: 1)
        case .keyword: .systemPurple
        case .number: .systemBlue
        }
    }
}

/// TextKit 1 text view configured for code: no smart substitutions, no
/// wrapping, find bar, undo, and a line-number ruler.
final class CodeTextView: NSTextView {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    weak var lineNumbers: LineNumberGutter?

    static func make() -> CodeTextView {
        // Built by hand on TextKit 1: the ruler reads line fragments from
        // the layout manager, which a TextKit 2 view would swap out.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = editorFont
        textView.typingAttributes = [.font: editorFont, .foregroundColor: NSColor.textColor]
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        return textView
    }

    /// ⌘F, ⌘G and ⇧⌘G go to this view's find bar while it has focus. Without
    /// this the app's ⌘F would move focus to the toolbar's tab search, which
    /// filters the file tree instead of searching the open file.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let action: NSTextFinder.Action?
        switch (key, shift) {
        case ("f", false): action = .showFindInterface
        case ("g", false): action = .nextMatch
        case ("g", true): action = .previousMatch
        case ("e", false): action = .setSearchString
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
        return true
    }

    /// Tab inserts four spaces where the file already indents with spaces.
    override func insertTab(_ sender: Any?) {
        let usesTabs = string.contains("\n\t")
        if usesTabs { super.insertTab(sender) } else { insertText("    ", replacementRange: selectedRange()) }
    }

    /// Return keeps the current line's indentation.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location, length: max(0, caret - lineRange.location)))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }

    /// The character range of 1-based `line`, without its line break.
    static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let next = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { break }
            location = next.location + 1
            current += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var length = lineRange.length
        if length > 0, text.character(at: lineRange.location + length - 1) == 10 { length -= 1 }
        return NSRange(location: lineRange.location, length: length)
    }
}

/// A code text view in a scroll view with a line-number gutter beside it.
/// The gutter is a sibling view rather than an `NSRulerView`, whose clip-view
/// tiling lets text slide under the numbers on recent macOS releases.
final class CodeEditorContainer: NSView {
    let textView = CodeTextView.make()
    let scrollView = NSScrollView()
    let gutter: LineNumberGutter

    override init(frame: NSRect) {
        gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
        super.init(frame: frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView.lineNumbers = gutter

        for view in [gutter, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = gutter.widthAnchor.constraint(equalToConstant: 40)
        gutter.widthConstraint = width
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Line numbers for a `CodeTextView`. Line starts are cached per edit, so
/// drawing only looks up the lines on screen.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    var widthConstraint: NSLayoutConstraint?
    private var lineStarts: [Int] = [0]
    private var stale = true

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc private func textChanged() { invalidateLines() }
    @objc func redraw() { needsDisplay = true }

    func invalidateLines() {
        stale = true
        rebuildIfNeeded()
        needsDisplay = true
    }

    private func rebuildIfNeeded() {
        guard stale, let text = textView?.string as NSString? else { return }
        stale = false
        var starts = [0]
        var location = 0
        while location < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            location = found.location + 1
            starts.append(location)
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let width = CGFloat(digits) * 7 + 16
        if let widthConstraint, abs(widthConstraint.constant - width) > 0.5 { widthConstraint.constant = width }
    }

    /// Index of the line containing `location`.
    private func lineIndex(for location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView, let scrollView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        rebuildIfNeeded()

        let clip = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let visible = NSRect(x: 0, y: clip.minY - inset, width: max(clip.width, 1), height: clip.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        func draw(_ number: Int, lineTop: CGFloat, lineHeight: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = lineTop + inset - clip.minY + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 7, y: y), withAttributes: attributes)
        }

        if text.length == 0 {
            draw(1, lineTop: 0, lineHeight: layout.defaultLineHeight(for: CodeTextView.editorFont))
            return
        }
        var index = lineIndex(for: characters.location)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(characters) { break }
            if start >= text.length {
                // The empty last line after a final newline.
                let extra = layout.extraLineFragmentRect
                if extra.height > 0 { draw(index + 1, lineTop: extra.minY, lineHeight: extra.height) }
                break
            }
            let glyph = layout.glyphIndexForCharacter(at: start)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(index + 1, lineTop: fragment.minY, lineHeight: fragment.height)
            index += 1
        }
    }
}

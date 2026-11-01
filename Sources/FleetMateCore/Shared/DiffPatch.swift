import Foundation

// Ported from MunkiStudio (rodchristiansen/apps/munkistudio,
// Sources/Core/Models/DiffPatch.swift) — same model and parser, minus the
// git-apply patch reconstruction FleetMate doesn't need, plus DiffBuilder:
// a string-to-string front-end for sources (Azure DevOps) that hand us file
// contents instead of unified-diff text.

/// Parsed unified-diff payload. One ``DiffFile`` per `diff --git …` header in
/// the input; one ``DiffHunk`` per `@@ … @@` section underneath; ``DiffLine``
/// describes each line of the hunk.
///
/// The parser is forgiving: input it doesn't recognise as a header, hunk
/// header, or diff line is ignored. Empty input parses to an empty patch.
public struct DiffPatch: Sendable, Hashable {
    public var files: [DiffFile]
    public init(files: [DiffFile] = []) { self.files = files }
    public var isEmpty: Bool { files.allSatisfy(\.hunks.isEmpty) && files.isEmpty }
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    /// Lines from `diff --git` up to (not including) the first hunk.
    public var headerLines: [String]
    /// Path with the `a/` prefix from the file header.
    public var oldPath: String
    /// Path with the `b/` prefix from the file header.
    public var newPath: String
    public var hunks: [DiffHunk]

    public var id: String { oldPath + "→" + newPath }

    /// Convenience name for display — prefers the new path (current state),
    /// falls back to the old path for deletions.
    public var displayPath: String {
        newPath == "/dev/null" ? cleanPath(oldPath) : cleanPath(newPath)
    }

    private func cleanPath(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    public init(
        headerLines: [String],
        oldPath: String,
        newPath: String,
        hunks: [DiffHunk] = []
    ) {
        self.headerLines = headerLines
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }

    public var insertions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }
    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The raw `@@ -old,olen +new,nlen @@ trailing context` header.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(
        id: UUID = UUID(),
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine] = []
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var insertions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case context, addition, deletion
        /// `\ No newline at end of file`.
        case noNewline
    }

    public var id: UUID
    public var kind: Kind
    /// 1-based line number in the pre-image side, or `nil` for additions.
    public var oldLine: Int?
    /// 1-based line number in the post-image side, or `nil` for deletions.
    public var newLine: Int?
    /// Raw line content WITHOUT the leading `+ -` marker.
    public var content: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        oldLine: Int? = nil,
        newLine: Int? = nil,
        content: String
    ) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.content = content
    }
}

/// Parse `git diff`-style unified output. Tolerant of unknown sections —
/// anything outside a `diff --git` block is dropped on the floor.
public enum DiffParser {
    public static func parse(_ text: String) -> DiffPatch {
        var files: [DiffFile] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("diff --git ") else { index += 1; continue }
            var header: [String] = [line]
            var oldPath = ""
            var newPath = ""
            index += 1
            // Header lines until the first hunk (or next file).
            while index < lines.count {
                let candidate = lines[index]
                if candidate.hasPrefix("@@ ") || candidate.hasPrefix("diff --git ") { break }
                header.append(candidate)
                if candidate.hasPrefix("--- ") {
                    oldPath = String(candidate.dropFirst(4))
                } else if candidate.hasPrefix("+++ ") {
                    newPath = String(candidate.dropFirst(4))
                }
                index += 1
            }
            if oldPath.isEmpty {
                // Fall back to the paths embedded in `diff --git a/x b/y`.
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    oldPath = String(parts[2])
                    newPath = String(parts[3])
                }
            }
            var file = DiffFile(headerLines: header, oldPath: oldPath, newPath: newPath)
            while index < lines.count, lines[index].hasPrefix("@@ ") {
                let (hunk, consumed) = parseHunk(lines: lines, from: index)
                file.hunks.append(hunk)
                index += consumed
            }
            files.append(file)
        }
        return DiffPatch(files: files)
    }

    /// Parse hunks that arrive without any `diff --git` header — the shape of
    /// GitHub's per-file `patch` strings. Returns them attached to a synthetic
    /// file entry for `fileName`.
    public static func parseBareHunks(_ patch: String, fileName: String) -> DiffFile {
        let synthetic = "diff --git a/\(fileName) b/\(fileName)\n--- a/\(fileName)\n+++ b/\(fileName)\n" + patch
        let parsed = parse(synthetic)
        return parsed.files.first ?? DiffFile(headerLines: [], oldPath: fileName, newPath: fileName)
    }

    private static func parseHunk(lines: [String], from start: Int) -> (DiffHunk, Int) {
        let header = lines[start]
        let (oldStart, oldCount, newStart, newCount) = parseHunkRanges(header)
        var hunk = DiffHunk(
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount
        )
        var oldCursor = oldStart
        var newCursor = newStart
        var consumed = 1
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@ ") || line.hasPrefix("diff --git ") { break }
            if line.isEmpty {
                // Empty lines inside a hunk are context lines; a truly empty
                // input line at end-of-file terminates the patch.
                if index == lines.count - 1 { break }
                hunk.lines.append(DiffLine(
                    kind: .context,
                    oldLine: oldCursor,
                    newLine: newCursor,
                    content: ""
                ))
                oldCursor += 1
                newCursor += 1
                index += 1
                consumed += 1
                continue
            }
            let first = line.first!
            let body = String(line.dropFirst())
            switch first {
            case "+":
                hunk.lines.append(DiffLine(kind: .addition, oldLine: nil, newLine: newCursor, content: body))
                newCursor += 1
            case "-":
                hunk.lines.append(DiffLine(kind: .deletion, oldLine: oldCursor, newLine: nil, content: body))
                oldCursor += 1
            case " ":
                hunk.lines.append(DiffLine(kind: .context, oldLine: oldCursor, newLine: newCursor, content: body))
                oldCursor += 1
                newCursor += 1
            case "\\":
                hunk.lines.append(DiffLine(kind: .noNewline, oldLine: nil, newLine: nil, content: body))
            default:
                return (hunk, consumed)
            }
            index += 1
            consumed += 1
        }
        return (hunk, consumed)
    }

    /// Pull `(oldStart, oldCount, newStart, newCount)` out of a hunk header.
    /// Missing counts default to 1 (git's own convention).
    private static func parseHunkRanges(_ header: String) -> (Int, Int, Int, Int) {
        let scanner = Scanner(string: header)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanString("@@")
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("-")
        let oldStart = scanner.scanInt() ?? 0
        var oldCount = 1
        if scanner.scanString(",") != nil { oldCount = scanner.scanInt() ?? 1 }
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("+")
        let newStart = scanner.scanInt() ?? 0
        var newCount = 1
        if scanner.scanString(",") != nil { newCount = scanner.scanInt() ?? 1 }
        return (oldStart, oldCount, newStart, newCount)
    }
}

// MARK: - String-to-string diffing

/// Build a ``DiffFile`` from two file contents — for sources like Azure
/// DevOps that serve before/after blobs rather than unified-diff text.
/// Uses `CollectionDifference` (Myers) and groups changes into hunks with
/// three lines of context, mirroring git's default.
public enum DiffBuilder {
    public static func build(fileName: String, old: String, new: String, context: Int = 3) -> DiffFile {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let difference = newLines.difference(from: oldLines)
        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        // Walk both sides in lockstep, emitting a flat annotated line list.
        var annotated: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedAt.contains(oldIndex) {
                annotated.append(DiffLine(kind: .deletion, oldLine: oldIndex + 1, content: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedAt.contains(newIndex) {
                annotated.append(DiffLine(kind: .addition, newLine: newIndex + 1, content: newLines[newIndex]))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                annotated.append(DiffLine(kind: .context, oldLine: oldIndex + 1, newLine: newIndex + 1, content: oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        // Group changed regions into hunks with `context` lines around them.
        var hunks: [DiffHunk] = []
        var index = 0
        while index < annotated.count {
            guard annotated[index].kind != .context else { index += 1; continue }
            let start = max(0, index - context)
            var end = index
            var sinceChange = 0
            var cursor = index
            while cursor < annotated.count {
                if annotated[cursor].kind == .context {
                    sinceChange += 1
                    // Two hunks whose context would touch merge into one.
                    if sinceChange > context * 2 { break }
                } else {
                    sinceChange = 0
                    end = cursor
                }
                cursor += 1
            }
            let sliceEnd = min(annotated.count, end + context + 1)
            let slice = Array(annotated[start..<sliceEnd])

            let oldStart = slice.compactMap(\.oldLine).first ?? 1
            let newStart = slice.compactMap(\.newLine).first ?? 1
            let oldCount = slice.filter { $0.kind != .addition }.count
            let newCount = slice.filter { $0.kind != .deletion }.count
            let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            hunks.append(DiffHunk(
                header: header,
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                lines: slice
            ))
            index = sliceEnd
        }

        return DiffFile(
            headerLines: ["diff --git a/\(fileName) b/\(fileName)"],
            oldPath: "a/\(fileName)",
            newPath: "b/\(fileName)",
            hunks: hunks
        )
    }
}

/// How a diff is drawn: old and new side by side, or one column of
/// removed and added lines.
public enum DiffLayout: String, Sendable, CaseIterable, Identifiable {
    case split
    case inline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .split: return "Side by Side"
        case .inline: return "Inline"
        }
    }

    public static let storageKey = "diffLayout"
}

/// One row of a side-by-side diff: the old line on the left, the new line
/// on the right. A removed line with no matching addition leaves the right
/// empty, and the reverse.
public struct DiffSplitRow: Sendable, Hashable, Identifiable {
    public var left: DiffLine?
    public var right: DiffLine?

    public var id: String {
        "\(left?.id.uuidString ?? "-")|\(right?.id.uuidString ?? "-")"
    }

    public init(left: DiffLine?, right: DiffLine?) {
        self.left = left
        self.right = right
    }
}

extension DiffHunk {
    /// The hunk as side-by-side rows. Context lines show on both sides. Each
    /// run of removed lines is paired, line by line, with the run of added
    /// lines that follows it, so a changed line sits opposite its new
    /// version. A "no newline" marker stays on the side it belongs to.
    public var splitRows: [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .context:
                rows.append(DiffSplitRow(left: line, right: line))
                i += 1
            case .noNewline:
                // Follows the line it describes; put it on that line's side.
                let previous = i > 0 ? lines[i - 1].kind : .context
                switch previous {
                case .deletion: rows.append(DiffSplitRow(left: line, right: nil))
                case .addition: rows.append(DiffSplitRow(left: nil, right: line))
                default: rows.append(DiffSplitRow(left: line, right: line))
                }
                i += 1
            case .deletion, .addition:
                var removed: [DiffLine] = []
                while i < lines.count, lines[i].kind == .deletion { removed.append(lines[i]); i += 1 }
                var removedMarker: DiffLine?
                if i < lines.count, lines[i].kind == .noNewline, !removed.isEmpty {
                    removedMarker = lines[i]; i += 1
                }
                var added: [DiffLine] = []
                while i < lines.count, lines[i].kind == .addition { added.append(lines[i]); i += 1 }
                var leftSide = removed
                if let removedMarker { leftSide.append(removedMarker) }
                for index in 0..<max(leftSide.count, added.count) {
                    rows.append(DiffSplitRow(
                        left: index < leftSide.count ? leftSide[index] : nil,
                        right: index < added.count ? added[index] : nil
                    ))
                }
            }
        }
        return rows
    }
}

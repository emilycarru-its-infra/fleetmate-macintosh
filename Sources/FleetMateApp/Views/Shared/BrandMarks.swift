import SwiftUI

/// Vector brand marks for the systems FleetMate talks to.
///
/// SF Symbols has no GitHub or Azure DevOps glyph, and the generic stand-ins
/// read as nothing in particular — `infinity` is a maths symbol, not the Azure
/// DevOps logo, and `chevron.left.forwardslash.chevron.right` is "code", not
/// GitHub. These draw the real marks instead, so a row's provider is
/// recognisable at a glance.
///
/// Paths are the standard single-colour brand marks on a 24×24 viewBox. They
/// render as a `Shape`, so they inherit `foregroundStyle` and scale cleanly at
/// any size — no bundled raster assets, and nothing to declare in Package.swift.
enum BrandMark {
    static let gitHub = BrandShape(
        pathData: """
        M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 \
        0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 \
        17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 \
        1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 \
        0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 \
        1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 \
        3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 \
        5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 \
        22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12z
        """,
        viewBox: 24
    )

    static let azureDevOps = BrandShape(
        pathData: """
        M0 8.877L2.247 5.91l8.405-3.416V.022l7.37 5.393L2.966 8.338v8.225L0 15.707V8.877zm24-4.44v14.651l-5.753 \
        4.89-9.303-3.05v3.05l-5.978-7.408 15.057 1.812V5.415L24 4.437z
        """,
        viewBox: 24
    )
}

/// A `Shape` built from SVG path data, scaled to fit its rect and centred.
struct BrandShape: Shape, Equatable {
    let pathData: String
    /// Width/height of the source viewBox (these marks are square).
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let parsed = SVGPathParser.path(from: pathData)
        let side = min(rect.width, rect.height)
        guard side > 0, viewBox > 0 else { return Path() }

        let scale = side / viewBox
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return parsed.applying(transform)
    }
}

/// A view wrapper so brand marks can be dropped in where an `Image` would go.
struct BrandIcon: View {
    let mark: BrandShape
    var size: CGFloat = 11

    var body: some View {
        mark
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - SVG path parsing

/// Minimal SVG path parser — enough for single-colour brand marks.
///
/// Supports `M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `S/s` and `Z/z`. Arcs are
/// deliberately unsupported: no mark used here needs one, and the endpoint-to-
/// centre conversion is a lot of surface area for no benefit. Pick a path
/// variant built from cubics — the standard single-colour marks all are.
enum SVGPathParser {
    static func path(from data: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection point for smooth-curve (`S`) continuation.
        var lastControl: CGPoint?

        var command: Character?
        var scanner = NumberScanner(data)

        while true {
            scanner.skipSeparators()
            if let c = scanner.peekCommand() {
                command = c
                scanner.advance()
            } else if scanner.isAtEnd {
                break
            }
            guard let cmd = command else { break }

            let relative = cmd.isLowercase
            func resolve(_ p: CGPoint) -> CGPoint {
                relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            }

            switch Character(cmd.lowercased()) {
            case "m":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = resolve(CGPoint(x: x, y: y))
                subpathStart = current
                path.move(to: current)
                lastControl = nil
                // Subsequent coordinate pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"

            case "l":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = resolve(CGPoint(x: x, y: y))
                path.addLine(to: current)
                lastControl = nil

            case "h":
                guard let x = scanner.nextNumber() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil

            case "v":
                guard let y = scanner.nextNumber() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil

            case "c":
                guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(),  let y = scanner.nextNumber() else { return path }
                let c1 = resolve(CGPoint(x: x1, y: y1))
                let c2 = resolve(CGPoint(x: x2, y: y2))
                let end = resolve(CGPoint(x: x, y: y))
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end

            case "s":
                guard let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                // First control is the reflection of the previous one.
                let c1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = resolve(CGPoint(x: x2, y: y2))
                let end = resolve(CGPoint(x: x, y: y))
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end

            case "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil

            default:
                return path
            }

            if scanner.isAtEnd { break }
        }

        return path
    }
}

/// Cursor over SVG path data, yielding commands and numbers.
private struct NumberScanner {
    private let chars: [Character]
    private var index: Int = 0

    init(_ string: String) {
        // Newlines exist only because the literals are wrapped for readability.
        chars = Array(string.replacingOccurrences(of: "\n", with: " "))
    }

    var isAtEnd: Bool { index >= chars.count }

    mutating func advance() { index += 1 }

    mutating func skipSeparators() {
        while index < chars.count, chars[index] == " " || chars[index] == "," {
            index += 1
        }
    }

    func peekCommand() -> Character? {
        guard index < chars.count else { return nil }
        let c = chars[index]
        return c.isLetter ? c : nil
    }

    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        var s = ""
        if index < chars.count, chars[index] == "-" || chars[index] == "+" {
            s.append(chars[index]); index += 1
        }
        var seenDot = false
        while index < chars.count {
            let c = chars[index]
            if c.isNumber {
                s.append(c); index += 1
            } else if c == "." && !seenDot {
                seenDot = true
                s.append(c); index += 1
            } else if c == "." && seenDot {
                // "1.5.5" is two numbers in SVG shorthand — stop before the second.
                break
            } else {
                break
            }
        }
        return s.isEmpty ? nil : CGFloat(Double(s) ?? 0)
    }
}

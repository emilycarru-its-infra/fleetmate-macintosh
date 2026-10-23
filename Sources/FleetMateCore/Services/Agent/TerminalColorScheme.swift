import Foundation

/// Whether a terminal is drawn light or dark, and what a program running in
/// it is told about that.
///
/// Programs pick their colours from the terminal's background: Claude Code's
/// `auto` theme, tmux and Vim ask with an OSC 11 query, read `COLORFGBG` at
/// start, or subscribe to colour-scheme reports (DEC private mode 2031) to
/// hear when it changes.
public enum TerminalColorScheme: Equatable, Sendable {
    case light
    case dark

    /// `COLORFGBG` for a session started in this scheme: the foreground and
    /// background as ANSI colour numbers, as rxvt sets it. Readers take the
    /// last number as the background and treat 0–6 and 8 as dark.
    public var colorFgBg: String {
        switch self {
        case .light: "0;15"
        case .dark: "15;0"
        }
    }

    /// The colour-scheme report, `CSI ? 997 ; 1 n` for dark and `; 2 n` for
    /// light, sent in answer to `CSI ? 996 n` and, while mode 2031 is on,
    /// whenever the scheme changes.
    public var report: String {
        switch self {
        case .dark: "\u{1b}[?997;1n"
        case .light: "\u{1b}[?997;2n"
        }
    }

    /// The 16 ANSI colours, as 8-bit RGB, picked to read on this scheme's
    /// background. The extended colours (16–255) stay the standard xterm
    /// cube and grey ramp: programs choose those indices expecting xterm's
    /// values, so deriving them from the background turns a light grey into
    /// black on a white terminal.
    public var ansiPalette: [(red: UInt8, green: UInt8, blue: UInt8)] {
        switch self {
        case .dark:
            [
                (0, 0, 0), (214, 76, 62), (64, 190, 64), (196, 186, 60),
                (92, 128, 255), (205, 90, 205), (64, 188, 204), (204, 204, 204),
                (128, 128, 128), (255, 102, 92), (96, 226, 96), (240, 230, 90),
                (130, 160, 255), (240, 120, 240), (100, 230, 240), (240, 240, 240),
            ]
        case .light:
            [
                (0, 0, 0), (186, 40, 30), (24, 128, 24), (150, 110, 0),
                (36, 64, 210), (160, 40, 160), (0, 120, 140), (140, 140, 140),
                (96, 96, 96), (214, 56, 44), (36, 150, 36), (176, 132, 0),
                (60, 92, 240), (190, 60, 190), (0, 142, 164), (184, 184, 184),
            ]
        }
    }
}

/// Picks out of a terminal's output the colour-scheme requests SwiftTerm does
/// not answer itself: turning mode 2031 on or off (`CSI ? 2031 h` / `l`,
/// possibly among other modes in one sequence) and the one-off query
/// `CSI ? 996 n`. A sequence split across two reads is still found.
public struct TerminalColorSchemeRequests: Sendable {
    public enum Request: Equatable, Sendable {
        case subscribe
        case unsubscribe
        case query
    }

    /// The start of a sequence that the last read cut off.
    private var carry: [UInt8] = []
    /// Longest sequence kept across reads; anything longer is not one of ours.
    private static let limit = 64

    public init() {}

    public mutating func scan<S: Sequence>(_ bytes: S) -> [Request] where S.Element == UInt8 {
        var data = carry
        data.append(contentsOf: bytes)
        carry.removeAll(keepingCapacity: true)
        var requests: [Request] = []
        var i = 0
        while i < data.count {
            guard data[i] == 0x1b else { i += 1; continue }
            // ESC [ ? <params> <final>
            var j = i + 1
            guard j < data.count else { keepCarry(data, from: i); break }
            guard data[j] == UInt8(ascii: "[") else { i += 1; continue }
            j += 1
            guard j < data.count else { keepCarry(data, from: i); break }
            guard data[j] == UInt8(ascii: "?") else { i += 1; continue }
            j += 1
            let start = j
            while j < data.count, data[j] == UInt8(ascii: ";") || (0x30...0x39).contains(data[j]) { j += 1 }
            guard j < data.count else {
                if j - i <= Self.limit { keepCarry(data, from: i) }
                break
            }
            let params = String(decoding: data[start..<j], as: UTF8.self).split(separator: ";")
            switch data[j] {
            case UInt8(ascii: "h") where params.contains("2031"): requests.append(.subscribe)
            case UInt8(ascii: "l") where params.contains("2031"): requests.append(.unsubscribe)
            case UInt8(ascii: "n") where params == ["996"]: requests.append(.query)
            default: break
            }
            i = j + 1
        }
        return requests
    }

    private mutating func keepCarry(_ data: [UInt8], from index: Int) {
        carry = Array(data[index...])
    }
}

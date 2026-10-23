import XCTest
@testable import FleetMateCore

final class TerminalColorSchemeTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testFindsSubscribeQueryAndUnsubscribe() {
        var scanner = TerminalColorSchemeRequests()
        let found = scanner.scan(bytes("text\u{1b}[?2031h more \u{1b}[?996n\u{1b}[?2031l"))
        XCTAssertEqual(found, [.subscribe, .query, .unsubscribe])
    }

    func testFindsModeAmongOthers() {
        var scanner = TerminalColorSchemeRequests()
        XCTAssertEqual(scanner.scan(bytes("\u{1b}[?2004;2031h")), [.subscribe])
        XCTAssertEqual(scanner.scan(bytes("\u{1b}[?2004h\u{1b}[?1049l\u{1b}[6n")), [])
    }

    func testFindsSequenceSplitAcrossReads() {
        var scanner = TerminalColorSchemeRequests()
        XCTAssertEqual(scanner.scan(bytes("abc\u{1b}[?99")), [])
        XCTAssertEqual(scanner.scan(bytes("6n")), [.query])
        XCTAssertEqual(scanner.scan(bytes("\u{1b}")), [])
        XCTAssertEqual(scanner.scan(bytes("[?2031h")), [.subscribe])
    }

    func testIgnoresOtherDeviceStatusReports() {
        var scanner = TerminalColorSchemeRequests()
        XCTAssertEqual(scanner.scan(bytes("\u{1b}[?6n\u{1b}[?9961n\u{1b}[996n")), [])
    }

    func testReportsAndColorFgBg() {
        XCTAssertEqual(TerminalColorScheme.dark.report, "\u{1b}[?997;1n")
        XCTAssertEqual(TerminalColorScheme.light.report, "\u{1b}[?997;2n")
        // Readers treat a last value of 0-6 or 8 as a dark background.
        XCTAssertEqual(TerminalColorScheme.light.colorFgBg.split(separator: ";").last, "15")
        XCTAssertEqual(TerminalColorScheme.dark.colorFgBg.split(separator: ";").last, "0")
    }

    func testPalettesHaveSixteenColoursThatReadOnTheirBackground() {
        func luminance(_ c: (red: UInt8, green: UInt8, blue: UInt8)) -> Double {
            func channel(_ v: UInt8) -> Double {
                let s = Double(v) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        // The coloured entries (red to cyan, normal and bright) must read as text.
        let coloured = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
        let backgrounds: [(TerminalColorScheme, Double)] = [(.light, 1.0), (.dark, luminance((30, 30, 30)))]
        for (scheme, background) in backgrounds {
            XCTAssertEqual(scheme.ansiPalette.count, 16)
            for index in coloured {
                XCTAssertGreaterThanOrEqual(contrast(luminance(scheme.ansiPalette[index]), background), 3,
                                            "\(scheme) colour \(index)")
            }
        }
    }
}

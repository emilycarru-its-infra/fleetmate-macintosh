import Foundation

/// How a tab's Graphs strip splits its cards into rows. Pure, so the Mac
/// layout and the tests agree; the Windows app follows the same rule.
///
/// Cards keep their order. A card spanning `fullRow` or more takes a row of
/// its own. Every other run of cards goes into the fewest rows that hold it
/// (`unitsPerRow` units each), split so the rows carry as even a number of
/// units as possible — two rows of three rather than five and a stretched
/// one.
public enum WidgetRowPacking {
    public static func rows(spans: [Int], unitsPerRow: Int, fullRow: Int) -> [[Int]] {
        let cap = max(1, unitsPerRow)
        var result: [[Int]] = []
        var run: [Int] = []
        func flush() {
            result += balanced(run, spans: run.map { min(max(1, spans[$0]), cap) }, cap: cap)
            run = []
        }
        for (i, span) in spans.enumerated() {
            if span >= fullRow {
                flush()
                result.append([i])
            } else {
                run.append(i)
            }
        }
        flush()
        return result
    }

    /// Fewest rows first (greedy is optimal for that), then the contiguous
    /// split with the smallest spread of row sizes.
    private static func balanced(_ items: [Int], spans: [Int], cap: Int) -> [[Int]] {
        let n = items.count
        guard n > 0 else { return [] }
        var rowCount = 1
        var used = 0
        for s in spans {
            if used + s > cap, used > 0 { rowCount += 1; used = 0 }
            used += s
        }
        guard rowCount > 1 else { return [items] }
        guard rowCount < n else { return items.map { [$0] } }

        let mean = Double(spans.reduce(0, +)) / Double(rowCount)
        var prefix = [0]
        for s in spans { prefix.append(prefix.last! + s) }
        // cost[k][i]: best cost of the first i cards in k rows.
        let inf = Double.infinity
        var cost = Array(repeating: Array(repeating: inf, count: n + 1), count: rowCount + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: rowCount + 1)
        cost[0][0] = 0
        for k in 1...rowCount {
            // k rows need at least k cards.
            for i in k...n {
                for j in (k - 1)..<i {
                    let units = prefix[i] - prefix[j]
                    guard units <= cap, cost[k - 1][j] < inf else { continue }
                    let c = cost[k - 1][j] + pow(Double(units) - mean, 2)
                    if c < cost[k][i] {
                        cost[k][i] = c
                        cut[k][i] = j
                    }
                }
            }
        }
        guard cost[rowCount][n] < inf else { return [items] }
        var rows: [[Int]] = []
        var end = n
        for k in stride(from: rowCount, to: 0, by: -1) {
            let start = cut[k][end]
            rows.insert(Array(items[start..<end]), at: 0)
            end = start
        }
        return rows
    }
}

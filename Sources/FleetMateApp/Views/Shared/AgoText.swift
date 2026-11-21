import SwiftUI

/// How long ago a date was, in one coarse unit: "just now", "12 min ago",
/// "3 hr ago", "4 days ago", then months and years. Minutes are the finest
/// grain and a larger unit drops the smaller ones, so a timestamp never
/// ticks by the second.
enum CoarseAgo {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        let future = seconds < 0
        let minutes = Int(abs(seconds) / 60)
        let amount: String
        switch minutes {
        case ..<1: return "just now"
        case ..<60: amount = "\(minutes) min"
        case ..<(60 * 24): amount = "\(minutes / 60) hr"
        case ..<(60 * 24 * 30): amount = plural(minutes / (60 * 24), "day")
        case ..<(60 * 24 * 365): amount = plural(minutes / (60 * 24 * 30), "month")
        default: amount = plural(minutes / (60 * 24 * 365), "year")
        }
        return future ? "in \(amount)" : "\(amount) ago"
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        count == 1 ? "1 \(unit)" : "\(count) \(unit)s"
    }
}

/// A coarse "ago" label that refreshes once a minute.
struct AgoText: View {
    let date: Date
    var prefix: String = ""
    var suffix: String = ""

    init(_ date: Date, prefix: String = "", suffix: String = "") {
        self.date = date
        self.prefix = prefix
        self.suffix = suffix
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(prefix + CoarseAgo.string(date, now: context.date) + suffix)
        }
    }
}

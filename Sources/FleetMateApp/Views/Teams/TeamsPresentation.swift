import SwiftUI
import FleetMateCore

// MARK: - Helpers

enum TeamsPeriod: String, CaseIterable, Identifiable {
    case anyTime, lastWeek, lastMonth, lastQuarter, lastYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .lastWeek: "Last 7 days"
        case .lastMonth: "Last 30 days"
        case .lastQuarter: "Last 90 days"
        case .lastYear: "Last year"
        }
    }

    /// The `since` day for the API, or nil for any time.
    var since: String? {
        let days: Int
        switch self {
        case .anyTime: return nil
        case .lastWeek: days = 7
        case .lastMonth: days = 30
        case .lastQuarter: days = 90
        case .lastYear: days = 365
        }
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }
}

enum TeamsDates {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func relative(_ value: String?) -> String {
        guard let date = parse(value) else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    static func full(_ value: String?) -> String {
        guard let date = parse(value) else { return value ?? "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ value: String) -> String? {
        if let date = parse(value) { return date.formatted(date: .abbreviated, time: .omitted) }
        return value.isEmpty ? nil : String(value.prefix(10))
    }
}

extension TeamsSearchHit {
    /// Thread ids are unique within a channel, not across channels.
    var key: String { "\(channelId)/\(threadId)" }
    var title: String {
        let subject = TeamsText.line(subject)
        if !subject.isEmpty { return subject }
        let first = TeamsText.line(snippet.split(separator: "\n").first.map(String.init) ?? snippet)
        return first.isEmpty ? "(no text)" : first
    }
}

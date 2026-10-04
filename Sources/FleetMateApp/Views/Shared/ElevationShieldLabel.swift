import SwiftUI
import FleetMateCore

/// The toolbar's authentication shield, carrying the elevation sessions'
/// state: a spinner while a container starts (the slow first action of the
/// day), a small dot otherwise. The tooltip lists each domain with its time
/// left. Re-derived every 30 seconds so an expiry shows on time without
/// polling Azure.
struct ElevationShieldLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usesAze = appState.config.graphUsesAze
            let status = appState.elevationAggregate(at: context.date)
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                if usesAze {
                    if status == .starting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(tint(status))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .accessibilityLabel(usesAze ? "Authentication, elevation \(status.label.lowercased())" : "Authentication")
            .help(help(at: context.date, usesAze: usesAze))
        }
    }

    private func tint(_ status: ElevationStatus) -> Color {
        switch status {
        case .ready: return .green
        case .starting, .expired: return .orange
        case .idle, .unknown: return .secondary
        }
    }

    private func help(at now: Date, usesAze: Bool) -> String {
        var lines = ["Authentication status for every connected system"]
        guard usesAze else { return lines[0] }
        lines.append("")
        lines.append("Elevation sessions:")
        for domain in AppState.elevationDomains {
            let status = appState.elevationStatus(domain, at: now)
            var line = "\(domain.rawValue.capitalized): \(status.label)"
            switch status {
            case .ready(let expires?):
                let left = Int(expires.timeIntervalSince(now) / 60)
                line += left >= 60 ? ", \(left / 60)h \(left % 60)m left" : ", \(max(left, 0))m left"
            case .starting:
                line += " (first action can take about a minute)"
            case .idle, .expired:
                line += " (starts on next action)"
            default:
                break
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

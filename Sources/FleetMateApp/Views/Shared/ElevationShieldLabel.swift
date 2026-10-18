import SwiftUI
import FleetMateCore

/// The toolbar's authentication shield, carrying the elevated sessions'
/// state: a spinner and "Elevation starting…" while a container starts (the
/// slow first action of the day), a green dot and "Elevation ready" while one
/// runs, and a quiet grey dot when they are stopped, since the next action
/// restarts them. The text drops out on narrow windows so the item stays
/// compact; the tooltip lists each domain with its time left. Re-derived
/// every 30 seconds so an expiry shows on time without polling Azure.
struct ElevationShieldLabel: View {
    @EnvironmentObject var appState: AppState
    /// False on narrow windows: the shield and dot alone.
    var showsText = true
    /// Window width under which the toolbar drops the text.
    static let textHiddenBelow: CGFloat = 1100

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usesAze = appState.config.graphUsesAze
            let status = appState.elevationAggregate(at: context.date)
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                if usesAze {
                    if status == .starting {
                        ProgressView().controlSize(.mini).tint(.blue)
                    } else {
                        Circle()
                            .fill(tint(status))
                            .frame(width: 6, height: 6)
                    }
                    if showsText, let text = ElevationWording.toolbarText(status) {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(usesAze ? "Authentication, elevated sessions \(ElevationWording.stateLabel(status).lowercased())" : "Authentication")
            .help(help(at: context.date, usesAze: usesAze))
        }
    }

    private func tint(_ status: ElevationStatus) -> Color {
        switch status {
        case .ready: return .green
        case .starting: return .blue
        // A stopped session is not a sign-in problem: the next action
        // restarts it.
        case .expired, .idle, .unknown: return .secondary
        }
    }

    private func help(at now: Date, usesAze: Bool) -> String {
        var lines = ["Authentication status for every connected system"]
        guard usesAze else { return lines[0] }
        lines.append(ElevationWording.explainer)
        lines.append("")
        for domain in AppState.elevationDomains {
            let status = appState.elevationStatus(domain, at: now)
            lines.append("\(ElevationWording.domainTitle(domain)): \(ElevationWording.detail(status, at: now))")
        }
        return lines.joined(separator: "\n")
    }
}

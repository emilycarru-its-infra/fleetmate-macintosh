import Foundation

/// The places a lightbox has shown, in the order they were reached, and which
/// one it shows now: what its breadcrumb trail draws and what Back and Forward
/// move through.
///
/// It behaves like a browser's history for one tab. Following a link drops
/// anything ahead of the current place and adds the new one; going back to a
/// crumb keeps what lies ahead of it, so Forward can return there.
public struct LightboxHistory<Destination: Hashable>: Equatable {
    public private(set) var entries: [Destination]
    public private(set) var index: Int

    public init(_ root: Destination) {
        entries = [root]
        index = 0
    }

    public var current: Destination { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Follow a link to `destination`. A link to the place already shown
    /// changes nothing; anything ahead of the current place is dropped.
    public mutating func push(_ destination: Destination) {
        guard destination != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(destination)
        index = entries.count - 1
    }

    public mutating func back() {
        if canGoBack { index -= 1 }
    }

    public mutating func forward() {
        if canGoForward { index += 1 }
    }

    /// Jump to the crumb at `position`, keeping the places after it.
    public mutating func go(to position: Int) {
        guard entries.indices.contains(position) else { return }
        index = position
    }
}

extension FleetMateLink {
    /// Whether the lightbox has a detail view for what the link names. The
    /// rest (devices, assets, tickets, people, Reporting pages) open in their
    /// own tab.
    public var opensInLightbox: Bool {
        switch self {
        case .workItem, .gitHubIssue, .pullRequest, .commit,
             .azureDevOpsRun, .azureDevOpsPipeline, .gitHubRun:
            return true
        case .device, .asset, .ticket, .user, .group, .reporting:
            return false
        }
    }
}

/// What following a link does to the Agent terminal dock.
///
/// A link is followed to see what it names. While the dock covers part of the
/// window, or all of it, that thing would open behind the terminal, so the
/// dock gets out of the way. A link that leaves the app (a browser page)
/// shows nothing in the window, so the terminal stays where it is.
public enum AgentDockLinkRule {
    public enum Target: Equatable {
        /// A tab, a detail view or the lightbox in FleetMate's window.
        case inApp
        /// A page in the browser or another app.
        case outsideApp
    }

    public static func hidesDock(dockShowing: Bool, target: Target) -> Bool {
        dockShowing && target == .inApp
    }
}

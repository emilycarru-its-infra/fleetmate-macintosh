import Foundation

/// Where a machine's address came from during a scan.
public enum AddressSource: String, Sendable, Codable {
    case none
    case reportMate
    case mdns
    case stored
}

public enum HostState: Sendable {
    /// No address could be found.
    case unresolved
    /// An address is known but neither SSH nor Screen Sharing answered.
    case unreachable
    /// At least one of SSH or Screen Sharing answered on the address.
    case online
}

/// What a scan learned about one machine.
public struct HostScanResult: Hashable, Sendable {
    public var serial: String
    public var ip: String
    public var source: AddressSource
    public var sshOpen: Bool
    public var screenSharingOpen: Bool
    public var scannedAt: Date

    public init(serial: String, ip: String = "", source: AddressSource = .none,
                sshOpen: Bool = false, screenSharingOpen: Bool = false, scannedAt: Date = Date()) {
        self.serial = serial
        self.ip = ip
        self.source = source
        self.sshOpen = sshOpen
        self.screenSharingOpen = screenSharingOpen
        self.scannedAt = scannedAt
    }

    public var hasAddress: Bool { !ip.isEmpty }

    public var state: HostState {
        if !hasAddress { return .unresolved }
        return (sshOpen || screenSharingOpen) ? .online : .unreachable
    }

    public var isOnline: Bool { state == .online }

    public static func unresolved(_ serial: String) -> HostScanResult {
        HostScanResult(serial: serial)
    }
}

/// Which sources answered during the last scan, for the badge.
public enum ScanMode: Sendable {
    case unknown
    case reportMate
    case mdnsOnly
    case limited

    public var label: String {
        switch self {
        case .unknown: "No scan yet"
        case .reportMate: "ReportMate active"
        case .mdnsOnly: "mDNS only"
        case .limited: "Limited connectivity"
        }
    }
}

public struct ScanSummary: Sendable {
    public var mode: ScanMode
    public var total: Int
    public var resolved: Int
    public var online: Int
    public var fromReportMate: Int
    public var fromMdns: Int
    public var reportMateAvailable: Bool
    public var duration: TimeInterval

    public init(mode: ScanMode = .unknown, total: Int = 0, resolved: Int = 0, online: Int = 0,
                fromReportMate: Int = 0, fromMdns: Int = 0, reportMateAvailable: Bool = false,
                duration: TimeInterval = 0) {
        self.mode = mode
        self.total = total
        self.resolved = resolved
        self.online = online
        self.fromReportMate = fromReportMate
        self.fromMdns = fromMdns
        self.reportMateAvailable = reportMateAvailable
        self.duration = duration
    }
}

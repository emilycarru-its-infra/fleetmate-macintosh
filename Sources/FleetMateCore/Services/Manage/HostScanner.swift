import Foundation

/// Where a scan looks up inventory addresses. `ReportMateDeviceDirectory`
/// is the real one; tests substitute a fake.
public protocol DeviceDirectory: Sendable {
    /// Serial to best LAN address for every Mac the inventory knows.
    func addressMap() async throws -> [String: String]
}

/// How a scan checks the network. `NetworkReachabilityProbe` is the real
/// one; tests substitute a fake.
public protocol ReachabilityProbe: Sendable {
    /// Resolve a Bonjour name to an address, or nil.
    func resolve(hostname: String) async -> String?
    /// True when a TCP connection to `ip:port` completes.
    func isTcpOpen(ip: String, port: Int) async -> Bool
}

extension ReportMateService: @unchecked Sendable {}

public struct ReportMateDeviceDirectory: DeviceDirectory {
    private let service: ReportMateService

    public init(service: ReportMateService) {
        self.service = service
    }

    public func addressMap() async throws -> [String: String] {
        try await service.getNetworkAddressMap()
    }
}

/// mDNS resolution through ping, and TCP probes through a connect with a
/// short timeout. ICMP is filtered on some lab subnets, so a completed
/// connect is the liveness test, never the ping.
public struct NetworkReachabilityProbe: ReachabilityProbe {
    public var connectTimeout: TimeInterval
    public var pingTimeoutMilliseconds: Int

    public init(connectTimeout: TimeInterval = 1.5, pingTimeoutMilliseconds: Int = 1000) {
        self.connectTimeout = connectTimeout
        self.pingTimeoutMilliseconds = pingTimeoutMilliseconds
    }

    /// Bonjour first (`name.local`, answered by the machine itself), then the
    /// unicast resolver for the bare name (campus DNS registers DHCP leases),
    /// which is what reaches a machine on another subnet.
    public func resolve(hostname: String) async -> String? {
        let bare = hostname.hasSuffix(".local") ? String(hostname.dropLast(".local".count)) : hostname
        let name = "\(bare).local"
        let result = await ProcessRunner.run("/sbin/ping", ["-c1", "-W\(pingTimeoutMilliseconds)", name])
        if let ip = Self.extractIP(from: result.stdout) { return ip }
        return await Self.unicastLookup(bare, timeout: connectTimeout)
    }

    /// IPv4 for `name` through the system resolver, bounded by `timeout`
    /// (getaddrinfo cannot be cancelled, so the lookup is raced against a
    /// sleep and a late answer is dropped).
    static func unicastLookup(_ name: String, timeout: TimeInterval) async -> String? {
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await Task.detached(priority: .userInitiated) { Self.getaddrinfoIPv4(name) }.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func getaddrinfoIPv4(_ name: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let addr = entry.pointee.ai_addr {
                var sin = sockaddr_in()
                memcpy(&sin, addr, Int(MemoryLayout<sockaddr_in>.size))
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buffer)
                    if !ip.hasPrefix("127.") { return ip }
                }
            }
            cursor = entry.pointee.ai_next
        }
        return nil
    }

    /// Pattern: `PING name.local (10.15.2.50): 56 data bytes`.
    static func extractIP(from output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)"),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    public func isTcpOpen(ip: String, port: Int) async -> Bool {
        let timeout = connectTimeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: TcpProbe.connects(ip: ip, port: port, timeout: timeout))
            }
        }
    }
}

/// A non-blocking IPv4 connect with a select-based timeout.
enum TcpProbe {
    static func connects(ip: String, port: Int, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(fd, &writeSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        let ready = select(fd + 1, nil, &writeSet, nil, &tv)
        guard ready > 0 else { return false }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }

    private static func fdZero(_ set: inout fd_set) {
        set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd / 32)
        let bitOffset = Int(fd % 32)
        let mask = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
        withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[intOffset] |= mask
            }
        }
    }
}

/// Resolves a room's machines to addresses and decides who is online.
///
/// Order: inventory addresses first (one call covers the fleet, including
/// WiFi-only and sleeping Macs that never answer mDNS), then name
/// resolution for the rest, then a TCP probe of 22 and 5900 for every
/// address. Inventory addresses that answer nothing are resolved by name
/// again, because the inventory can be days behind a DHCP lease. Ad-hoc
/// devices with a stored address are probed at that address and keep it
/// even when nothing answers, so SSH and Screen Sharing stay one click away.
public struct HostScanner: Sendable {
    public static let sshPort = 22
    public static let screenSharingPort = 5900

    private let directory: DeviceDirectory?
    private let probe: ReachabilityProbe
    public var concurrency: Int

    public init(directory: DeviceDirectory?, probe: ReachabilityProbe = NetworkReachabilityProbe(), concurrency: Int = 16) {
        self.directory = directory
        self.probe = probe
        self.concurrency = max(1, concurrency)
    }

    public struct Progress: Sendable {
        public var status: String
        public var fraction: Double
    }

    /// Scan `computers`. `knownAddresses` seeds ad-hoc devices (hostname to
    /// stored IP). Progress is reported as phases complete.
    public func scan(
        _ computers: [RosterComputer],
        knownAddresses: [String: String] = [:],
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> (results: [String: HostScanResult], summary: ScanSummary) {
        let started = Date()
        var addresses: [String: (ip: String, source: AddressSource)] = [:]
        var reportMateAvailable = false

        let regular = computers.filter { !$0.isAdhoc }
        let adhoc = computers.filter { $0.isAdhoc }

        // 1. Inventory.
        onProgress?(Progress(status: "Checking ReportMate…", fraction: 0.05))
        if let directory, !regular.isEmpty {
            do {
                let map = try await directory.addressMap()
                reportMateAvailable = !map.isEmpty
                for c in regular {
                    if let ip = map[c.serial], !ip.isEmpty { addresses[c.serial] = (ip, .reportMate) }
                }
            } catch {
                dbg.warn("ReportMate address lookup failed: \(error.localizedDescription)", category: "manage")
            }
        }
        if Task.isCancelled { return ([:], ScanSummary(mode: .unknown, total: computers.count)) }

        // 2. mDNS for anything the inventory did not cover, and ad-hoc devices without an address.
        let needsResolve = regular.filter { addresses[$0.serial] == nil && $0.hasHostname }
            + adhoc.filter { (knownAddresses[$0.hostname] ?? "").isEmpty }
        onProgress?(Progress(status: reportMateAvailable
            ? "ReportMate matched \(addresses.count)/\(regular.count), resolving the rest…"
            : "ReportMate unavailable, resolving hostnames…", fraction: 0.3))
        let resolved = await throttled(needsResolve) { c -> (String, String?) in
            (c.serial, await probe.resolve(hostname: c.hostname))
        }
        for (serial, ip) in resolved {
            if let ip, !ip.isEmpty { addresses[serial] = (ip, .mdns) }
        }
        for c in adhoc {
            if let ip = knownAddresses[c.hostname], !ip.isEmpty, addresses[c.serial] == nil {
                addresses[c.serial] = (ip, .stored)
            }
        }
        if Task.isCancelled { return ([:], ScanSummary(mode: .unknown, total: computers.count)) }

        // 3. TCP probe of every address.
        onProgress?(Progress(status: "Probing \(addresses.count) addresses…", fraction: 0.6))
        let snapshot = addresses
        let withAddress = computers.filter { snapshot[$0.serial] != nil }
        var probed = await throttled(withAddress) { c -> HostScanResult in
            let entry = snapshot[c.serial]!
            return await probePorts(serial: c.serial, ip: entry.ip, source: entry.source)
        }
        if Task.isCancelled { return ([:], ScanSummary(mode: .unknown, total: computers.count)) }

        // 4. An inventory address that answered nothing may simply be an old
        // lease: the machine reported it days ago and has moved since. Ask
        // the network for the name and, when that gives a different address,
        // probe that one instead.
        let silentBySerial = Dictionary(uniqueKeysWithValues: probed
            .filter { $0.source == .reportMate && !$0.isOnline }
            .map { ($0.serial, $0) })
        let stale = regular.filter { silentBySerial[$0.serial] != nil && $0.hasHostname }
        if !stale.isEmpty {
            onProgress?(Progress(status: "\(stale.count) inventory addresses silent, resolving by name…", fraction: 0.8))
            let moved = await throttled(stale) { c -> HostScanResult? in
                guard let ip = await probe.resolve(hostname: c.hostname), !ip.isEmpty,
                      ip != silentBySerial[c.serial]?.ip else { return nil }
                return await probePorts(serial: c.serial, ip: ip, source: .mdns)
            }
            let movedBySerial = Dictionary(uniqueKeysWithValues: moved.compactMap { $0 }.map { ($0.serial, $0) })
            probed = probed.map { movedBySerial[$0.serial] ?? $0 }
        }

        var results: [String: HostScanResult] = [:]
        for c in computers { results[c.serial] = .unresolved(c.serial) }
        for r in probed { results[r.serial] = r }

        let fromReportMate = probed.filter { $0.source == .reportMate }.count
        let fromMdns = probed.filter { $0.source == .mdns }.count
        let online = probed.filter(\.isOnline).count
        let mode: ScanMode
        if reportMateAvailable && fromReportMate > 0 { mode = .reportMate }
        else if !probed.isEmpty { mode = .mdnsOnly }
        else { mode = .limited }

        onProgress?(Progress(status: "", fraction: 1))
        return (results, ScanSummary(
            mode: mode, total: computers.count, resolved: probed.count, online: online,
            fromReportMate: fromReportMate, fromMdns: fromMdns,
            reportMateAvailable: reportMateAvailable,
            duration: Date().timeIntervalSince(started)))
    }

    /// Re-check one machine: the name first (or the known address for
    /// ad-hoc), then a TCP probe. When the name does not resolve but an
    /// address is known from before, that address is probed so a machine
    /// that answers only on its old lease is not reported as gone.
    public func rescan(_ computer: RosterComputer, knownIp: String?) async -> HostScanResult {
        var ip: String? = nil
        var source: AddressSource = .none
        if computer.hasHostname, let resolved = await probe.resolve(hostname: computer.hostname) {
            ip = resolved; source = .mdns
        } else if let knownIp, !knownIp.isEmpty {
            ip = knownIp; source = .stored
        }
        guard let ip else { return .unresolved(computer.serial) }
        return await probePorts(serial: computer.serial, ip: ip, source: source)
    }

    private func probePorts(serial: String, ip: String, source: AddressSource) async -> HostScanResult {
        async let ssh = probe.isTcpOpen(ip: ip, port: Self.sshPort)
        async let vnc = probe.isTcpOpen(ip: ip, port: Self.screenSharingPort)
        return HostScanResult(serial: serial, ip: ip, source: source,
                              sshOpen: await ssh, screenSharingOpen: await vnc)
    }

    private func throttled<T: Sendable, R: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: R.self, returning: [R].self) { group in
            var results: [R] = []
            var index = 0
            let limit = concurrency
            while index < items.count && index < limit {
                let item = items[index]; index += 1
                group.addTask { await body(item) }
            }
            while let r = await group.next() {
                results.append(r)
                if index < items.count {
                    let item = items[index]; index += 1
                    group.addTask { await body(item) }
                }
            }
            return results
        }
    }
}

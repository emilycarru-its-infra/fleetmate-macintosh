import XCTest
@testable import FleetMateCore

/// Fakes for the scanner: an inventory that knows some serials, and a
/// network where some addresses answer on some ports.
struct FakeDirectory: DeviceDirectory {
    var map: [String: String]
    var fails = false

    func addressMap() async throws -> [String: String] {
        if fails { throw URLError(.cannotConnectToHost) }
        return map
    }
}

final class FakeProbe: ReachabilityProbe, @unchecked Sendable {
    private let lock = NSLock()
    var mdns: [String: String]
    var open: Set<String>
    private(set) var resolved: [String] = []
    private(set) var probed: [String] = []

    init(mdns: [String: String] = [:], open: Set<String> = []) {
        self.mdns = mdns
        self.open = open
    }

    func resolve(hostname: String) async -> String? {
        lock.withLock { resolved.append(hostname) }
        return mdns[hostname]
    }

    func isTcpOpen(ip: String, port: Int) async -> Bool {
        lock.withLock { probed.append("\(ip):\(port)") }
        return open.contains("\(ip):\(port)")
    }
}

final class HostScannerTests: XCTestCase {
    let lab = [
        RosterComputer(serial: "S1", hostname: "LAB-01"),
        RosterComputer(serial: "S2", hostname: "LAB-02"),
        RosterComputer(serial: "S3", hostname: "LAB-03"),
        RosterComputer(serial: "S4", allocation: "No hostname yet"),
    ]

    func testInventoryFirstThenMdnsThenTcp() async {
        let directory = FakeDirectory(map: ["S1": "10.15.1.1", "S2": "10.17.1.2"])
        let probe = FakeProbe(mdns: ["LAB-03": "10.15.1.3"], open: ["10.15.1.1:22", "10.15.1.1:5900", "10.15.1.3:5900"])
        let scanner = HostScanner(directory: directory, probe: probe, concurrency: 2)

        let (results, summary) = await scanner.scan(lab)

        XCTAssertEqual(results["S1"]?.ip, "10.15.1.1")
        XCTAssertEqual(results["S1"]?.source, .reportMate)
        XCTAssertEqual(results["S1"]?.state, .online)
        XCTAssertEqual(results["S2"]?.state, .unreachable, "inventory address that answers nothing")
        XCTAssertEqual(results["S3"]?.source, .mdns)
        XCTAssertTrue(results["S3"]!.isOnline, "Screen Sharing alone counts as online")
        XCTAssertEqual(results["S4"]?.state, .unresolved)
        XCTAssertEqual(probe.resolved, ["LAB-03"], "inventory hits are not re-resolved; rows without a hostname are skipped")
        XCTAssertEqual(summary.mode, .reportMate)
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.resolved, 3)
        XCTAssertEqual(summary.online, 2)
        XCTAssertEqual(summary.fromReportMate, 2)
        XCTAssertEqual(summary.fromMdns, 1)
    }

    func testInventoryFailureFallsBackToMdns() async {
        let probe = FakeProbe(mdns: ["LAB-01": "10.15.1.1"], open: ["10.15.1.1:22"])
        let scanner = HostScanner(directory: FakeDirectory(map: [:], fails: true), probe: probe)
        let (results, summary) = await scanner.scan(lab)
        XCTAssertEqual(results["S1"]?.source, .mdns)
        XCTAssertEqual(summary.mode, .mdnsOnly)
        XCTAssertFalse(summary.reportMateAvailable)
        XCTAssertEqual(Set(probe.resolved), ["LAB-01", "LAB-02", "LAB-03"])
    }

    func testNothingAnswersIsLimited() async {
        let scanner = HostScanner(directory: nil, probe: FakeProbe())
        let (results, summary) = await scanner.scan(lab)
        XCTAssertEqual(summary.mode, .limited)
        XCTAssertTrue(results.values.allSatisfy { $0.state == .unresolved })
    }

    func testAdhocDevicesKeepStoredAddressEvenWhenUnreachable() async {
        let stored = RosterComputer.adhoc(hostname: "loaner", ip: "10.15.9.9")
        let named = RosterComputer.adhoc(hostname: "kiosk-7", ip: "")
        let probe = FakeProbe(mdns: ["kiosk-7": "10.15.9.7"], open: ["10.15.9.7:22"])
        let scanner = HostScanner(directory: FakeDirectory(map: [:]), probe: probe)
        let (results, _) = await scanner.scan([stored, named], knownAddresses: ["loaner": "10.15.9.9"])
        XCTAssertEqual(results[stored.serial]?.ip, "10.15.9.9")
        XCTAssertEqual(results[stored.serial]?.source, .stored)
        XCTAssertEqual(results[stored.serial]?.state, .unreachable)
        XCTAssertEqual(results[named.serial]?.source, .mdns)
        XCTAssertTrue(results[named.serial]!.isOnline)
        XCTAssertEqual(probe.resolved, ["kiosk-7"], "a stored address is not re-resolved")
    }

    func testRescanOneMachine() async {
        let probe = FakeProbe(mdns: ["LAB-01": "10.15.1.1"], open: ["10.15.1.1:5900"])
        let scanner = HostScanner(directory: nil, probe: probe)
        let r = await scanner.rescan(lab[0], knownIp: nil)
        XCTAssertEqual(r.ip, "10.15.1.1")
        XCTAssertTrue(r.screenSharingOpen)
        XCTAssertFalse(r.sshOpen)
        let stored = await scanner.rescan(RosterComputer.adhoc(hostname: "x", ip: "10.1.1.1"), knownIp: "10.1.1.1")
        XCTAssertEqual(stored.source, .stored)
    }

    func testProgressReportsPhases() async {
        let scanner = HostScanner(directory: FakeDirectory(map: ["S1": "10.15.1.1"]), probe: FakeProbe())
        let collector = OutputCollector()
        _ = await scanner.scan(lab) { collector.append($0.status + "|") }
        XCTAssertTrue(collector.text.contains("Checking ReportMate"))
        XCTAssertTrue(collector.text.contains("ReportMate matched 1/4"))
        XCTAssertTrue(collector.text.contains("Probing 1 addresses"))
    }

    func testPingOutputParsing() {
        XCTAssertEqual(NetworkReachabilityProbe.extractIP(from: "PING Lab-01.local (10.15.2.50): 56 data bytes\n"), "10.15.2.50")
        XCTAssertNil(NetworkReachabilityProbe.extractIP(from: "ping: cannot resolve Lab-01.local: Unknown host"))
    }

    func testTcpProbeAgainstLocalListener() throws {
        // Bind an ephemeral port and confirm the probe sees it open, then closed.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        XCTAssertTrue(TcpProbe.connects(ip: "127.0.0.1", port: port, timeout: 1))
        close(fd)
        XCTAssertFalse(TcpProbe.connects(ip: "127.0.0.1", port: port, timeout: 1))
        XCTAssertFalse(TcpProbe.connects(ip: "not an ip", port: 22, timeout: 1))
    }
}

final class ReportMateNetworkAddressTests: XCTestCase {

    func testBestIPPrefersWiredLabSubnetsThenWifiThenAnyPrivate() throws {
        let json = """
        [
          {"serialNumber": "S1", "operatingSystem": "macOS", "raw": {"interfaces": [
            {"name": "en0", "type": "WiFi", "isUp": 1, "addresses": [{"address": "10.17.4.4", "family": "IPv4"}]},
            {"name": "en5", "type": "Ethernet", "isUp": 1, "addresses": [{"address": "10.15.2.50", "family": "IPv4"}, {"address": "fe80::1", "family": "IPv6"}]},
            {"name": "lo0", "type": "loopback", "isUp": 1, "addresses": [{"address": "127.0.0.1", "family": "IPv4"}]}
          ]}},
          {"serialNumber": "S2", "operatingSystem": "macOS", "raw": {"interfaces": [
            {"name": "en0", "type": "WiFi", "isUp": 1, "ipAddresses": ["10.17.4.5"]},
            {"name": "en5", "type": "Ethernet", "isUp": 0, "ipAddresses": ["10.15.2.51"]}
          ]}},
          {"serialNumber": "S3", "operatingSystem": "macOS", "raw": {"interfaces": [
            {"name": "en0", "type": "WiFi", "isActive": true, "ipAddresses": ["10.20.1.1"]},
            {"name": "en5", "type": "Ethernet", "status": "up", "ipAddresses": ["10.20.1.2"]}
          ]}},
          {"serialNumber": "S4", "operatingSystem": "macOS", "raw": {"interfaces": [
            {"name": "en0", "type": "WiFi", "isUp": 1, "ipAddresses": ["192.168.1.9"]}
          ]}},
          {"serialNumber": "W1", "operatingSystem": "Windows", "raw": {"interfaces": [
            {"name": "eth", "type": "Ethernet", "isUp": 1, "ipAddresses": ["10.15.3.3"]}
          ]}}
        ]
        """
        let devices = try JSONDecoder().decode([ReportMateNetworkDevice].self, from: Data(json.utf8))
        XCTAssertEqual(devices.first { $0.serialNumber == "S1" }?.bestIP(), "10.15.2.50")
        XCTAssertEqual(devices.first { $0.serialNumber == "S2" }?.bestIP(), "10.17.4.5", "down wired interface is ignored")
        XCTAssertEqual(devices.first { $0.serialNumber == "S3" }?.bestIP(), "10.20.1.2", "wired wins among other private addresses")
        XCTAssertNil(devices.first { $0.serialNumber == "S4" }?.bestIP(), "non-10.x addresses are not fleet addresses")
        XCTAssertFalse(devices.first { $0.serialNumber == "W1" }!.isMac)
    }
}

import XCTest
@testable import FleetMateCore

/// The CLI-first path: when `reportmate` is installed, every read goes through
/// it with the same credential the HTTP path would send, and the API's JSON
/// decodes identically. When the binary cannot launch, HTTP takes over.
final class ReportMateCliTests: XCTestCase {

    /// Writes an executable stub that records its arguments and environment
    /// to `log` and prints `stdout`, exiting with `exitCode`.
    private func makeStub(stdout: String, stderr: String = "", exitCode: Int32 = 0) throws -> (path: String, log: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reportmate-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log").path
        let script = dir.appendingPathComponent("reportmate")
        let body = """
        #!/bin/sh
        echo "ARGS: $*" >> "\(log)"
        echo "URL: $REPORTMATE_API_URL" >> "\(log)"
        echo "PASSPHRASE: $REPORTMATE_PASSPHRASE" >> "\(log)"
        echo "TOKEN: ${REPORTMATE_TOKEN:-unset}" >> "\(log)"
        printf '%s' '\(stdout)'
        printf '%s' '\(stderr)' >&2
        exit \(exitCode)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, log)
    }

    private func calls(_ log: String) -> String {
        (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    }

    func testLocateHonoursPinnedBinaryAndRejectsNonExecutable() throws {
        let stub = try makeStub(stdout: "{}")
        XCTAssertEqual(ReportMateCli.locate(environment: ["REPORTMATE_CLI": stub.path])?.path, stub.path)
        XCTAssertNil(ReportMateCli.locate(environment: ["REPORTMATE_CLI": "/nonexistent/reportmate"]))
        XCTAssertNil(ReportMateCli.locate(environment: ["REPORTMATE_CLI": ""]), "empty pin disables the CLI path")
    }

    func testDevicesGoThroughTheCliWithTheServiceCredential() async throws {
        let json = """
        {"devices":[{"serialNumber":"SER-LAB01","deviceName":"LAB-01","hostname":"lab-01"}],"total":1,"offset":0,"limit":100}
        """
        let stub = try makeStub(stdout: json)
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu/", passphrase: "secret",
                                        cli: ReportMateCli(path: stub.path))
        XCTAssertTrue(service.usesCli)

        let devices = try await service.getDevices()

        XCTAssertEqual(devices.map(\.serialNumber), ["SER-LAB01"])
        let log = calls(stub.log)
        XCTAssertTrue(log.contains("ARGS: devices --limit 100 --offset 0 --output json"), log)
        XCTAssertTrue(log.contains("URL: https://reportmate.example.edu\n"), "trailing slash is stripped: \(log)")
        XCTAssertTrue(log.contains("PASSPHRASE: secret"), log)
        XCTAssertTrue(log.contains("TOKEN: unset"), log)
    }

    func testFleetNetworkDecodesTheV1RowsIntoAddresses() async throws {
        let json = """
        [{"serialNumber":"SER-LAB01","deviceName":"LAB-01","lastSeen":"2026-09-01T10:00:00+00:00",
          "raw":{"activeConnection":{"ipAddress":"10.1.2.3","macAddress":"aa:bb:cc:dd:ee:ff"},
                 "interfaces":[{"name":"en0","ipAddresses":["fe80::1","10.1.2.3"],"isActive":true}]}},
         {"serialNumber":"SER-LAB02","deviceName":"LAB-02","raw":{"interfaces":[]}}]
        """
        let stub = try makeStub(stdout: json)
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu", passphrase: "secret",
                                        cli: ReportMateCli(path: stub.path))

        let addresses = try await service.getFleetAddresses()

        XCTAssertEqual(addresses["SER-LAB01"]?.primaryIp, "10.1.2.3")
        XCTAssertEqual(addresses["SER-LAB01"]?.macAddress, "aa:bb:cc:dd:ee:ff")
        XCTAssertNil(addresses["SER-LAB02"], "a device with no address is absent, not empty")
        XCTAssertTrue(calls(stub.log).contains("ARGS: module network --output json"))
    }

    func testDeviceNetworkParsesTheModuleDocument() async throws {
        let json = """
        {"success":true,"module":"network","data":{
          "primaryInterface":"Ethernet 2",
          "activeConnection":{"ipAddress":"","macAddress":""},
          "interfaces":[
            {"name":"Loopback","ipAddresses":["127.0.0.1"],"isActive":true},
            {"name":"Ethernet 2","macAddress":"00:11:22:33:44:55","ipAddresses":["fe80::abcd","192.168.5.20"],"isActive":true}]}}
        """
        let stub = try makeStub(stdout: json)
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu", passphrase: "secret",
                                        cli: ReportMateCli(path: stub.path))

        let info = try await service.getDeviceNetwork("SER-LAB01")

        XCTAssertEqual(info?.primaryIpv4, "192.168.5.20", "loopback is never the primary address")
        XCTAssertEqual(info?.interfaces.first { $0.name == "Ethernet 2" }?.ipv6Addresses, ["fe80::abcd"])
        XCTAssertTrue(calls(stub.log).contains("ARGS: device SER-LAB01 module network --output json"))
    }

    func testApiNotFoundThroughTheCliIsNil() async throws {
        let stub = try makeStub(stdout: "", stderr: "Error: GET /api/v1/device/NOPE/installs/log -> 404 Not Found: {}", exitCode: 1)
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu", passphrase: "secret",
                                        cli: ReportMateCli(path: stub.path))

        let log = try await service.getDeviceLog("NOPE")

        XCTAssertNil(log)
    }

    func testApiRefusalThroughTheCliSurfaces() async throws {
        let stub = try makeStub(stdout: "", stderr: "Error: GET /api/v1/installs -> 403 Forbidden: scope", exitCode: 1)
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu", passphrase: "secret",
                                        cli: ReportMateCli(path: stub.path))

        do {
            _ = try await service.getInstalls()
            XCTFail("a 403 must not be swallowed")
        } catch let failure as ReportMateCli.Failure {
            XCTAssertEqual(failure, .failed(exitCode: 1, stderr: "Error: GET /api/v1/installs -> 403 Forbidden: scope"))
        }
    }

    func testUnlaunchableCliFallsBackToHttp() async throws {
        StubURLProtocol.reset(stubs: [
            .init(pathContains: "/api/v1/installs", body: "[]"),
        ])
        let service = ReportMateService(baseUrl: "https://reportmate.example.edu", passphrase: "secret",
                                        cli: ReportMateCli(path: "/nonexistent/reportmate"),
                                        sessionConfiguration: StubURLProtocol.sessionConfiguration())

        let installs = try await service.getInstalls()

        XCTAssertEqual(installs.count, 0)
        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.path, "/api/v1/installs")
        XCTAssertEqual(request.headers["X-Client-Passphrase"], "secret")
    }
}

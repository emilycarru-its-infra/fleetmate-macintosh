import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// Explicit-domain elevation — the command-line face of the aze protocol.
///
/// Every call runs as the domain's managed identity (DevOps-Terraform, -Devices,
/// -Identity, -Systems, -Cloud, -Security) inside an elevation session container.
/// Nothing here uses the operator's own directory roles or PIM: the operator only
/// needs elevation-operators membership to start the session, and the identity's
/// token never leaves Azure — only the JSON result comes back.
struct ElevateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elevate",
        abstract: "Run Graph/ARM requests as a domain managed identity (aze)",
        subcommands: [
            ElevateStatusSubcommand.self,
            ElevateRestSubcommand.self,
            ElevateStopSubcommand.self
        ],
        defaultSubcommand: ElevateStatusSubcommand.self
    )

    static let allDomains: [GraphDomain] = [.terraform, .devices, .identity, .systems, .cloud, .security]
    static var domainList: String { allDomains.map(\.rawValue).joined(separator: ", ") }

    static func parseDomain(_ value: String) throws -> GraphDomain {
        guard let d = GraphDomain(rawValue: value.lowercased()) else {
            throw ValidationError("Unknown domain '\(value)'. Use one of: \(domainList)")
        }
        return d
    }
}

struct ElevateStatusSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show each domain's managed identity and session state"
    )

    func run() async throws {
        let session = ElevationSession()
        print("DOMAIN".bold.padding(toLength: 22, withPad: " ", startingAt: 0)
            + "MANAGED IDENTITY".bold.padding(toLength: 30, withPad: " ", startingAt: 0)
            + "SESSION".bold)
        for d in ElevateCommand.allDomains {
            let state: String
            do { state = try await session.sessionState(d) ?? "none" } catch { state = "error: \(error)" }
            let shown = state == "Running" ? state.green : state
            print(d.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)
                + session.identity(for: d).padding(toLength: 30, withPad: " ", startingAt: 0)
                + shown)
        }
    }
}

struct ElevateRestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rest",
        abstract: "Send one Graph/ARM request as the domain's managed identity"
    )

    @Argument(help: "Elevation domain: terraform, devices, identity, systems, cloud, security")
    var domain: String

    @Argument(help: "HTTP method: get, post, patch, put, delete")
    var method: String

    @Argument(help: "Full Graph or ARM URL, e.g. https://graph.microsoft.com/v1.0/organization")
    var url: String

    @Option(name: [.customShort("b"), .long], help: "JSON request body")
    var body: String?

    func run() async throws {
        let d = try ElevateCommand.parseDomain(domain)
        guard let verb = GraphRequest.Method(rawValue: method.lowercased()) else {
            throw ValidationError("Unsupported method '\(method)'")
        }
        guard let host = URL(string: url)?.host?.lowercased(),
              host == "graph.microsoft.com" || host == "management.azure.com" else {
            throw ValidationError("Only https://graph.microsoft.com and https://management.azure.com URLs are allowed")
        }

        let request = GraphRequest(method: verb, url: url, body: body.map { Data($0.utf8) })
        do {
            let data = try await AzeGraphTransport().send(request, as: d)
            print(String(data: data, encoding: .utf8) ?? "")
        } catch let error as AzeError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            throw ExitCode(error.exitCode)
        }
    }
}

struct ElevateStopSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "End a domain's elevation session before its TTL"
    )

    @Argument(help: "Elevation domain: terraform, devices, identity, systems, cloud, security")
    var domain: String

    func run() async throws {
        let d = try ElevateCommand.parseDomain(domain)
        let stopped = try await ElevationSession().stopSession(d)
        print(stopped ? "\("Stopped".green) the \(d.rawValue) session." : "No \(d.rawValue) session was running.")
    }
}

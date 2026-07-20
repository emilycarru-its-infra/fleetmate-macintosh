import ArgumentParser
import Foundation
import Rainbow
import FleetMateCore

/// `fleetmate login` — one sign-in for the whole FleetMate estate.
///
/// The only genuinely interactive step is `az login`: it is the trust anchor
/// for the secretless elevation model (every Graph/Intune/Entra call runs inside
/// an `aze` session keyed off the operator's own, compliant-device-gated az
/// session). Every other system authenticates silently — from a stored API key
/// (Snipe), service credentials (TDX), or the az session itself (Azure DevOps) —
/// so `login` establishes the az session and then verifies auth across all of
/// them, printing a single status matrix.
struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in to Azure and verify auth across every FleetMate system"
    )

    @Flag(name: .long, help: "Use the device-code flow (SSH / headless sessions with no browser)")
    var deviceCode: Bool = false

    @Flag(name: .long, help: "Use the macOS Platform SSO broker for a silent, device-bound az login (preview; needs az core.enable_broker_on_mac)")
    var broker: Bool = false

    @Flag(name: .long, help: "Pre-warm the aze elevation sessions (Intune/Entra) after signing in")
    var warm: Bool = false

    @Flag(name: .long, help: "Skip the interactive az login; only verify auth across systems")
    var check: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let az = LoginCommand.locateAz()
        var report = LoginReport()

        // ── Azure sign-in — the one interactive login ─────────────────────────
        if !check {
            if broker {
                // Preview: opt into the macOS Platform SSO broker (Azure/azure-cli
                // #33376). Dormant until that ships + MS updates the CLI app's
                // redirect URIs; harmless to set beforehand.
                _ = LoginCommand.sh(az, ["config", "set", "core.enable_broker_on_mac=true", "--only-show-errors"])
            }
            let tenant = config.effectiveAzureTenantId
            // Idempotent: only (re)login when not already on the right tenant.
            if LoginCommand.account(az)?.tenantId.lowercased() != tenant.lowercased() {
                var args = ["login", "--tenant", tenant, "--output", "none", "--only-show-errors"]
                if deviceCode { args.append("--use-device-code") }
                let r = LoginCommand.sh(az, args)
                if r.code != 0 {
                    report.set(.azure, .failed, r.err.isEmpty ? "az login failed" : r.err.oneLine)
                }
            }
            // Best-effort subscription selection (some identities have none).
            _ = LoginCommand.sh(az, ["account", "set", "--subscription", config.effectiveAzureSubscriptionId, "--only-show-errors"])
        }

        // Azure account status (post-login / --check).
        if let acct = LoginCommand.account(az) {
            var detail = "\(acct.user) · tenant \(LoginCommand.shortId(acct.tenantId))"
            if let sub = acct.subscriptionName { detail += " · \(sub)" }
            report.set(.azure, .ok, detail)
        } else if report[.azure] == nil {
            report.set(.azure, .failed, check ? "not signed in (run `fleetmate login` without --check)" : "not signed in")
        }

        let azureOk = report[.azure]?.status == .ok

        // ── Silent auth verification across the rest of the estate ───────────
        // Graph / Intune / Entra — via aze elevation off the az session.
        let graph = GraphService(config: config)
        if graph.isConfigured {
            if warm {
                let ok = await graph.warmElevationSessions()
                report.set(.graph, ok ? .ok : .failed, ok ? "aze elevation sessions warmed" : "could not warm elevation sessions")
            } else {
                report.set(.graph, azureOk ? .ok : .failed, azureOk ? "ready via aze (use --warm to pre-start containers)" : "needs Azure sign-in")
            }
        }

        // Azure DevOps — SSO via the az session (no PAT).
        if config.devopsOrganization?.isEmpty == false {
            let ok = (try? await AzureDevOpsService(config: config).verifyAuth()) ?? false
            report.set(.devops, ok ? .ok : .failed, ok ? (config.devopsOrganization ?? "") : "auth failed (Azure sign-in required)")
        }

        // Snipe-IT — Entra bearer (SSO) when snipe_oidc_audience is set (dormant
        // until Snipe's OIDC guard ships), else the shared API key.
        let snipe = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey, oidcAudience: config.snipeOidcAudience)
        if snipe.isConfigured {
            do {
                let n = try await snipe.getLocations().count
                report.set(.snipe, .ok, snipe.usesOidc ? "SSO identity valid · \(n) locations" : "\(n) locations")
            } catch {
                let r = LoginCommand.classify(error, service: "Snipe-IT", oidc: snipe.usesOidc)
                report.set(.snipe, r.0, r.1)
            }
        }

        // ReportMate — Entra bearer (SSO) when reportmate_oidc_audience is set,
        // else the legacy X-Client-Passphrase.
        let rm = ReportMateService(baseUrl: config.reportMateUrl, passphrase: config.reportMatePassphrase, oidcAudience: config.reportMateOidcAudience)
        if rm.isConfigured {
            do {
                let n = try await rm.getDevices().count
                report.set(.reportmate, .ok, rm.usesOidc ? "SSO identity valid · \(n) devices" : "\(n) devices")
            } catch {
                let r = LoginCommand.classify(error, service: "ReportMate", oidc: rm.usesOidc)
                report.set(.reportmate, r.0, r.1)
            }
        }

        // MunkiReport.
        let munki = MunkiReportService(config: config)
        if munki.isConfigured {
            do { report.set(.munki, .ok, "\(try await munki.getDevices().count) devices") }
            catch { report.set(.munki, .failed, error.localizedDescription.oneLine) }
        }

        // TeamDynamix — credential-based; the token is minted lazily on first
        // API call, so here we report configured-but-unverified.
        if TdxService(config: config).isConfigured {
            report.set(.tdx, .unverified, "configured; verified on first use")
        }

        if json { try LoginCommand.printJSON(report) } else { LoginCommand.printMatrix(report, check: check) }
        if report[.azure]?.status == .failed { throw ExitCode.failure }
    }

    // MARK: - az helpers

    static func locateAz() -> String {
        for c in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "az"
    }

    struct AzAccount { let user: String; let tenantId: String; let subscriptionName: String? }

    /// `az account show` parsed; nil when not signed in.
    static func account(_ az: String) -> AzAccount? {
        let r = sh(az, ["account", "show", "--output", "json", "--only-show-errors"])
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tenant = obj["tenantId"] as? String ?? ""
        let user = (obj["user"] as? [String: Any])?["name"] as? String ?? "unknown"
        return AzAccount(user: user, tenantId: tenant, subscriptionName: obj["name"] as? String)
    }

    static func shortId(_ id: String) -> String { id.count > 8 ? String(id.prefix(8)) + "…" : id }

    /// Classify a service auth failure into the three identity states the spec
    /// calls for: needs-sign-in / reachable-but-no-role / unreachable-or-error.
    static func classify(_ error: Error, service: String, oidc: Bool) -> (AuthStatus, String) {
        if error is AzTokenError {
            return (.failed, "Azure sign-in required — run `fleetmate login`")
        }
        let d = error.localizedDescription
        let lower = d.lowercased()
        if d.contains("403") || lower.contains("forbidden") {
            return (.unverified, oidc ? "reachable — no \(service) role assigned to your identity"
                                      : "reachable — credential lacks permission")
        }
        if d.contains("401") || lower.contains("unauthor") {
            return (.failed, oidc ? "token rejected (401) — check audience/role assignment" : "unauthorized (401)")
        }
        return (.failed, d.oneLine)
    }

    /// Run `az` synchronously (blocking is fine for a CLI), returning stdout/stderr/exit.
    @discardableResult
    static func sh(_ az: String, _ args: [String]) -> (out: String, err: String, code: Int32) {
        let p = Process()
        if az == "az" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["az"] + args
        } else {
            p.executableURL = URL(fileURLWithPath: az)
            p.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        // az login opens a browser and needs the user's terminal for prompts.
        p.standardInput = FileHandle.standardInput
        do { try p.run() } catch { return ("", "could not launch az: \(error.localizedDescription)", -1) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    // MARK: - Output

    static func printMatrix(_ report: LoginReport, check: Bool) {
        print("\n" + "═══════════════════════════════════════════════════════".bold)
        print("                   " + "FleetMate Login".bold.green)
        print("═══════════════════════════════════════════════════════".bold + "\n")
        for system in LoginSystem.allCases {
            guard let e = report[system] else { continue }
            print("  \(e.status.icon) \(system.label.padding(toLength: 23, withPad: " ", startingAt: 0))".lightBlue + e.detail.colored(e.status))
        }
        let failed = LoginSystem.allCases.compactMap { report[$0] }.contains { $0.status == .failed }
        print("\n" + "═══════════════════════════════════════════════════════".bold)
        print(failed ? "  Some systems need attention.".yellow : "  All configured systems authenticated.".green)
        print("═══════════════════════════════════════════════════════".bold + "\n")
    }

    static func printJSON(_ report: LoginReport) throws {
        let obj = Dictionary(uniqueKeysWithValues: LoginSystem.allCases.compactMap { s -> (String, [String: String])? in
            guard let e = report[s] else { return nil }
            return (s.rawValue, ["status": e.status.rawValue, "detail": e.detail])
        })
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Report model

enum LoginSystem: String, CaseIterable {
    case azure, graph, devops, snipe, reportmate, munki, tdx
    var label: String {
        switch self {
        case .azure: return "Azure sign-in"
        case .graph: return "Graph (Intune/Entra)"
        case .devops: return "Azure DevOps"
        case .snipe: return "Snipe-IT"
        case .reportmate: return "ReportMate"
        case .munki: return "MunkiReport"
        case .tdx: return "TeamDynamix"
        }
    }
}

enum AuthStatus: String {
    case ok, failed, unverified
    var icon: String {
        switch self {
        case .ok: return "✓".green
        case .failed: return "✗".red
        case .unverified: return "•".yellow
        }
    }
}

struct LoginReport {
    struct Entry { let status: AuthStatus; let detail: String }
    private var entries: [LoginSystem: Entry] = [:]
    subscript(_ s: LoginSystem) -> Entry? { entries[s] }
    mutating func set(_ s: LoginSystem, _ status: AuthStatus, _ detail: String) {
        entries[s] = Entry(status: status, detail: detail)
    }
}

private extension String {
    var oneLine: String {
        trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }
    func colored(_ status: AuthStatus) -> String {
        switch status {
        case .ok: return green
        case .failed: return red
        case .unverified: return yellow
        }
    }
}

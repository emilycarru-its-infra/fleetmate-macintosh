import SwiftUI
import FleetMateCore
import ReportMateKit
import ReportMateUI

/// The Reporting tab is the ReportMate dashboard itself, taken from the
/// ReportMate app's `ReportMateUI` package rather than rebuilt here. ReportMate
/// is the product; FleetMate only follows it, one way: `reportmate-sync.yml`
/// moves the pin to ReportMate's latest `main`, and nothing flows back.
@MainActor
final class ReportingHost {
    let session: ReportMateSession

    init(config: FleetMateConfig) {
        session = ReportMateSession(configuration: Self.configuration(from: config))
    }

    /// FleetMate's ReportMate connection, when it has one: the same endpoint and
    /// Entra audience the rest of FleetMate reads with. Without one the dashboard
    /// uses its own saved settings, as the standalone app does.
    static func configuration(from config: FleetMateConfig) -> ReportMateKit.AppConfiguration? {
        guard let url = config.reportMateUrl?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
        // The standalone app's web dashboard address, so Copy Link can fall back to the browser.
        let web = UserDefaults(suiteName: "com.github.reportmate.mac")?
            .string(forKey: ReportMateKit.AppConfiguration.webBaseURLDefaultsKey) ?? ""
        if let audience = config.reportMateOidcAudience, !audience.isEmpty {
            return ReportMateKit.AppConfiguration(baseURL: url, authMethod: .entraBearer, oidcAudience: audience, webBaseURL: web)
        }
        if let passphrase = config.reportMatePassphrase, !passphrase.isEmpty {
            return ReportMateKit.AppConfiguration(baseURL: url, authMethod: .passphrase, passphrase: passphrase, webBaseURL: web)
        }
        return nil
    }

    /// Open a `reportmate://` page (the target of a `fleetmate://reporting/…` link).
    func open(_ url: URL) {
        if !session.open(url: url) {
            dbg.warn("Reporting link not understood: \(url.absoluteString)", category: "links")
        }
    }

    func openDevice(serial: String) {
        session.openDevice(serial: serial)
    }

    /// Load ReportMate's device list for global search; the Reporting tab
    /// shares the same cached copy. Does nothing without a connection.
    func loadDevicesForSearch() async {
        await session.loadDevices()
    }

    /// The fields global search matches on.
    static func record(_ device: DeviceSummary) -> ReportingDeviceRecord {
        ReportingDeviceRecord(
            serial: device.serialNumber,
            name: device.name,
            hostname: device.hostname,
            user: device.inventory.owner,
            assetTag: device.inventory.assetTag,
            platform: device.platform == .unknown ? nil : device.platform.displayName
        )
    }
}

struct ReportingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ReportMateDashboard(session: appState.reporting.session)
    }
}

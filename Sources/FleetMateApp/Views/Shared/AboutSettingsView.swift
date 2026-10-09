import SwiftUI
import FleetMateCore

/// Settings ▸ About — what build this is and where to report a problem.
struct AboutSettingsView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "—" }
    private var build: String { info["CFBundleVersion"] as? String ?? "—" }

    private var platform: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private var architecture: String {
        #if arch(arm64)
        "Apple silicon (arm64)"
        #elseif arch(x86_64)
        "Intel (x86_64)"
        #else
        "Unknown"
        #endif
    }

    private static let repository = URL(string: "https://github.com/emilycarru-its-infra/fleetmate-macintosh")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppEdition.current.displayName).appFont(.title2, weight: .semibold)
                        Text("Version \(version) (\(build))")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").appFont(.headline)
                        Divider()
                        row("Version", version)
                        row("Build", build)
                        row("Platform", platform)
                        row("Architecture", architecture)
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Links").appFont(.headline)
                        Divider()
                        Link("Source code", destination: Self.repository)
                        Link("Report an issue", destination: Self.repository.appendingPathComponent("issues"))
                        Link("Release history", destination: Self.repository.appendingPathComponent("releases"))
                    }
                    .padding(4)
                }

                HStack {
                    Spacer()
                    Button("Copy Version Info") {
                        let text = "FleetMate \(version) (\(build)) · \(platform) · \(architecture)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            .padding(20)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .appFont(.callout)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

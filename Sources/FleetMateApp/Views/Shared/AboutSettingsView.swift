import SwiftUI
import FleetMateCore

/// Settings ▸ About, laid out like the sibling tools' About panes: identity,
/// build facts, related projects, then the author.
struct AboutSettingsView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var displayVersion: String {
        AppVersionDisplay.string(short: info["CFBundleShortVersionString"] as? String,
                                 build: info["CFBundleVersion"] as? String,
                                 commit: info["FleetMateGitCommit"] as? String)
    }

    /// "macOS Version 26.1 (Build 25B78)", as the system reports it.
    private var platform: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// The Swift compiler this build was made with.
    private var swiftVersion: String {
        #if compiler(>=6.4)
        "6.4"
        #elseif compiler(>=6.3)
        "6.3"
        #elseif compiler(>=6.2)
        "6.2"
        #elseif compiler(>=6.1)
        "6.1"
        #elseif compiler(>=6.0)
        "6.0"
        #else
        "5.10"
        #endif
    }

    private static let repository = "github.com/emilycarru-its-infra/fleetmate-macintosh"

    private var summary: String {
        AppEdition.current.isTicketsOnly
            ? "Service desk tickets for macOS"
            : "Unified fleet management for macOS"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppEdition.current.displayName).font(.title3).fontWeight(.semibold)
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                        Link(Self.repository, destination: URL(string: "https://\(Self.repository)")!)
                            .font(.caption)
                    }
                }

                VStack(spacing: 6) {
                    labeledInfo("Version", displayVersion)
                    labeledInfo("Platform", platform)
                    labeledInfo("Swift", swiftVersion)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Related Projects")
                    projectRow("ReportMate", "Unified reporting + visibility for Mac + Windows fleets", "https://github.com/reportmate")
                    projectRow("BootstrapMate", "Provisioning + bootstrap tooling with a DevOps-first workflow", "https://github.com/bootstrapmate")
                    projectRow("Cimian", "Managed software deployment for MSI(X), EXE, NUPKG, and PWSH on Windows", "https://github.com/windowsadmins/cimian")
                    projectRow("ASBMUtil", "Apple School & Business Manager CLI + GUI", "https://github.com/rodchristiansen/asbmutil")
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("Author")
                    Text("Rod Christiansen").font(.body).fontWeight(.medium)
                    Text("Devices Administrator Lead")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Vancouver, BC, Canada")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Managing a fleet of 1000+ computers. Focused on infrastructure, DevOps architecture, CI/CD pipelines, and automating at scale.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        linkRow("GitHub", "github.com/rodchristiansen", "https://github.com/rodchristiansen")
                        linkRow("Blog", "blog.focused.systems", "https://blog.focused.systems")
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contextMenu {
            Button("Copy Version Info") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(AppEdition.current.displayName) \(displayVersion) · \(platform) · Swift \(swiftVersion)", forType: .string)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary).textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    private func projectRow(_ name: String, _ desc: String, _ urlString: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url = URL(string: urlString) {
                Link(name, destination: url)
                    .font(.callout).fontWeight(.medium)
            } else {
                Text(name).font(.callout).fontWeight(.medium)
            }
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func linkRow(_ label: String, _ display: String, _ urlString: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout).fontWeight(.medium)
            if let url = URL(string: urlString) {
                Link(display, destination: url)
                    .font(.caption)
            }
        }
    }

    private func labeledInfo(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }
}

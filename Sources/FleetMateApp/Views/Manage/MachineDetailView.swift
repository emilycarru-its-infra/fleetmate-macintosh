import SwiftUI
import FleetMateCore

/// Everything known about one machine: the roster row, what the scan
/// found, and what the probe learned.
struct MachineDetailView: View {
    @ObservedObject var manage: ManageState
    let computer: RosterComputer

    private var scan: HostScanResult? { manage.scanResult(computer) }
    private var info: MachineInfo? { manage.machineInfos[computer.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                rosterSection
                networkSection
                if let info { probeSection(info) }
                else if manage.isOnline(computer) {
                    Button {
                        Task { await manage.fetchMachineInfo(for: [computer]) }
                    } label: {
                        Label("Fetch machine info", systemImage: "info.circle")
                    }
                    .disabled(manage.isFetchingInfo)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(manage.isOnline(computer) ? Color.manageSuccess : Color.manageFailure)
                    .frame(width: 8, height: 8)
                Text(computer.displayName)
                    .appFont(.title3, weight: .semibold)
                    .textSelection(.enabled)
            }
            if !computer.allocation.isEmpty, computer.allocation != computer.displayName {
                Text(computer.allocation).appFont(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Copy inventory line") { ManageClipboard.copy(manage.inventoryLine(for: computer)) }
                    .controlSize(.small)
                Button("Rescan") { Task { await manage.rescan(computer) } }
                    .controlSize(.small)
                    .disabled(manage.rescanningSerials.contains(computer.id))
            }
            .padding(.top, 4)
        }
    }

    private var rosterSection: some View {
        GroupBox("Roster") {
            VStack(alignment: .leading, spacing: 6) {
                row("Serial", computer.isAdhoc ? "ad hoc" : computer.serial)
                row("Asset", computer.asset)
                row("Catalog", computer.catalog)
                row("Area", computer.area)
                row("Location", computer.location)
                row("Fleet", computer.fleet)
                row("Usage", computer.usage)
                row("Status", computer.status)
                row("Username", computer.username)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var networkSection: some View {
        GroupBox("Network") {
            VStack(alignment: .leading, spacing: 6) {
                if let scan, scan.hasAddress {
                    row("Address", scan.ip)
                    row("Source", sourceLabel(scan.source))
                    row("SSH (22)", scan.sshOpen ? "answers" : "no answer")
                    row("Screen Sharing (5900)", scan.screenSharingOpen ? "answers" : "no answer")
                    row("Scanned", scan.scannedAt.formatted(date: .omitted, time: .shortened))
                } else if manage.scanSummary.mode == .unknown {
                    Text("Not scanned yet").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No address found").appFont(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func probeSection(_ info: MachineInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Session") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Console user", info.hasConsoleUser ? info.consoleUser : (info.xcredsRunning ? "xCreds login window" : "Login window"))
                    row("Email", info.email)
                    row("macOS", info.osVersion)
                    row("Uptime", info.uptime)
                    row("Munki client", info.clientIdentifier)
                    row("Fetched", info.fetchedAt.formatted(date: .omitted, time: .shortened))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Remote access") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Remote Login", info.sshRemoteLogin)
                    row("SSH port", info.sshPortListening ? "listening" : "not listening")
                    row("Screen Sharing", info.screenSharingState)
                    row("Screen Sharing port", info.screenSharingPortListening ? "listening" : "not listening")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            let ard = info.ardText.enumerated().filter { !$0.element.isEmpty }
            if !ard.isEmpty {
                GroupBox("Remote Desktop info") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ard, id: \.offset) { item in
                            row("Text \(item.offset + 1)", item.element)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !info.topApps.isEmpty {
                GroupBox("Running applications") {
                    Text(info.topApps.joined(separator: ", "))
                        .appFont(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(value)
                    .appFont(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sourceLabel(_ source: AddressSource) -> String {
        switch source {
        case .reportMate: "ReportMate"
        case .mdns: "mDNS"
        case .stored: "stored address"
        case .none: "unknown"
        }
    }
}

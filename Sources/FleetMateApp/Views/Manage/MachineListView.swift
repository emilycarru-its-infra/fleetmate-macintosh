import SwiftUI
import AppKit
import FleetMateCore

enum MachineRowDensity: String {
    case short
    case extended
}

/// The machines in the current room or group: scan state, who is signed
/// in, remote-access readiness, and the checkbox that makes a machine a
/// target.
struct MachineListView: View {
    @ObservedObject var manage: ManageState
    @AppStorage("manage.rowDensity") private var densityRaw = MachineRowDensity.extended.rawValue
    @State private var showAddDevice = false
    @State private var showSSHTabPicker = false

    private var density: MachineRowDensity { MachineRowDensity(rawValue: densityRaw) ?? .extended }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manage.isScanning {
                HStack(spacing: 8) {
                    ProgressView(value: manage.scanProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text(manage.scanStatus.isEmpty ? "Scanning…" : manage.scanStatus)
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                Divider()
            }

            HStack {
                Text(selectionSummary)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if manage.scanSummary.mode != .unknown {
                    Text("\(manage.onlineCount) of \(manage.currentComputers.count) online")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            Divider()

            List(manage.currentComputers) { computer in
                MachineRow(manage: manage, computer: computer, density: density)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(manage.selectedComputerIDs.contains(computer.id) ? Color.manageSelection : Color.clear)
            }
            .listStyle(.inset)
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet(manage: manage, isPresented: $showAddDevice)
        }
    }

    private var selectionSummary: String {
        let count = manage.selectedComputerIDs.count
        if count == 0 { return "No machines selected" }
        return "\(count) selected"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(manage.currentLabel)
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if manage.scanSummary.mode != .unknown {
                StatusCapsule(text: manage.scanSummary.mode.label, tint: manage.scanSummary.mode.tint)
                    .help("How the last scan found addresses")
            }

            if manage.isScanning {
                Button { manage.cancelScan() } label: {
                    Image(systemName: "xmark.circle").appFont(fixed: 12)
                }
                .buttonStyle(.borderless)
                .help("Cancel scan")
            } else {
                Button { manage.startScan() } label: {
                    Image(systemName: "dot.radiowaves.left.and.right").appFont(fixed: 12)
                }
                .buttonStyle(.borderless)
                .help("Scan again")
            }

            Spacer()

            Button("All") { manage.selectAll() }.buttonStyle(.link).appFont(.caption)
            Button("Online") { manage.selectOnline() }.buttonStyle(.link).appFont(.caption)
            Button("None") { manage.selectNone() }.buttonStyle(.link).appFont(.caption)

            Button {
                densityRaw = density == .extended ? MachineRowDensity.short.rawValue : MachineRowDensity.extended.rawValue
            } label: {
                Image(systemName: density == .extended ? "list.bullet" : "list.bullet.rectangle").appFont(fixed: 12)
            }
            .buttonStyle(.borderless)
            .help(density == .extended ? "Short rows" : "Extended rows")

            Divider().frame(height: 12)

            Button { showAddDevice = true } label: {
                Image(systemName: "plus.circle").appFont(fixed: 12)
            }
            .buttonStyle(.borderless)
            .help("Add a machine to this view or a group")

            Divider().frame(height: 12)

            Button {
                Task { await manage.fetchAllMachineInfo() }
            } label: {
                if manage.isFetchingInfo {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "info.circle").appFont(fixed: 12)
                }
            }
            .buttonStyle(.borderless)
            .disabled(manage.isFetchingInfo || manage.isScanning || manage.onlineCount == 0)
            .help("Fetch machine info (user, OS, uptime, remote access)")

            Divider().frame(height: 12)

            Menu {
                Button {
                    showSSHTabPicker = true
                } label: {
                    Label("Open SSH Tabs…", systemImage: "terminal")
                }
                .disabled(manage.onlineCount == 0)
            } label: {
                Image(systemName: "ellipsis.circle").appFont(fixed: 12)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("Actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .sheet(isPresented: $showSSHTabPicker) {
            SSHTabPickerSheet(manage: manage, isPresented: $showSSHTabPicker)
        }
    }
}

struct MachineRow: View {
    @ObservedObject var manage: ManageState
    let computer: RosterComputer
    let density: MachineRowDensity

    private var isSelected: Bool { manage.selectedComputerIDs.contains(computer.id) }
    private var isOnline: Bool { manage.isOnline(computer) }
    private var info: MachineInfo? { manage.machineInfos[computer.id] }
    private var scan: HostScanResult? { manage.scanResult(computer) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                .appFont(fixed: 13)
                .frame(width: 16)

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button { ManageClipboard.copy(computer.displayName) } label: {
                        Text(computer.displayName)
                            .appFont(.subheadline, weight: .semibold)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Copy hostname")

                    if !computer.allocation.isEmpty, computer.allocation != computer.displayName {
                        Text(computer.allocation)
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !computer.hasHostname && !computer.isAdhoc {
                        StatusCapsule(text: "no hostname", tint: .secondary)
                    }
                }

                HStack(alignment: .center, spacing: 5) {
                    addressBadge
                    remoteAccessStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if density == .extended { extendedInfo }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if density == .extended {
                    Button { manage.openScreenSharing(for: computer) } label: {
                        Image(systemName: "rectangle.on.rectangle").appFont(fixed: 11)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isOnline)
                    .help("Screen Sharing")

                    Button { manage.openSSH(for: computer) } label: {
                        Image(systemName: "terminal").appFont(fixed: 11)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isOnline)
                    .help("SSH")
                }

                Button { manage.openSSHAndScreenSharing(for: computer) } label: {
                    Image(systemName: "link").appFont(fixed: 11)
                }
                .buttonStyle(.borderless)
                .disabled(!isOnline)
                .help("SSH and Screen Sharing")

                Button {
                    Task { await manage.rescan(computer) }
                } label: {
                    if manage.rescanningSerials.contains(computer.id) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise").appFont(fixed: 11)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(manage.isScanning || manage.rescanningSerials.contains(computer.id))
                .help("Rescan this machine")
            }
            .foregroundStyle(isOnline ? Color.secondary : Color(NSColor.quaternaryLabelColor))
        }
        .contentShape(Rectangle())
        .opacity(isOnline || manage.isScanning ? 1.0 : 0.5)
        .onTapGesture { manage.toggleSelected(computer) }
        .contextMenu { contextMenu }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var addressBadge: some View {
        if let scan, scan.hasAddress {
            Button { ManageClipboard.copy(scan.ip) } label: {
                StatusCapsule(text: scan.ip, systemImage: sourceIcon(scan.source), tint: scan.isOnline ? .manageInfo : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help(scan.isOnline ? "Copy address (\(sourceLabel(scan.source)))" : "Address known from \(sourceLabel(scan.source)) but nothing answered")
        } else if manage.isScanning || manage.rescanningSerials.contains(computer.id) {
            StatusCapsule(text: "scanning", systemImage: "dot.radiowaves.left.and.right", tint: .manageWarning)
        } else if manage.scanSummary.mode == .unknown {
            StatusCapsule(text: "not scanned", systemImage: "questionmark.circle", tint: .secondary)
        } else {
            StatusCapsule(text: "offline", systemImage: "wifi.slash", tint: .secondary)
        }
    }

    @ViewBuilder
    private var remoteAccessStatus: some View {
        if isOnline && manage.sshUnavailable.contains(computer.id) {
            StatusCapsule(text: "SSH auth failed", systemImage: "key.slash", tint: .manageWarning)
                .help("The host answered but rejected the configured key or user")
        } else if let info {
            HStack(spacing: 6) {
                Button { manage.openSSH(for: computer) } label: {
                    StatusCapsule(
                        text: info.sshPortListening ? "SSH ready" : "SSH not listening",
                        systemImage: info.sshPortListening ? "terminal.fill" : "terminal",
                        tint: info.sshPortListening ? .manageSuccess : .manageWarning)
                }
                .buttonStyle(.plain)
                .disabled(!info.sshPortListening)
                .help(info.sshPortListening ? "Open SSH" : "SSH is not listening")

                Button { manage.openScreenSharing(for: computer) } label: {
                    StatusCapsule(
                        text: info.screenSharingReady ? "Screen Sharing ready" : "Screen Sharing off",
                        systemImage: info.screenSharingReady ? "rectangle.on.rectangle" : "rectangle.slash",
                        tint: info.screenSharingReady ? .manageSuccess : .manageWarning)
                }
                .buttonStyle(.plain)
                .disabled(!info.screenSharingReady)
                .help(info.screenSharingReady ? "Open Screen Sharing" : "Screen Sharing is not running")
            }
            .lineLimit(1)
            .help(remoteAccessHelp(info))
        } else if let scan, scan.isOnline {
            HStack(spacing: 6) {
                if scan.sshOpen { StatusCapsule(text: "22 open", systemImage: "terminal", tint: .manageInfo) }
                if scan.screenSharingOpen { StatusCapsule(text: "5900 open", systemImage: "rectangle.on.rectangle", tint: .manageInfo) }
            }
            .help("Ports answered; fetch machine info for the full picture")
        }
    }

    @ViewBuilder
    private var extendedInfo: some View {
        if let info {
            Group {
                if info.hasConsoleUser {
                    Label(info.consoleUser, systemImage: "person.fill").foregroundStyle(Color.accentColor)
                } else if info.xcredsRunning {
                    Label("xCreds", systemImage: "lock.shield.fill").foregroundStyle(Color.manageWarning)
                } else {
                    Label("Login window", systemImage: "person.crop.rectangle").foregroundStyle(.secondary)
                }
            }
            .appFont(.caption2)
            .lineLimit(1)

            let meta = [
                info.osVersion.isEmpty ? nil : "macOS \(info.osVersion)",
                info.uptime.isEmpty ? nil : "up \(info.uptime)",
                info.clientIdentifier.isEmpty ? nil : info.clientIdentifier,
            ].compactMap { $0 }.joined(separator: "  ·  ")
            if !meta.isEmpty {
                Text(meta).appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            let ard = info.ardText.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            if !ard.isEmpty {
                Text(ard).appFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(ard)
            }
        } else if !computer.location.isEmpty || !computer.asset.isEmpty {
            Text([computer.location, computer.asset, computer.serial].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .appFont(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let selected = manage.selectedComputerIDs.contains(computer.id) ? manage.selectedComputers : [computer]
        Button("Copy Hostname") { ManageClipboard.copy(computer.displayName) }
        Button("Copy IP Address") { ManageClipboard.copy(manage.ipFor(computer) ?? "") }
            .disabled(manage.ipFor(computer) == nil)
        Button("Copy Serial Number") { ManageClipboard.copy(computer.serial) }
            .disabled(computer.isAdhoc)
        Button("Copy Asset Tag") { ManageClipboard.copy(computer.asset) }
            .disabled(computer.asset.isEmpty)
        if let version = info?.osVersion, !version.isEmpty {
            Button("Copy macOS Version") { ManageClipboard.copy(version) }
        }
        Divider()
        Button("Copy Inventory Line") { ManageClipboard.copy(manage.inventoryLine(for: computer)) }
        if selected.count > 1 {
            Divider()
            Button("Copy Selected Hostnames") { ManageClipboard.copy(selected.map(\.displayName).joined(separator: "\n")) }
            Button("Copy Selected Asset Tags") {
                ManageClipboard.copy(selected.map(\.asset).filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            .disabled(selected.allSatisfy { $0.asset.isEmpty })
            Button("Copy Selected Inventory") {
                ManageClipboard.copy(selected.map { manage.inventoryLine(for: $0) }.joined(separator: "\n"))
            }
        }
        Divider()
        Button("Open SSH") { manage.openSSH(for: computer) }.disabled(!isOnline)
        Button("Open Screen Sharing") { manage.openScreenSharing(for: computer) }.disabled(!isOnline)
        Button("Open Both") { manage.openSSHAndScreenSharing(for: computer) }.disabled(!isOnline)
        Divider()
        Button("Rescan") { Task { await manage.rescan(computer) } }
    }

    private var statusColor: Color {
        if manage.isScanning { return .manageWarning }
        if manage.scanSummary.mode == .unknown { return .secondary }
        return isOnline ? .manageSuccess : .manageFailure
    }

    private func sourceIcon(_ source: AddressSource) -> String {
        switch source {
        case .reportMate: "antenna.radiowaves.left.and.right"
        case .mdns: "bonjour"
        case .stored: "pin"
        case .none: "network"
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

    private func remoteAccessHelp(_ info: MachineInfo) -> String {
        [
            "Remote Login: \(info.sshRemoteLogin.isEmpty ? "unknown" : info.sshRemoteLogin)",
            "SSH port 22: \(info.sshPortListening ? "listening" : "not listening")",
            "Screen Sharing service: \(info.screenSharingState.isEmpty ? "unknown" : info.screenSharingState)",
            "Screen Sharing port 5900: \(info.screenSharingPortListening ? "listening" : "not listening")",
        ].joined(separator: "\n")
    }
}

/// Choose which online machines get a Terminal tab.
struct SSHTabPickerSheet: View {
    @ObservedObject var manage: ManageState
    @Binding var isPresented: Bool
    @State private var selectedIDs: Set<String> = []

    private var onlineComputers: [RosterComputer] {
        manage.currentComputers
            .filter { manage.isOnline($0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open SSH Tabs").appFont(.headline)
                Spacer()
                Text("\(selectedIDs.count) selected").appFont(.caption).foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            List(onlineComputers) { computer in
                Toggle(isOn: Binding(
                    get: { selectedIDs.contains(computer.id) },
                    set: { on in if on { selectedIDs.insert(computer.id) } else { selectedIDs.remove(computer.id) } }
                )) {
                    HStack {
                        Text(computer.displayName).appFont(.body, weight: .medium)
                        Spacer()
                        if let ip = manage.ipFor(computer) {
                            Text(ip).appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()

            HStack {
                Button("All") { selectedIDs = Set(onlineComputers.map(\.id)) }
                Button("None") { selectedIDs = [] }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    manage.openSSHTabs(for: onlineComputers.filter { selectedIDs.contains($0.id) })
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
        .onAppear {
            let preselected = onlineComputers.filter { manage.selectedComputerIDs.contains($0.id) }
            selectedIDs = Set((preselected.isEmpty ? onlineComputers : preselected).map(\.id))
        }
    }
}

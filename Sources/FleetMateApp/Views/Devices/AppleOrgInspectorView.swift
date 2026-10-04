import SwiftUI
import FleetMateCore

// MARK: - Inspector section

/// The device inspector's Apple organization section, shown for a device an
/// organization holds — and, while the organizations are still being read,
/// as a loading row for an Apple device that may turn out to be in one.
struct AppleOrgDetailSection: View {
    @ObservedObject var store: AppleOrgStore
    let row: DeviceListRow

    static func applies(to row: DeviceListRow, store: AppleOrgStore) -> Bool {
        row.apple != nil || (store.hasProfile && store.lastLoaded == nil && row.isApplePlatform)
    }

    var body: some View {
        if row.apple == nil {
            DetailSection(title: store.profiles.count == 1 ? store.label(for: store.profiles[0].name) : "Apple Organization", icon: "apple.logo") {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Reading the Apple organization…").appFont(.caption).foregroundColor(.secondary)
                }
            }
        } else if let device = row.apple {
            VStack(alignment: .leading, spacing: 16) {
                DetailSection(title: store.label(for: device.orgId), icon: "apple.logo") {
                    DeviceDetailRow(label: "Status", value: row.orgStatusLabel)
                    DeviceDetailRow(label: "Management Service", value: row.serverName ?? "None")
                    DeviceDetailRow(label: "Model", value: device.model)
                    DeviceDetailRow(label: "Order", value: device.orderNumber, monospaced: true)
                    DeviceDetailRow(label: "Order Date", value: device.orderDate.map { AppleOrgFormat.date($0) })
                    DeviceDetailRow(label: "Purchase Source", value: device.purchaseSource == nil ? nil : row.purchaseSourceLabel)
                    DeviceDetailRow(label: "Added", value: device.addedToOrg.map { AppleOrgFormat.date($0) })
                    DeviceDetailRow(label: "Released", value: device.releasedFromOrg.map { AppleOrgFormat.date($0) })
                    ForEach(device.wifiMacAddresses, id: \.self) { DeviceDetailRow(label: "Wi-Fi MAC", value: $0, monospaced: true) }
                    ForEach(device.ethernetMacAddresses, id: \.self) { DeviceDetailRow(label: "Ethernet MAC", value: $0, monospaced: true) }
                    DeviceDetailRow(label: "Migration", value: device.migrationStatus == nil ? nil : row.migrationLabel)
                    DeviceDetailRow(label: "Migration Deadline", value: device.migrationDeadline.map { AppleOrgFormat.dateTime($0) })
                    DeviceDetailRow(label: "Migration Capable", value: device.isMigrationCapable.map { $0 ? "Yes" : "No" })
                }

                DetailSection(title: "AppleCare", icon: "cross.case") {
                    appleCare(for: device.serialNumber)
                }
                .task(id: device.serialNumber) { store.loadAppleCare(for: device) }
            }
        }
    }

    @ViewBuilder
    private func appleCare(for serial: String) -> some View {
        switch store.appleCare[serial] {
        case nil:
            HStack {
                ProgressView().scaleEffect(0.6)
                Text("Loading coverage…").appFont(.caption).foregroundColor(.secondary)
            }
        case .failure(let error):
            Text(error.localizedDescription).appFont(.caption).foregroundColor(.secondary)
        case .success(let agreements) where agreements.isEmpty:
            Text("No coverage reported.").appFont(.caption).foregroundColor(.secondary)
        case .success(let agreements):
            ForEach(Array(agreements.enumerated()), id: \.offset) { _, agreement in
                VStack(alignment: .leading, spacing: 1) {
                    Text(agreement.description).appFont(.caption).fontWeight(.medium)
                    Text(coverageLine(agreement))
                        .appFont(.caption2)
                        .foregroundColor(isActive(agreement) ? .green : .secondary)
                }
            }
        }
    }

    private func isActive(_ a: AppleCareAgreement) -> Bool {
        !a.isCanceled && (a.end.map { $0 > Date() } ?? false)
    }

    private func coverageLine(_ a: AppleCareAgreement) -> String {
        var parts: [String] = []
        if a.isCanceled { parts.append("Cancelled") }
        else if let status = a.status { parts.append(status.capitalized) }
        if let end = a.end { parts.append((end > Date() ? "until " : "ended ") + AppleOrgFormat.date(end)) }
        if let n = a.agreementNumber { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Actions

/// An action waiting on the user's confirmation. Unassign is sent once per
/// current service, so one confirmation can carry several submissions.
private struct PendingOrgAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
    let steps: [(AppleOrgAction, [String])]
}

/// The Apple organization's actions in the Device Actions panel. Shown only
/// when one organization holds every selected device — every action names a
/// service, and a service means nothing outside its own organization — and
/// each action only when it applies to every one of them.
struct AppleOrgActionsGroup: View {
    @ObservedObject var store: AppleOrgStore
    let rows: [DeviceListRow]

    @State private var expanded: Set<String> = ["service"]
    @State private var targetServerId: String = ""
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var pending: PendingOrgAction?
    @State private var isRunning = false
    @State private var outcome: (ok: Bool, message: String)?

    private var devices: [AppleOrgDevice] { rows.compactMap(\.apple) }
    private var orgId: String { devices.first?.orgId ?? "" }
    private var orgServers: [AppleOrgServer] { store.servers(in: orgId) }
    private var isSchool: Bool { store.profile(named: orgId)?.isSchool ?? false }
    private var serials: [String] { devices.map(\.serialNumber) }
    private var noneReleased: Bool { devices.allSatisfy { $0.releasedFromOrg == nil } }
    private var canUnassign: Bool { noneReleased && devices.allSatisfy { $0.assignedServerId != nil } }
    private var canSchedule: Bool { noneReleased && devices.allSatisfy { $0.isMigrationCapable == true } }
    private var canChangeMigration: Bool { noneReleased && devices.allSatisfy(\.hasActiveMigration) }
    private var canRelease: Bool { noneReleased && !isSchool }
    private var targetName: String { orgServers.first { $0.id == targetServerId }?.name ?? "" }
    private var deadlineRange: ClosedRange<Date> { Date()...AppleOrgAction.latestDeadline() }

    var body: some View {
        VStack(spacing: 0) {
            if noneReleased {
                ActionAccordion(
                    title: "Assign Management Service",
                    icon: "server.rack",
                    isExpanded: expanded.contains("service"),
                    onToggle: { toggle("service") }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose which \(store.label(for: orgId)) service the device enrolls with. Takes effect at its next enrollment or erase.")
                            .appFont(.caption).foregroundColor(.secondary)
                        servicePicker
                        HStack {
                            Button(action: confirmAssign) {
                                Label("Assign", systemImage: "arrow.right.circle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(targetServerId.isEmpty)
                            if canUnassign {
                                Button(action: confirmUnassign) {
                                    Label("Unassign", systemImage: "minus.circle").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        status
                    }
                }
            }

            if canSchedule || canChangeMigration {
                ActionAccordion(
                    title: "Migrate Management Service",
                    icon: "arrow.left.arrow.right.circle",
                    isExpanded: expanded.contains("migration"),
                    onToggle: { toggle("migration") }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Move to another service without erasing. The device keeps running under its current service until it moves; deadlines are at most \(AppleOrgAction.maxMigrationDays) days out.")
                            .appFont(.caption).foregroundColor(.secondary)
                        if canSchedule { servicePicker }
                        DatePicker("Deadline", selection: $deadline, in: deadlineRange, displayedComponents: [.date, .hourAndMinute])
                            .appFont(.caption)
                        if canSchedule {
                            Button(action: confirmSchedule) {
                                Label("Schedule Migration", systemImage: "calendar.badge.clock").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(targetServerId.isEmpty)
                        }
                        if canChangeMigration {
                            HStack {
                                Button(action: confirmUpdateDeadline) {
                                    Text("Change Deadline").frame(maxWidth: .infinity)
                                }
                                Button(action: confirmCancelMigration) {
                                    Text("Cancel Migration").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        status
                    }
                }
            }

            if canRelease {
                ActionAccordion(
                    title: "Release from Organization",
                    icon: "rectangle.portrait.and.arrow.right",
                    isExpanded: expanded.contains("release"),
                    onToggle: { toggle("release") }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Remove the device from \(store.label(for: orgId)) for good. It stops enrolling automatically.")
                            .appFont(.caption).foregroundColor(.secondary)
                        Button(action: confirmRelease) {
                            Label("Release", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        status
                    }
                }
            }
        }
        .disabled(isRunning)
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button("Cancel", role: .cancel) { }
            Button(action.title, role: action.destructive ? .destructive : nil) { run(action) }
        } message: { action in
            Text(action.message)
        }
        .onChange(of: serials) { _, _ in outcome = nil; targetServerId = "" }
    }

    private func toggle(_ section: String) {
        withAnimation {
            if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        }
    }

    private var servicePicker: some View {
        Picker("Service", selection: $targetServerId) {
            Text("Choose a service…").tag("")
            ForEach(orgServers) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var status: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Waiting for Apple to finish…").appFont(.caption).foregroundColor(.secondary)
            }
        } else if let outcome {
            Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .appFont(.caption)
                .foregroundColor(outcome.ok ? .green : .orange)
        }
    }

    private func count(_ n: Int) -> String { "\(n) device\(n == 1 ? "" : "s")" }

    private func confirmAssign() {
        pending = PendingOrgAction(
            title: "Assign",
            message: "Assign \(count(serials.count)) to \(targetName)? It takes effect at each device's next enrollment or erase.",
            destructive: false,
            steps: [(.assign(serverId: targetServerId), serials)]
        )
    }

    private func confirmUnassign() {
        let groups = Dictionary(grouping: devices, by: { $0.assignedServerId ?? "" }).filter { !$0.key.isEmpty }
        let names = groups.keys.compactMap { id in orgServers.first { $0.id == id }?.name }.sorted()
        pending = PendingOrgAction(
            title: "Unassign",
            message: "Unassign \(count(serials.count)) from \(names.joined(separator: ", "))? They will not enroll automatically until assigned again.",
            destructive: true,
            steps: groups.map { (AppleOrgAction.unassign(serverId: $0.key), $0.value.map(\.serialNumber)) }
        )
    }

    private func confirmSchedule() {
        pending = PendingOrgAction(
            title: "Schedule Migration",
            message: "Migrate \(count(serials.count)) to \(targetName) by \(AppleOrgFormat.dateTime(deadline))? Users are prompted, and the move is enforced on the device at the deadline.",
            destructive: false,
            steps: [(.scheduleMigration(serverId: targetServerId, deadline: deadline), serials)]
        )
    }

    private func confirmUpdateDeadline() {
        let earliest = devices.compactMap(\.migrationDeadline).min()
        let shortening = earliest.map { deadline < $0 } ?? false
        pending = PendingOrgAction(
            title: "Change Deadline",
            message: "Move the migration deadline for \(count(serials.count)) to \(AppleOrgFormat.dateTime(deadline))?"
                + (shortening ? " An earlier deadline applies immediately, without giving users a chance to delay." : ""),
            destructive: shortening,
            steps: [(.updateMigrationDeadline(deadline), serials)]
        )
    }

    private func confirmCancelMigration() {
        pending = PendingOrgAction(
            title: "Cancel Migration",
            message: "Cancel the migration for \(count(serials.count))? They stay on their current service.",
            destructive: true,
            steps: [(.cancelMigration, serials)]
        )
    }

    private func confirmRelease() {
        pending = PendingOrgAction(
            title: "Release",
            message: "Release \(count(serials.count)) from \(store.label(for: orgId))? This cannot be undone: the devices leave the organization and stop enrolling automatically.",
            destructive: true,
            steps: [(.release, serials)]
        )
    }

    private func run(_ action: PendingOrgAction) {
        isRunning = true
        outcome = nil
        Task {
            var failures: [String] = []
            var successes: [String] = []
            for (step, serials) in action.steps where !serials.isEmpty {
                let result = await store.perform(step, serials: serials, in: orgId)
                if result.ok { successes.append(result.message) } else { failures.append(result.message) }
            }
            outcome = failures.isEmpty
                ? (true, successes.joined(separator: " "))
                : (false, failures.joined(separator: " "))
            isRunning = false
        }
    }
}

// MARK: - Formatting

enum AppleOrgFormat {
    static func date(_ date: Date?) -> String {
        guard let date else { return DeviceListRow.missing }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return DeviceListRow.missing }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func isoDate(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return DeviceListRow.missing }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return date(d) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return date(d) }
        return String(iso.prefix(10))
    }
}

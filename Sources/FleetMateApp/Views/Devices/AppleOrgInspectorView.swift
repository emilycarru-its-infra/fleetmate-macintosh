import SwiftUI
import FleetMateCore

/// The Mac view's right-hand panel: the device's Apple and Intune records when
/// one is selected, and the organization actions for any selection.
struct AppleOrgInspectorView: View {
    @ObservedObject var store: AppleOrgStore
    let rows: [AppleOrgRow]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if rows.count == 1, let row = rows.first {
                    AppleOrgDeviceDetail(store: store, row: row)
                } else {
                    Text("\(rows.count) devices selected")
                        .appFont(.title3, weight: .semibold)
                }
                Divider()
                AppleOrgActionsSection(store: store, rows: rows)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Detail

private struct AppleOrgDeviceDetail: View {
    @ObservedObject var store: AppleOrgStore
    let row: AppleOrgRow

    private var device: AppleOrgDevice { row.device }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.intune?.deviceName ?? device.model)
                    .appFont(.title3, weight: .semibold)
                    .textSelection(.enabled)
                Text(device.serialNumber)
                    .appFont(.callout, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            section(store.activeProfile?.serviceName ?? "Apple Organization") {
                field("Status", row.statusLabel)
                field("Service", row.serverName ?? "None")
                field("Model", device.model)
                if let family = device.productFamily { field("Family", family) }
                field("Order", device.orderNumber ?? "—")
                field("Order Date", AppleOrgFormat.date(device.orderDate))
                field("Purchase Source", row.purchaseSourceLabel)
                field("Added", AppleOrgFormat.date(device.addedToOrg))
                if let released = device.releasedFromOrg {
                    field("Released", AppleOrgFormat.date(released))
                }
                ForEach(device.wifiMacAddresses, id: \.self) { field("Wi-Fi MAC", $0, mono: true) }
                ForEach(device.ethernetMacAddresses, id: \.self) { field("Ethernet MAC", $0, mono: true) }
            }

            section("Migration") {
                field("Status", row.migrationLabel)
                if let deadline = device.migrationDeadline {
                    field("Deadline", AppleOrgFormat.dateTime(deadline))
                }
                field("Capable", device.isMigrationCapable.map { $0 ? "Yes" : "No" } ?? "Unknown")
            }

            section("AppleCare") { appleCare }
                .task(id: device.serialNumber) { store.loadAppleCare(serial: device.serialNumber) }

            section("Intune") {
                if let intune = row.intune {
                    field("Name", intune.deviceName ?? "—")
                    field("User", intune.userPrincipalName ?? intune.userDisplayName ?? "—")
                    HStack(alignment: .firstTextBaseline) {
                        Text("Compliance").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        AppleOrgComplianceLabel(row: row)
                    }
                    field("OS", [intune.operatingSystem, intune.osVersion].compactMap { $0 }.joined(separator: " "))
                    field("Enrolled", AppleOrgFormat.isoDate(intune.enrolledDateTime))
                    field("Last Sync", AppleOrgFormat.isoDate(intune.lastSyncDateTime))
                } else {
                    Text("No Intune record has this serial number.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var appleCare: some View {
        switch store.appleCare[device.serialNumber] {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading coverage…").foregroundStyle(.secondary)
            }
        case .failure(let error):
            Text(error.localizedDescription)
                .foregroundStyle(.secondary)
        case .success(let agreements) where agreements.isEmpty:
            Text("No coverage reported.").foregroundStyle(.secondary)
        case .success(let agreements):
            ForEach(Array(agreements.enumerated()), id: \.offset) { _, agreement in
                VStack(alignment: .leading, spacing: 2) {
                    Text(agreement.description).appFont(.body, weight: .medium)
                    Text(coverageLine(agreement))
                        .appFont(.caption)
                        .foregroundStyle(isActive(agreement) ? .green : .secondary)
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(.headline)
            content()
        }
    }

    private func field(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .appFont(.body, design: mono ? .monospaced : .default)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Actions

/// An action waiting on the user's confirmation, with the serials it will
/// actually reach — devices it cannot apply to are dropped up front and named.
private struct PendingOrgAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
    /// One or more submissions: unassign goes once per current service.
    let steps: [(AppleOrgAction, [String])]
}

private struct AppleOrgActionsSection: View {
    @ObservedObject var store: AppleOrgStore
    let rows: [AppleOrgRow]

    @State private var targetServerId: String = ""
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var pending: PendingOrgAction?
    @State private var isRunning = false
    @State private var outcome: (ok: Bool, message: String)?

    private var serials: [String] { rows.map(\.device.serialNumber) }
    private var activeRows: [AppleOrgRow] { rows.filter { $0.device.releasedFromOrg == nil } }
    private var assignedRows: [AppleOrgRow] { activeRows.filter { $0.device.assignedServerId != nil } }
    private var migratingRows: [AppleOrgRow] { activeRows.filter { $0.device.hasActiveMigration } }
    private var migratableRows: [AppleOrgRow] { activeRows.filter { $0.device.isMigrationCapable == true } }
    private var targetName: String { store.servers.first { $0.id == targetServerId }?.name ?? "" }
    private var deadlineRange: ClosedRange<Date> { Date()...AppleOrgAction.latestDeadline() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actions").appFont(.headline)

            GroupBox("Device Management Service") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Service", selection: $targetServerId) {
                        Text("Choose…").tag("")
                        ForEach(store.servers) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    HStack {
                        Button("Assign") { confirmAssign() }
                            .disabled(targetServerId.isEmpty || activeRows.isEmpty)
                        Button("Unassign") { confirmUnassign() }
                            .disabled(assignedRows.isEmpty)
                    }
                    Text("Assignment takes effect at the device's next enrollment or erase.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Migration") {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Deadline", selection: $deadline, in: deadlineRange, displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Button("Schedule") { confirmSchedule() }
                            .disabled(targetServerId.isEmpty || migratableRows.isEmpty)
                            .help("Move to the chosen service without erasing, by the deadline")
                        Button("Change Deadline") { confirmUpdateDeadline() }
                            .disabled(migratingRows.isEmpty)
                        Button("Cancel Migration") { confirmCancelMigration() }
                            .disabled(migratingRows.isEmpty)
                    }
                    Text("No erase: the device keeps running under its current service until it moves. Deadlines are at most \(AppleOrgAction.maxMigrationDays) days out.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if !store.isSchool {
                GroupBox("Organization") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Release from Organization…") { confirmRelease() }
                            .disabled(activeRows.isEmpty)
                        Text("Removes the device from the organization for good. It can only come back through a purchase or Apple Configurator.")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Apple to finish…").foregroundStyle(.secondary)
                }
            } else if let outcome {
                Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.ok ? .green : .orange)
                    .appFont(.callout)
            }
        }
        .disabled(isRunning)
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button("Cancel", role: .cancel) { }
            Button(action.title, role: action.destructive ? .destructive : nil) { run(action) }
        } message: { action in
            Text(action.message)
        }
        .onChange(of: serials) { _, _ in outcome = nil }
    }

    // MARK: Confirmations

    private func count(_ n: Int) -> String { "\(n) device\(n == 1 ? "" : "s")" }

    private func skipped(_ total: Int, _ reached: Int, _ reason: String) -> String {
        total == reached ? "" : " \(count(total - reached)) \(reason) will be skipped."
    }

    private func confirmAssign() {
        let reach = activeRows.map(\.device.serialNumber)
        pending = PendingOrgAction(
            title: "Assign",
            message: "Assign \(count(reach.count)) to \(targetName)? It takes effect at each device's next enrollment or erase.\(skipped(rows.count, reach.count, "already released"))",
            destructive: false,
            steps: [(.assign(serverId: targetServerId), reach)]
        )
    }

    private func confirmUnassign() {
        let groups = Dictionary(grouping: assignedRows, by: { $0.device.assignedServerId! })
        let steps = groups.map { (AppleOrgAction.unassign(serverId: $0.key), $0.value.map(\.device.serialNumber)) }
        let names = groups.keys.compactMap { id in store.servers.first { $0.id == id }?.name }.sorted()
        pending = PendingOrgAction(
            title: "Unassign",
            message: "Unassign \(count(assignedRows.count)) from \(names.joined(separator: ", "))? They will not enroll automatically until assigned again.\(skipped(rows.count, assignedRows.count, "with no service"))",
            destructive: true,
            steps: steps
        )
    }

    private func confirmSchedule() {
        let reach = migratableRows.map(\.device.serialNumber)
        pending = PendingOrgAction(
            title: "Schedule Migration",
            message: "Migrate \(count(reach.count)) to \(targetName) by \(AppleOrgFormat.dateTime(deadline))? Users are prompted, and the move is enforced on the device at the deadline.\(skipped(rows.count, reach.count, "not migration-capable"))",
            destructive: false,
            steps: [(.scheduleMigration(serverId: targetServerId, deadline: deadline), reach)]
        )
    }

    private func confirmUpdateDeadline() {
        let reach = migratingRows.map(\.device.serialNumber)
        let earliest = migratingRows.compactMap(\.device.migrationDeadline).min()
        let shortening = earliest.map { deadline < $0 } ?? false
        pending = PendingOrgAction(
            title: "Change Deadline",
            message: "Move the migration deadline for \(count(reach.count)) to \(AppleOrgFormat.dateTime(deadline))?"
                + (shortening ? " An earlier deadline applies immediately, without giving users a chance to delay." : "")
                + skipped(rows.count, reach.count, "with no migration in progress"),
            destructive: shortening,
            steps: [(.updateMigrationDeadline(deadline), reach)]
        )
    }

    private func confirmCancelMigration() {
        let reach = migratingRows.map(\.device.serialNumber)
        pending = PendingOrgAction(
            title: "Cancel Migration",
            message: "Cancel the migration for \(count(reach.count))? They stay on their current service.\(skipped(rows.count, reach.count, "with no migration in progress"))",
            destructive: true,
            steps: [(.cancelMigration, reach)]
        )
    }

    private func confirmRelease() {
        let reach = activeRows.map(\.device.serialNumber)
        pending = PendingOrgAction(
            title: "Release",
            message: "Release \(count(reach.count)) from the organization? This cannot be undone: the devices leave Apple Business Manager and stop enrolling automatically.",
            destructive: true,
            steps: [(.release, reach)]
        )
    }

    private func run(_ action: PendingOrgAction) {
        isRunning = true
        outcome = nil
        Task {
            var failures: [String] = []
            var successes: [String] = []
            for (step, serials) in action.steps where !serials.isEmpty {
                let result = await store.perform(step, serials: serials)
                (result.ok ? { successes.append(result.message) } : { failures.append(result.message) })()
            }
            outcome = failures.isEmpty
                ? (true, successes.joined(separator: " "))
                : (false, failures.joined(separator: " "))
            isRunning = false
        }
    }
}

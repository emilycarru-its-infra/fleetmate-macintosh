import SwiftUI
import AppKit
import FleetMateCore

/// Everything about one compliance policy on one device, sized like the
/// pull-request lightbox: the per-setting evaluation Graph made for this
/// device, the policy's own requirements and non-compliance actions, and a
/// Copy button that renders it all as a plain-text report for a ticket.
struct CompliancePolicyLightboxView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let device: IntuneDevice
    let policy: DeviceCompliancePolicyState

    @State private var settings: [CompliancePolicySettingState] = []
    @State private var definition: CompliancePolicyDefinition?
    @State private var settingsError: String?
    @State private var definitionError: String?
    @State private var isLoading = true
    @State private var copied = false
    @State private var syncState: SyncState = .idle

    private enum SyncState { case idle, running, done, failed(String) }

    /// Same sizing rule as the other lightboxes: ~80% of the host window.
    private let sheetSize: CGSize = {
        let host = NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .max(by: { $0.frame.width < $1.frame.width })
        let size = host?.frame.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: max(860, size.width * 0.8), height: max(560, size.height * 0.8))
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer()
                ProgressView("Loading policy details…")
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            settingsSection
                            requirementsSection
                        }
                        .padding(18)
                    }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            deviceSection
                            actionsSection
                            assignmentsSection
                        }
                        .padding(18)
                    }
                    .frame(width: 340)
                }
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: stateIcon(policy.state))
                .foregroundStyle(stateColor(policy.state))
                .appFont(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(policy.displayName ?? "Compliance Policy")
                    .appFont(.title3, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StateCapsule(text: (policy.state ?? "unknown").capitalized, color: stateColor(policy.state))
                    if let platform = policy.platformType { Text(platform).appFont(.caption).foregroundStyle(.secondary) }
                    if let version = policy.version { Text("v\(version)").appFont(.caption).foregroundStyle(.secondary) }
                    Text(device.deviceName ?? device.id).appFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                copyReport()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy a plain-text report of this policy on this device")
            Button {
                Task { await sync() }
            } label: {
                switch syncState {
                case .running: Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                case .done: Label("Sync requested", systemImage: "checkmark")
                default: Label("Sync device", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled({ if case .running = syncState { return true } else { return false } }())
            .help("Ask Intune to sync this device now")
            Button {
                if let url = URL(string: intuneURL) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "globe")
            }
            .help("Open the device's compliance page in Intune")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .appFont(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: Sections

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Settings evaluated on this device", icon: "list.bullet.rectangle",
                         trailing: settings.isEmpty ? nil : "\(failingSettings.count) failing · \(settings.count) total")
            if let settingsError {
                errorRow(settingsError)
            } else if settings.isEmpty {
                Text("Graph returned no per-setting states for this policy.")
                    .appFont(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sortedSettings) { setting in
                    SettingRow(setting: setting, color: stateColor(setting.state), icon: stateIcon(setting.state))
                }
            }
        }
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What the policy requires", icon: "checklist")
            if let definitionError {
                errorRow(definitionError)
            } else if let definition {
                if let desc = definition.description, !desc.isEmpty {
                    Text(desc).appFont(.caption).foregroundStyle(.secondary)
                }
                if definition.requirements.isEmpty {
                    Text("No requirement values reported.").appFont(.caption).foregroundStyle(.secondary)
                }
                ForEach(definition.requirements, id: \.label) { req in
                    HStack(alignment: .top) {
                        Text(req.label).appFont(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                        Text(req.value).appFont(.caption).textSelection(.enabled)
                        Spacer()
                    }
                }
                if let type = definition.odataType {
                    Text(type.replacingOccurrences(of: "#microsoft.graph.", with: ""))
                        .appFont(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Device", icon: "laptopcomputer")
            infoRow("Name", device.deviceName)
            infoRow("Serial", device.serialNumber, mono: true)
            infoRow("User", device.userPrincipalName ?? device.userDisplayName)
            infoRow("OS", [device.operatingSystem, device.osVersion].compactMap { $0 }.joined(separator: " "))
            infoRow("Overall compliance", device.complianceState?.capitalized)
            infoRow("Last check-in", formatted(device.lastSyncDateTime))
            infoRow("Enrolled", formatted(device.enrolledDateTime))
            infoRow("Intune ID", device.id, mono: true)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Actions for non-compliance", icon: "clock.badge.exclamationmark")
            if let definition, !definition.scheduledActions.isEmpty {
                ForEach(Array(definition.scheduledActions.enumerated()), id: \.offset) { _, action in
                    HStack(alignment: .top, spacing: 6) {
                        Text(actionLabel(action.actionType)).appFont(.caption)
                        Spacer()
                        Text(graceLabel(action.gracePeriodHours)).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if definition != nil {
                Text("No scheduled actions.").appFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not loaded.").appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var assignmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Assigned to", icon: "person.3")
            if let definition, !definition.assignments.isEmpty {
                ForEach(Array(definition.assignments.enumerated()), id: \.offset) { _, assignment in
                    HStack(spacing: 6) {
                        Text(assignmentLabel(assignment)).appFont(.caption)
                        Spacer()
                        if let id = assignment.groupId {
                            Text(id).appFont(.caption2, design: .monospaced).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if let modified = definition.lastModifiedDateTime {
                    Text("Policy last modified \(formatted(modified) ?? modified)")
                        .appFont(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
            } else if definition != nil {
                Text("No assignments.").appFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not loaded.").appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String, icon: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).appFont(.caption)
            Text(title).appFont(.subheadline, weight: .semibold)
            Spacer()
            if let trailing { Text(trailing).appFont(.caption).foregroundStyle(.secondary) }
        }
    }

    private func infoRow(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        Group {
            if let value, !value.isEmpty {
                HStack(alignment: .top) {
                    Text(label).appFont(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    Text(value).appFont(.caption, design: mono ? .monospaced : .default).textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).appFont(.caption)
            Text(message).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private struct StateCapsule: View {
        let text: String
        let color: Color
        var body: some View {
            Text(text)
                .appFont(.caption2, weight: .semibold)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
    }

    private struct SettingRow: View {
        let setting: CompliancePolicySettingState
        let color: Color
        let icon: String
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).appFont(.caption).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(setting.displayName).appFont(.caption, weight: .medium).textSelection(.enabled)
                        Spacer()
                        Text((setting.state ?? "unknown").capitalized).appFont(.caption2).foregroundStyle(color)
                    }
                    if let value = setting.currentValue, !value.isEmpty {
                        Text("Current value: \(value)").appFont(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let err = setting.errorText {
                        Text(err).appFont(.caption2).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let sources = setting.sources, !sources.isEmpty {
                        Text("From " + sources.compactMap { $0.displayName }.joined(separator: ", "))
                            .appFont(.caption2).foregroundStyle(.tertiary)
                    }
                    if let user = setting.userPrincipalName ?? setting.userName, !user.isEmpty {
                        Text(user).appFont(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(8)
            .background(setting.severityRank <= 2 ? color.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
    }

    // MARK: Data

    private var sortedSettings: [CompliancePolicySettingState] {
        settings.sorted {
            if $0.severityRank != $1.severityRank { return $0.severityRank < $1.severityRank }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var failingSettings: [CompliancePolicySettingState] {
        settings.filter { $0.severityRank <= 2 }
    }

    private var intuneURL: String {
        "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/compliance/mdmDeviceId/\(device.id)"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let policyId = policy.id else {
            settingsError = "This policy state has no id, so Graph cannot be asked for its settings."
            return
        }
        async let settingsTask: Result<[CompliancePolicySettingState], Error> = {
            do { return .success(try await appState.graphService.getCompliancePolicySettingStates(deviceId: device.id, policyId: policyId)) }
            catch { return .failure(error) }
        }()
        async let definitionTask: Result<CompliancePolicyDefinition, Error> = {
            do { return .success(try await appState.graphService.getCompliancePolicyDefinition(policyId: policyId)) }
            catch { return .failure(error) }
        }()
        switch await settingsTask {
        case .success(let value): settings = value
        case .failure(let error): settingsError = "Could not load setting states: \(error.localizedDescription)"
        }
        switch await definitionTask {
        case .success(let value): definition = value
        case .failure(let error): definitionError = "Could not load the policy definition: \(error.localizedDescription)"
        }
    }

    private func sync() async {
        syncState = .running
        do {
            let results = try await appState.graphService.syncDevices([device.id])
            if let failure = results.first(where: { !$0.success }) {
                syncState = .failed(failure.error ?? "Sync failed")
            } else {
                syncState = .done
            }
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    // MARK: Copy

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }

    private var report: String {
        var lines: [String] = []
        lines.append("Compliance policy: \(policy.displayName ?? "Unknown") — \((policy.state ?? "unknown").capitalized)")
        if let platform = policy.platformType { lines.append("Platform: \(platform)") }
        if let version = policy.version { lines.append("Policy version: \(version)") }
        lines.append("")
        lines.append("Device: \(device.deviceName ?? device.id)")
        if let serial = device.serialNumber { lines.append("Serial: \(serial)") }
        if let user = device.userPrincipalName ?? device.userDisplayName { lines.append("User: \(user)") }
        let os = [device.operatingSystem, device.osVersion].compactMap { $0 }.joined(separator: " ")
        if !os.isEmpty { lines.append("OS: \(os)") }
        if let overall = device.complianceState { lines.append("Overall compliance: \(overall.capitalized)") }
        if let sync = formatted(device.lastSyncDateTime) { lines.append("Last check-in: \(sync)") }
        lines.append("Intune ID: \(device.id)")
        lines.append("")
        lines.append("Settings (\(failingSettings.count) failing of \(settings.count)):")
        if settings.isEmpty { lines.append("  none reported") }
        for setting in sortedSettings {
            var line = "  [\((setting.state ?? "unknown").capitalized)] \(setting.displayName)"
            if let value = setting.currentValue, !value.isEmpty { line += " — current: \(value)" }
            if let err = setting.errorText { line += " — \(err)" }
            lines.append(line)
        }
        if let definition {
            lines.append("")
            lines.append("Requirements:")
            for req in definition.requirements { lines.append("  \(req.label): \(req.value)") }
            if !definition.scheduledActions.isEmpty {
                lines.append("")
                lines.append("Actions for non-compliance:")
                for action in definition.scheduledActions {
                    lines.append("  \(actionLabel(action.actionType)) — \(graceLabel(action.gracePeriodHours))")
                }
            }
            if !definition.assignments.isEmpty {
                lines.append("")
                lines.append("Assigned to:")
                for a in definition.assignments { lines.append("  \(assignmentLabel(a))\(a.groupId.map { " (\($0))" } ?? "")") }
            }
        }
        lines.append("")
        lines.append("Intune: \(intuneURL)")
        return lines.joined(separator: "\n")
    }

    // MARK: Labels

    private func stateIcon(_ state: String?) -> String {
        switch state?.lowercased() {
        case "compliant": return "checkmark.circle.fill"
        case "noncompliant": return "xmark.circle.fill"
        case "error": return "exclamationmark.octagon.fill"
        case "conflict": return "exclamationmark.triangle.fill"
        case "notapplicable": return "minus.circle"
        default: return "questionmark.circle"
        }
    }

    private func stateColor(_ state: String?) -> Color {
        switch state?.lowercased() {
        case "compliant": return .green
        case "noncompliant", "error": return .red
        case "conflict": return .orange
        case "notapplicable": return .secondary
        default: return .gray
        }
    }

    private func actionLabel(_ type: String?) -> String {
        switch type {
        case "block": return "Mark device non-compliant"
        case "notification": return "Email the user"
        case "retire": return "Retire the device"
        case "wipe": return "Wipe the device"
        case "remoteLock": return "Remote lock"
        case "pushNotification": return "Push notification"
        case "removeResourceAccessProfiles": return "Remove resource access profiles"
        default: return type ?? "Action"
        }
    }

    private func graceLabel(_ hours: Int?) -> String {
        guard let hours, hours > 0 else { return "immediately" }
        if hours % 24 == 0 { let d = hours / 24; return "after \(d) day\(d == 1 ? "" : "s")" }
        return "after \(hours) hour\(hours == 1 ? "" : "s")"
    }

    private func assignmentLabel(_ a: CompliancePolicyDefinition.Assignment) -> String {
        switch a.targetType {
        case "allDevicesAssignmentTarget": return "All devices"
        case "allLicensedUsersAssignmentTarget": return "All users"
        case "groupAssignmentTarget": return "Group"
        case "exclusionGroupAssignmentTarget": return "Excluded group"
        default: return a.targetType ?? "Target"
        }
    }

    private func formatted(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? { parser.formatOptions = [.withInternetDateTime]; return parser.date(from: iso) }()
        guard let date else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

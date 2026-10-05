import SwiftUI
import UniformTypeIdentifiers
import FleetMateCore

// MARK: - Inspector section

/// The device inspector's Windows Autopilot section, shown only for a device
/// with an Autopilot identity.
struct AutopilotDetailSection: View {
    let identity: WindowsAutopilotDevice
    let registration: AutopilotRegistration?

    var body: some View {
        DetailSection(title: "Windows Autopilot", icon: "shippingbox") {
            DeviceDetailRow(label: "Registration", value: registration?.rawValue)
            DeviceDetailRow(label: "Group Tag", value: identity.groupTagLabel)
            DeviceDetailRow(label: "Deployment Profile", value: identity.profileStatusLabel)
            DeviceDetailRow(label: "Profile Assigned", value: identity.deploymentProfileAssignedDateTime.map(AppleOrgFormat.isoDate))
            DeviceDetailRow(label: "Enrollment State", value: identity.enrollmentStateLabel)
            DeviceDetailRow(label: "Last Contacted", value: identity.lastContactedDateTime.map(AppleOrgFormat.isoDate))
            DeviceDetailRow(label: "Assigned User", value: identity.userPrincipalName)
            DeviceDetailRow(label: "Purchase Order", value: identity.purchaseOrderIdentifier)
            DeviceDetailRow(label: "Manufacturer", value: identity.manufacturer)
            DeviceDetailRow(label: "Model", value: identity.model)
            DeviceDetailRow(label: "Entra Device ID", value: identity.azureActiveDirectoryDeviceId, monospaced: true)
        }
    }
}

// MARK: - Actions

private struct PendingAutopilotAction: Identifiable {
    let id = UUID()
    let action: AutopilotAction
    let message: String
    let destructive: Bool
}

/// Autopilot's actions in the Device Actions panel, after Intune's. Shown
/// only when every selected device has an Autopilot identity, and each card
/// only when its action applies to every one of them.
struct AutopilotActionsGroup: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AutopilotStore
    let rows: [DeviceListRow]

    @State private var expanded: Set<String> = ["groupTag"]
    @State private var groupTag = ""
    @State private var userPrincipalName = ""
    @State private var pending: PendingAutopilotAction?
    @State private var isRunning = false
    @State private var outcome: (ok: Bool, message: String)?

    /// Every selected device has an identity.
    static func applies(to rows: [DeviceListRow]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.autopilot != nil }
    }

    private var identities: [WindowsAutopilotDevice] { rows.compactMap(\.autopilot) }
    private func available(_ action: AutopilotAction) -> Bool { action.isAvailable(for: rows.map(\.autopilot)) }
    private var trimmedTag: String { groupTag.trimmingCharacters(in: .whitespaces) }
    private var trimmedUser: String { userPrincipalName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            if available(.setGroupTag("")) {
                ActionAccordion(title: "Set Group Tag", icon: "tag", isExpanded: expanded.contains("groupTag"),
                                onToggle: { toggle("groupTag") }) {
                    Text("The group tag decides which dynamic groups, and so which deployment profile, the device lands in.")
                        .appFont(.caption).foregroundColor(.secondary)
                    TextField(currentTagPlaceholder, text: $groupTag)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        confirm(.setGroupTag(trimmedTag),
                                "Set the group tag of \(count) to \(trimmedTag.isEmpty ? "nothing (clear it)" : "“\(trimmedTag)”")? Profile assignment follows once Autopilot syncs.")
                    } label: {
                        Label("Set Group Tag", systemImage: "tag").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    status
                }
            }

            if available(.assignUser("")) {
                ActionAccordion(title: "Assign User", icon: "person.crop.circle.badge.plus", isExpanded: expanded.contains("user"),
                                onToggle: { toggle("user") }) {
                    Text("Pre-fills the account at the out-of-box sign-in.")
                        .appFont(.caption).foregroundColor(.secondary)
                    TextField("user@example.com", text: $userPrincipalName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            confirm(.assignUser(trimmedUser), "Assign \(trimmedUser) to \(count)?")
                        } label: {
                            Label("Assign", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!trimmedUser.contains("@"))
                        if available(.unassignUser) {
                            Button {
                                confirm(.unassignUser, "Remove the assigned user from \(count)?")
                            } label: {
                                Label("Unassign", systemImage: "person.badge.minus").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    status
                }
            }

            ActionAccordion(title: "Sync Autopilot", icon: "arrow.triangle.2.circlepath", isExpanded: expanded.contains("sync"),
                            onToggle: { toggle("sync") }) {
                Text("Asks Autopilot to sync with Intune now, so imports and group tag changes reach profile assignment sooner. Intune allows one sync every ten minutes.")
                    .appFont(.caption).foregroundColor(.secondary)
                Button(action: sync) {
                    Label("Sync Autopilot", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                status
            }

            if available(.delete) {
                ActionAccordion(title: "Delete Autopilot Identity", icon: "trash", isExpanded: expanded.contains("delete"),
                                onToggle: { toggle("delete") }) {
                    Text("Releases the hardware from this tenant: it will not run Autopilot again until its hash is imported again. The Intune and Entra records are not touched.")
                        .appFont(.caption).foregroundColor(.secondary)
                    Button {
                        confirm(.delete, "Delete the Autopilot identity of \(count)? This cannot be undone; the hardware hash has to be imported again to bring it back.", destructive: true)
                    } label: {
                        Label("Delete Identity…", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    status
                }
            }
        }
        .disabled(isRunning)
        .alert(pending?.action.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            Button("Cancel", role: .cancel) { }
            Button(item.action.title, role: item.destructive ? .destructive : nil) { run(item.action) }
        } message: { item in
            Text(item.message)
        }
        .onChange(of: rows.map(\.id)) { _, _ in outcome = nil; groupTag = ""; userPrincipalName = "" }
    }

    private var count: String {
        let n = identities.count
        return "\(n) device\(n == 1 ? "" : "s")"
    }

    private var currentTagPlaceholder: String {
        let tags = Set(identities.map(\.groupTagLabel))
        return tags.count == 1 ? tags.first! : "Group tag"
    }

    @ViewBuilder
    private var status: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Working…").appFont(.caption).foregroundColor(.secondary)
            }
        } else if let outcome {
            Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .appFont(.caption)
                .foregroundColor(outcome.ok ? .green : .orange)
        }
    }

    private func toggle(_ section: String) {
        withAnimation {
            if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        }
    }

    private func confirm(_ action: AutopilotAction, _ message: String, destructive: Bool = false) {
        pending = PendingAutopilotAction(action: action, message: message, destructive: destructive)
    }

    private func run(_ action: AutopilotAction) {
        isRunning = true
        outcome = nil
        let targets = identities
        Task {
            outcome = await store.perform(action, on: targets, using: appState.graphService)
            isRunning = false
        }
    }

    private func sync() {
        isRunning = true
        outcome = nil
        Task {
            outcome = await store.sync(using: appState.graphService)
            isRunning = false
        }
    }
}

// MARK: - Hardware hash import

/// Import hardware hashes from a CSV such as `Get-WindowsAutopilotInfo`
/// writes. The sheet is the confirmation: it lists what will be sent, and
/// what was skipped and why, before anything goes to Intune.
struct AutopilotImportSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AutopilotStore
    @Environment(\.dismiss) private var dismiss

    @State private var fileName: String?
    @State private var parsed: AutopilotHashCSV?
    @State private var parseError: String?
    @State private var groupTag = ""
    @State private var showImporter = false
    @State private var outcome: (ok: Bool, message: String)?

    private var entries: [AutopilotHashEntry] {
        let tag = groupTag.trimmingCharacters(in: .whitespaces)
        return (parsed?.entries ?? []).map { $0.withGroupTag(tag) }
    }

    private var canImport: Bool {
        !entries.isEmpty && entries.count <= AutopilotHashCSV.maxEntries && !store.isImporting && outcome == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Hardware Hashes", systemImage: "square.and.arrow.down")
                .appFont(.headline)
            Text("Registers devices with Windows Autopilot from a CSV with Device Serial Number and Hardware Hash columns, as Get-WindowsAutopilotInfo writes it. At most \(AutopilotHashCSV.maxEntries) devices per import.")
                .appFont(.caption).foregroundColor(.secondary)

            HStack {
                Button(fileName == nil ? "Choose CSV…" : "Choose Another…") { showImporter = true }
                if let fileName {
                    Text(fileName).appFont(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle").foregroundColor(.orange).appFont(.caption)
            }

            if let parsed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(parsed.entries.count) device\(parsed.entries.count == 1 ? "" : "s") ready to import")
                        .appFont(.subheadline).fontWeight(.medium)
                    TextField("Group tag for every device (optional; otherwise the file's)", text: $groupTag)
                        .textFieldStyle(.roundedBorder)
                    if !parsed.issues.isEmpty {
                        Text("Skipped")
                            .appFont(.caption).fontWeight(.medium).foregroundColor(.orange)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(parsed.issues, id: \.self) { issue in
                                    Text(issue.line > 0 ? "Line \(issue.line): \(issue.message)" : issue.message)
                                        .appFont(.caption).foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }

            if store.isImporting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    let done = store.importProgress.filter(\.isFinished).count
                    Text("Intune is processing the import (\(done) of \(store.importProgress.count) finished)…")
                        .appFont(.caption).foregroundColor(.secondary)
                }
            } else if let outcome {
                Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundColor(outcome.ok ? .green : .orange)
            }

            HStack {
                Spacer()
                Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isImporting)
                Button("Import \(entries.count) Device\(entries.count == 1 ? "" : "s")") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            load(result)
        }
        .interactiveDismissDisabled(store.isImporting)
    }

    private func load(_ result: Result<URL, Error>) {
        parsed = nil
        parseError = nil
        outcome = nil
        switch result {
        case .failure(let error):
            parseError = error.localizedDescription
        case .success(let url):
            fileName = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                parsed = try AutopilotHashCSV.parse(data: try Data(contentsOf: url))
            } catch {
                parseError = error.localizedDescription
            }
        }
    }

    private func runImport() {
        let toSend = entries
        Task {
            outcome = await store.importHashes(toSend, using: appState.graphService)
        }
    }
}

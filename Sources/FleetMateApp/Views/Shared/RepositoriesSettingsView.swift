import SwiftUI
import AppKit
import FleetMateCore

/// Backs Settings › Repositories: the provider catalog joined with local
/// checkouts, and the clone and scan locations. Everything goes through the
/// same `RepoManager` and registry file as `fleetmate repos`.
@MainActor
final class RepositoriesSettingsModel: ObservableObject {
    let manager = RepoManager()

    @Published private(set) var records: [RepoRecord] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var providerErrors: [String] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var discoverySummary: String?
    /// Repository ids being cloned or located, and the inline error of each.
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published var settings = RepoSettings.default
    @Published private(set) var savedSettings = RepoSettings.default
    @Published var error: String?

    func load() {
        do {
            settings = try manager.settings()
            savedSettings = settings
            reloadRecords()
        } catch {
            self.error = message(error)
        }
        let cached = manager.cachedCatalog()
        fetchedAt = cached?.fetchedAt
        providerErrors = cached?.errors ?? []
    }

    private func reloadRecords() {
        do {
            records = try manager.records()
        } catch {
            self.error = message(error)
        }
    }

    private func registryChanged() {
        reloadRecords()
        NotificationCenter.default.post(name: .repoRegistryChanged, object: nil)
    }

    // MARK: Catalog

    func refreshCatalog(appState: AppState) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let service = Self.catalogService(appState: appState, settings: settings)
        do {
            let catalog = try await manager.refreshCatalog(using: service)
            providerErrors = catalog.errors
            fetchedAt = catalog.fetchedAt
            registryChanged()
        } catch {
            self.error = message(error)
        }
    }

    /// The catalog for the signed-in person: Azure DevOps through the app's
    /// own token (never an interactive prompt), GitHub through config, the
    /// `gh` CLI or the environment.
    static func catalogService(appState: AppState, settings: RepoSettings) -> RepoCatalogService {
        let config = appState.config
        let organization = config.tasks?.providers.azdevops?.organization ?? config.devopsOrganization
        let azure = (organization?.isEmpty == false) ? appState.devOpsService : nil
        let gitHub = config.tasks?.providers.github
        let owners = settings.gitHubOwners + [gitHub?.owner, gitHub?.organization].compactMap { $0 }
        return RepoCatalogService(
            azureDevOps: azure,
            azureDevOpsOrganization: organization,
            gitHubToken: RepoCatalogService.gitHubTokenProvider(config: gitHub),
            gitHubOwners: owners
        )
    }

    // MARK: Rows

    func setTracked(_ record: RepoRecord, _ tracked: Bool) {
        do {
            _ = try manager.setTracked(record.id, tracked)
            registryChanged()
        } catch {
            rowErrors[record.id] = message(error)
        }
    }

    func clone(_ record: RepoRecord) async {
        busy.insert(record.id)
        rowErrors[record.id] = nil
        defer { busy.remove(record.id) }
        do {
            try await manager.clone(record.id)
            registryChanged()
        } catch {
            rowErrors[record.id] = message(error)
        }
    }

    /// Points a catalog repository at a checkout already on disk. The folder's
    /// origin must name the same repository, or the link is refused.
    func locate(_ record: RepoRecord) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose the checkout of \(record.key.displayName)"
        panel.directoryURL = URL(fileURLWithPath: RepoSettings.expand(settings.cloneRoot))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy.insert(record.id)
        rowErrors[record.id] = nil
        defer { busy.remove(record.id) }
        do {
            try await manager.link(path: url.path, to: record.id, tracked: true)
            registryChanged()
        } catch {
            rowErrors[record.id] = message(error)
        }
    }

    /// Links any checkout by its origin, catalog or not.
    func linkFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Choose one or more git checkouts"
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            do {
                try await manager.link(path: url.path, tracked: true)
            } catch {
                failures.append(message(error))
            }
        }
        registryChanged()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func unlink(_ record: RepoRecord) {
        do {
            try manager.unlink(record.id)
            rowErrors[record.id] = nil
            registryChanged()
        } catch {
            rowErrors[record.id] = message(error)
        }
    }

    // MARK: Discovery and locations

    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let results = try await manager.discover(track: false, settings: settings)
            let linked = results.filter { $0.action == .linked }.count
            let existing = results.filter { $0.action == .alreadyLinked }.count
            let duplicates = results.filter { $0.action == .duplicate }.count
            var parts = ["Linked \(linked) new", "\(existing) already linked"]
            if duplicates > 0 { parts.append("\(duplicates) second copies left alone") }
            discoverySummary = parts.joined(separator: " · ")
            registryChanged()
        } catch {
            self.error = message(error)
        }
    }

    func saveSettings() {
        let updated = settings
        do {
            try manager.updateSettings { $0 = updated }
            savedSettings = updated
        } catch {
            self.error = message(error)
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Settings › Repositories: every Azure DevOps and GitHub repository the
/// person can see, where each lives on this Mac, and which are tracked.
struct RepositoriesSettingsView: View {
    /// The Settings tab tag, so other views can open Settings here.
    static let tabTag = 5

    @EnvironmentObject var appState: AppState
    @StateObject private var model = RepositoriesSettingsModel()
    @State private var query = ""
    @State private var newScanRoot = ""

    var body: some View {
        Form {
            locationsSection
            catalogHeaderSection
            let groups = RepoRecordGroup.groups(model.records, matching: query)
            if groups.isEmpty {
                Section {
                    Text(model.records.isEmpty
                         ? "No repositories yet. Refresh the catalog, find existing clones, or link a folder."
                         : "No repositories match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        RepositorySettingsRow(record: record, model: model)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
        .actionErrorBanner($model.error)
    }

    private var locationsSection: some View {
        Section {
            LabeledContent("Clone into") {
                HStack {
                    TextField("", text: $model.settings.cloneRoot, prompt: Text("~/Developer"))
                        .labelsHidden()
                    Button("Choose…") {
                        if let path = chooseFolder() { model.settings.cloneRoot = path }
                    }
                }
            }
            ForEach(model.settings.scanRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(root).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        model.settings.scanRoots.removeAll { $0 == root }
                    } label: {
                        Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Folder to scan for clones", text: $newScanRoot)
                    .onSubmit(addScanRoot)
                Button("Add", action: addScanRoot)
                    .disabled(newScanRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose…") {
                    if let path = chooseFolder(), !model.settings.scanRoots.contains(path) {
                        model.settings.scanRoots.append(path)
                    }
                }
            }
            HStack {
                Button {
                    Task { await model.discover() }
                } label: {
                    Label("Find Existing Clones", systemImage: "magnifyingglass")
                }
                .disabled(model.isDiscovering || model.settings.scanRoots.isEmpty)
                Button {
                    Task { await model.linkFolder() }
                } label: {
                    Label("Link Folder…", systemImage: "link")
                }
                if model.isDiscovering { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save") { model.saveSettings() }
                    .disabled(model.settings == model.savedSettings)
            }
            if let summary = model.discoverySummary {
                Text(summary).appFont(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Locations")
        } footer: {
            Text("New clones go to <clone root>/AzDevOps/<Project>/<Repo> or <clone root>/GitHub/<owner>/<repo>. Finding clones scans the folders above \(model.settings.scanDepth) levels deep and links each checkout by its origin. The same settings drive `fleetmate repos`.")
                .settingsFooter()
        }
    }

    private var catalogHeaderSection: some View {
        Section {
            HStack {
                TextField("Search repositories", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await model.refreshCatalog(appState: appState) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
            ForEach(model.providerErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Catalog")
        } footer: {
            Text(catalogFooter).settingsFooter()
        }
    }

    private var catalogFooter: String {
        let local = model.records.filter(\.isLocal).count
        let tracked = model.records.filter(\.isTracked).count
        var text = "\(model.records.count) repositories, \(local) on this Mac, \(tracked) tracked. Tracked repositories appear in Development › Repos."
        if let fetchedAt = model.fetchedAt {
            text += " Catalog updated \(DevelopmentView.relative(fetchedAt))."
        }
        return text
    }

    private func addScanRoot() {
        let value = newScanRoot.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !model.settings.scanRoots.contains(value) else { return }
        model.settings.scanRoots.append(value)
        newScanRoot = ""
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return repoAbbreviatedPath(url.path)
    }
}

private struct RepositorySettingsRow: View {
    let record: RepoRecord
    @ObservedObject var model: RepositoriesSettingsModel

    private var isBusy: Bool { model.busy.contains(record.id) }
    private var localExists: Bool {
        guard let path = record.local?.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.key.name).appFont(.body, weight: .medium).lineLimit(1)
                        if record.catalog?.isArchived == true { tag("archived") }
                        if record.catalog?.isFork == true { tag("fork") }
                        if record.catalog == nil { tag("not in catalog") }
                    }
                    if let local = record.local {
                        Text(repoAbbreviatedPath(local.path) + (localExists ? "" : " (missing)"))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not on this Mac").appFont(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(record.isLocal ? "Linking…" : "Cloning…").appFont(.caption).foregroundStyle(.secondary)
                } else if record.isLocal {
                    Button {
                        if let path = record.local?.path {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!localExists)
                    .help("Reveal in Finder")
                    Button("Unlink") { model.unlink(record) }
                        .help("Forget this checkout. The folder stays on disk.")
                } else {
                    Button("Clone") { Task { await model.clone(record) } }
                        .disabled(record.catalog == nil)
                        .help("Clone into the default layout under the clone root")
                    Button("Locate…") { Task { await model.locate(record) } }
                        .help("Point at a checkout already on disk")
                }
                Toggle("Track", isOn: Binding(
                    get: { record.isTracked },
                    set: { model.setTracked(record, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!record.isLocal || isBusy)
                .help(record.isLocal ? "Tracked repositories appear in Development › Repos" : "Clone or locate it first")
            }
            .controlSize(.small)
            if let error = model.rowErrors[record.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .appFont(fixed: 10)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.12), in: Capsule())
    }
}

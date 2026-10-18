import SwiftUI
import AppKit
import FleetMateCore

/// "Where do you keep your code?" Pick one or more folders; every clone in
/// them is listed, grouped the way the Repos sidebar groups them, and all of
/// them are tracked unless unticked. Cloning catalog repositories that are
/// not on this Mac yet is offered, never preselected.
struct OnboardingRepositoriesStep: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: OnboardingWizardState

    @State private var catalogFilter = ""
    @State private var loadingCatalog = false
    @State private var catalogError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where do you keep your code?")
                    .appFont(.title2, weight: .bold)
                Text("FleetMate tracks the git clones in these folders and picks up new ones as you clone them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                foldersSection
                clonesSections
                catalogSection
            }
            .formStyle(.grouped)
        }
        .task {
            wizardState.prepareRepoRoots()
            await wizardState.scanRepoRoots()
        }
    }

    // MARK: Folders

    private var foldersSection: some View {
        Section {
            ForEach(wizardState.repoRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(root).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        wizardState.repoRoots.removeAll { $0 == root }
                        Task { await wizardState.scanRepoRoots() }
                    } label: {
                        Label("Remove \(root)", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop looking in this folder")
                }
            }
            HStack {
                Button("Add Folder…") { addFolders() }
                if wizardState.isScanningRepos {
                    ProgressView().controlSize(.small)
                    Text("Looking for clones…").appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text("Folders")
        } footer: {
            if wizardState.repoRoots.isEmpty {
                Text("Add the folder that holds your clones, or skip this and choose one later from Development › Repos.")
                    .settingsFooter()
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folders where you keep your code"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let root = RepoSettings.abbreviate(url.path)
            if !wizardState.repoRoots.contains(root) { wizardState.repoRoots.append(root) }
        }
        Task { await wizardState.scanRepoRoots() }
    }

    // MARK: Clones found

    @ViewBuilder
    private var clonesSections: some View {
        let sections = RepoSidebarOrganizer.sections(wizardState.previewRecords, statuses: [:], sort: .name)
        if sections.isEmpty, !wizardState.isScanningRepos, !wizardState.repoRoots.isEmpty {
            Section("Clones") {
                Text("No git clones in these folders yet.").foregroundStyle(.secondary)
            }
        }
        ForEach(sections) { section in
            Section {
                ForEach(section.groups) { group in
                    DisclosureGroup {
                        ForEach(group.records) { record in
                            Toggle(isOn: wizardState.selection(for: record)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(record.key.name)
                                        if wizardState.isFromWorkspace(record) {
                                            Text("from a VS Code workspace")
                                                .appFont(fixed: 10).foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.secondary.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    if let path = record.local?.path {
                                        Text(repoAbbreviatedPath(path))
                                            .appFont(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    } label: {
                        Toggle(isOn: wizardState.selection(forGroup: group.records)) {
                            Label("\(group.scope) (\(group.records.count))", systemImage: "folder")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text(section.title)
            } footer: {
                if section.id == sections.last?.id {
                    Text("\(wizardState.selectedPreviewCount) of \(wizardState.previewRecords.count) will be tracked. Untick any you do not work in; they will not be added later either.")
                        .settingsFooter()
                }
            }
        }
    }

    // MARK: Catalog

    private var catalogSection: some View {
        Section {
            let missing = wizardState.missingCatalogRepos(matching: catalogFilter)
            HStack {
                TextField("Filter", text: $catalogFilter)
                    .textFieldStyle(.roundedBorder)
                Button(wizardState.catalogRepos.isEmpty ? "Load Catalog" : "Refresh") {
                    Task { await loadCatalog() }
                }
                .disabled(loadingCatalog)
                if loadingCatalog { ProgressView().controlSize(.small) }
            }
            if let catalogError {
                Label(catalogError, systemImage: "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(.orange)
            }
            ForEach(missing.prefix(200)) { repo in
                Toggle(isOn: Binding(
                    get: { wizardState.catalogToClone.contains(repo.id) },
                    set: { on in
                        if on { wizardState.catalogToClone.insert(repo.id) } else { wizardState.catalogToClone.remove(repo.id) }
                    }
                )) {
                    Text(repo.key.displayName)
                }
                .toggleStyle(.checkbox)
            }
            if missing.count > 200 {
                Text("\(missing.count - 200) more; filter to find one.").appFont(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Clone More (Optional)")
        } footer: {
            Text(wizardState.catalogToClone.isEmpty
                 ? "Repositories you can see on Azure DevOps and GitHub that are not on this Mac. Tick any to clone them into \(wizardState.repoCloneRoot) when setup finishes."
                 : "\(wizardState.catalogToClone.count) will be cloned into \(wizardState.repoCloneRoot) when setup finishes.")
                .settingsFooter()
        }
    }

    private func loadCatalog() async {
        loadingCatalog = true
        catalogError = nil
        defer { loadingCatalog = false }
        let manager = RepoManager()
        let settings = (try? manager.settings()) ?? .default
        let service = RepositoriesSettingsModel.catalogService(appState: appState, settings: settings)
        do {
            let catalog = try await manager.refreshCatalog(using: service)
            wizardState.catalogRepos = catalog.repos.filter { !$0.isArchived }
            if !catalog.errors.isEmpty { catalogError = catalog.errors.joined(separator: "\n") }
        } catch {
            catalogError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - State

extension OnboardingWizardState {
    /// The first time the step shows: the saved roots when the person chose
    /// them before, otherwise every common location that exists here.
    func prepareRepoRoots() {
        guard !repoRootsPrepared else { return }
        repoRootsPrepared = true
        let settings = (try? RepoManager().settings()) ?? .default
        if settings.rootsChosen {
            repoRoots = settings.scanRoots
        } else {
            var roots = RepoDiscovery.existingCommonLocations()
            let clone = RepoSettings.abbreviate(repoCloneRoot)
            if FileManager.default.fileExists(atPath: RepoSettings.expand(clone)), !roots.contains(clone) { roots.insert(clone, at: 0) }
            repoRoots = roots
        }
        catalogRepos = (RepoManager().cachedCatalog()?.repos ?? []).filter { !$0.isArchived }
    }

    func scanRepoRoots() async {
        isScanningRepos = true
        defer { isScanningRepos = false }
        let roots = repoRoots
        let found = (try? await RepoManager().preview(roots: roots)) ?? []
        guard roots == repoRoots else { return }
        var seen = Set<String>()
        let previous = Set(repoPreview.map(\.path))
        repoPreview = found.filter { checkout in
            guard let key = checkout.key else { return false }
            return seen.insert(key.id).inserted
        }
        // A clone named only by a workspace file starts unticked: the file
        // came from somewhere, the folders it lists are the person's call.
        for checkout in repoPreview where checkout.fromWorkspace && !previous.contains(checkout.path) {
            repoDeselected.insert(checkout.path)
        }
    }

    func isFromWorkspace(_ record: RepoRecord) -> Bool {
        repoPreview.first { $0.path == record.local?.path }?.fromWorkspace ?? false
    }

    /// The preview as records, so the sidebar's grouping applies.
    var previewRecords: [RepoRecord] {
        repoPreview.compactMap { checkout in
            checkout.key.map { RepoRecord(key: $0, catalog: nil, local: RepoRegistryEntry(key: $0, path: checkout.path, tracked: true)) }
        }
    }

    var selectedPreviewCount: Int { repoPreview.filter { !repoDeselected.contains($0.path) }.count }

    func selection(for record: RepoRecord) -> Binding<Bool> {
        let path = record.local?.path ?? ""
        return Binding(
            get: { !self.repoDeselected.contains(path) },
            set: { on in if on { self.repoDeselected.remove(path) } else { self.repoDeselected.insert(path) } }
        )
    }

    func selection(forGroup records: [RepoRecord]) -> Binding<Bool> {
        let paths = records.compactMap { $0.local?.path }
        return Binding(
            get: { paths.allSatisfy { !self.repoDeselected.contains($0) } },
            set: { on in
                if on { self.repoDeselected.subtract(paths) } else { self.repoDeselected.formUnion(paths) }
            }
        )
    }

    func missingCatalogRepos(matching filter: String) -> [CatalogRepo] {
        let present = Set(repoPreview.compactMap { $0.key?.id })
        let local = Set(((try? RepoManager().registry())?.repos.values.map(\.key.id)) ?? [])
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return catalogRepos
            .filter { !present.contains($0.id) && !local.contains($0.id) }
            .filter { needle.isEmpty || $0.key.displayName.lowercased().contains(needle) }
            .sorted { $0.key.displayName.localizedStandardCompare($1.key.displayName) == .orderedAscending }
    }

    /// Saves the step: the roots as chosen, the ticked clones tracked, the
    /// unticked ones linked but untracked (so auto-tracking leaves them be),
    /// and the ticked catalog repositories cloned in the background.
    func saveRepositories() {
        guard repoRootsPrepared else { return }
        let manager = RepoManager()
        let roots = repoRoots.map(RepoSettings.abbreviate)
        let selected = repoPreview.filter { !repoDeselected.contains($0.path) }
        let deselected = repoPreview.filter { repoDeselected.contains($0.path) }
        do {
            try manager.updateSettings { settings in
                settings.scanRoots = roots
                settings.rootsChosen = true
            }
            try manager.register(selected, track: true)
            try manager.register(deselected)
            for checkout in deselected {
                if let id = checkout.key?.id { _ = try? manager.setTracked(id, false) }
            }
        } catch {
            dbg.error("[Wizard] Saving repositories failed: \(error.localizedDescription)", category: "wizard")
        }
        NotificationCenter.default.post(name: .repoRegistryChanged, object: nil)

        let toClone = Array(catalogToClone)
        guard !toClone.isEmpty else { return }
        Task.detached {
            for id in toClone {
                do {
                    try await manager.clone(id)
                } catch {
                    dbg.error("[Wizard] Cloning \(id) failed: \(error.localizedDescription)", category: "wizard")
                }
                await MainActor.run { NotificationCenter.default.post(name: .repoRegistryChanged, object: nil) }
            }
        }
    }
}

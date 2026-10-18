import SwiftUI
import AppKit
import FleetMateCore

extension Notification.Name {
    /// Posted after Settings links, unlinks, clones or (un)tracks a repository,
    /// so the Repos workspace reloads its list at once.
    static let repoRegistryChanged = Notification.Name("repoRegistryChanged")
}

/// A file open in the editor. A reference type so typing does not publish a
/// model change per keystroke: the editor writes `text` and the model only
/// hears that the document became dirty.
final class RepoEditorDocument: Identifiable {
    let id = UUID()
    let path: String
    /// What is on disk, as last read or saved.
    var savedText: String
    /// What the editor holds now.
    var text: String
    /// Too large or not text: shown, never written.
    let isReadOnly: Bool
    /// Line to scroll to and select when the editor next shows this document.
    var revealLine: Int?

    init(path: String, text: String, isReadOnly: Bool, revealLine: Int? = nil) {
        self.path = path
        self.savedText = text
        self.text = text
        self.isReadOnly = isReadOnly
        self.revealLine = revealLine
    }
}

/// The Repos segment: tracked checkouts on the left; for the selected one,
/// the git pane (`GitPaneState`, ported from MunkiStudio) plus FleetMate's
/// file browser and editor.
@MainActor
final class RepoWorkspaceModel: ObservableObject {
    let manager = RepoManager()
    /// The selected repository's git pane.
    let git = GitPaneState()
    /// The Insights panel's period, scope and statistics.
    let insights = RepoInsightsModel()

    init() {
        git.onError = { [weak self] title, message in self?.report(title: title, message) }
        git.onRefreshed = { [weak self] in await self?.workingTreeChanged() }
        git.unsavedEdits = { [weak self] in
            guard let self, let root = self.selectedPath else { return 0 }
            return self.unsavedCount(under: root)
        }
    }

    // Repository list
    /// Tracked repositories the sidebar shows: hidden ones are left out.
    @Published private(set) var tracked: [RepoRecord] = []
    /// Every tracked repository, hidden or not, for the sidebar's Edit mode.
    @Published private(set) var allTracked: [RepoRecord] = []
    /// The sidebar's Edit mode: visibility toggles and removal on each row.
    @Published var isEditing = false
    /// A Choose Folder scan or the launch pick-up of new clones is running.
    @Published private(set) var isScanning = false
    /// A clone whose deletion waits on the person's confirmation, with what
    /// deleting it would lose.
    @Published var pendingRemoval: (record: RepoRecord, check: CloneRemovalCheck)?
    @Published private(set) var statuses: [String: RepoStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFetching: Set<String> = []
    @Published var selectedId: String? {
        willSet { lastRoot = selectedPath }
        didSet { if selectedId != oldValue { selectionChanged() } }
    }

    // Selected repository
    @Published private(set) var files: [String] = []
    @Published private(set) var tree: [RepoFileNode] = []
    @Published var expandedFolders: Set<String> = []
    @Published private(set) var grepQuery: String?
    @Published private(set) var grepResults: [RepoGrepMatch] = []
    @Published private(set) var isSearching = false

    // Editor
    @Published private(set) var document: RepoEditorDocument?
    @Published private(set) var isDirty = false
    /// Bumped to scroll the open document to its `revealLine` again.
    @Published private(set) var revealToken = 0

    // Feedback
    @Published var actionError: String?
    @Published private(set) var actionErrorTitle = "Action failed"
    @Published private(set) var notice: String?

    var selected: RepoRecord? { allTracked.first { $0.id == selectedId } }
    var selectedPath: String? { selected?.local?.path }
    var selectedStatus: RepoStatus? { selectedId.flatMap { statuses[$0] } }

    private var copy: GitWorkingCopy? { selectedPath.map(GitWorkingCopy.init(path:)) }

    // MARK: - List

    /// Rereads the registry. Cheap: one JSON file and the catalog cache.
    func reloadRecords() {
        do {
            allTracked = try manager.records().filter(\.isTracked)
                .sorted { $0.key.displayName.localizedStandardCompare($1.key.displayName) == .orderedAscending }
            tracked = allTracked.filter { !$0.isHidden }
        } catch {
            report(error)
        }
        if allTracked.isEmpty { isEditing = false }
        let listed = isEditing ? allTracked : tracked
        if let selectedId, !listed.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        if selectedId == nil { selectedId = tracked.first?.id }
    }

    /// What the sidebar lists: everything tracked while editing, otherwise
    /// only what is not hidden.
    var listed: [RepoRecord] { isEditing ? allTracked : tracked }

    // MARK: - Folders and auto-tracking

    /// Common code folders on this Mac that hold clones, offered in the
    /// empty sidebar before any folder was chosen.
    @Published private(set) var suggestedRoots: [String] = []

    func loadSuggestedRoots() async {
        guard let settings = try? manager.settings(), !settings.rootsChosen else {
            suggestedRoots = []
            return
        }
        suggestedRoots = await Task.detached(priority: .utility) {
            RepoDiscovery.existingCommonLocations().filter { root in
                !RepoDiscovery.findCheckouts(roots: [root], maxDepth: settings.scanDepth, skip: settings.skipDirectories).isEmpty
            }
        }.value
    }

    /// Asks for one or more folders, then tracks every clone in them. No
    /// further questions: picking the folder is the decision.
    func chooseFolders() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder where you keep your code. FleetMate tracks every git clone inside it."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await trackFolders(panel.urls.map(\.path))
    }

    func trackFolders(_ paths: [String]) async {
        isScanning = true
        defer { isScanning = false }
        do {
            let (results, review) = try await manager.trackFolders(paths)
            let found = results.filter { $0.action == .linked || $0.action == .alreadyLinked }.count
            registryChanged()
            if !review.isEmpty { offer(review) }
            if found == 0 && review.isEmpty {
                report(title: "No clones found", "There are no git clones in \(paths.map(repoAbbreviatedPath).joined(separator: ", ")). Clone a repository there, or choose another folder.")
            } else if found > 0 {
                flash("Tracking \(found) \(found == 1 ? "repository" : "repositories")")
            }
        } catch {
            report(title: "Could not scan the folder", error)
        }
    }

    /// Clones that appeared in the watched folders and wait for the person
    /// to add or ignore them. Never tracked unasked: a clone's own config
    /// is not trusted until someone chooses to work in it.
    @Published private(set) var newClones: [DiscoveredCheckout] = []
    /// Paths of offered clones the person has ticked in the review list.
    /// Ones whose config can run commands start unticked.
    @Published var newClonesSelected: Set<String> = []

    /// Looks for new clones, when Settings has that on. Runs no git.
    func findNewClones() async {
        guard !isScanning else { return }
        let found = (try? await manager.newClones()) ?? []
        let held = newClones.filter { $0.runsCommands && !found.contains($0) }
        offer(found + held, replacing: true)
    }

    private func offer(_ clones: [DiscoveredCheckout], replacing: Bool = false) {
        var seen = Set<String>()
        let merged = (replacing ? clones : newClones + clones).filter { seen.insert($0.path).inserted }
        let before = Set(newClones.map(\.path))
        newClones = merged
        for clone in merged where !before.contains(clone.path) && !clone.runsCommands {
            newClonesSelected.insert(clone.path)
        }
        newClonesSelected.formIntersection(merged.map(\.path))
    }

    /// "3 new repositories found in ~/Code", or the folders when several.
    var newClonesSummary: String {
        let roots = Set(newClones.compactMap { manager.scanRoot(containing: $0.path) }).sorted()
        let count = newClones.count
        let what = count == 1 ? "1 new repository" : "\(count) new repositories"
        return roots.isEmpty ? "\(what) found" : "\(what) found in \(roots.joined(separator: ", "))"
    }

    /// Tracks the ticked clones; the person ticked any flagged one knowing
    /// its settings can run commands. The rest stay offered.
    func addNewClones() {
        let found = newClones.filter { newClonesSelected.contains($0.path) }
        guard !found.isEmpty else { return }
        newClones.removeAll { newClonesSelected.contains($0.path) }
        newClonesSelected.subtract(found.map(\.path))
        do {
            try manager.register(found, track: true, trustCommandConfig: true)
            registryChanged()
            flash("Tracking \(found.count) \(found.count == 1 ? "repository" : "repositories")")
        } catch {
            report(error)
        }
    }

    /// Links them untracked so they are not offered again; Settings ›
    /// Repositories can still track any of them.
    func ignoreNewClones() {
        let found = newClones
        newClones = []
        newClonesSelected = []
        do {
            try manager.ignore(found)
            NotificationCenter.default.post(name: .repoRegistryChanged, object: nil)
        } catch {
            report(error)
        }
    }

    // MARK: - Edit mode

    func setHidden(_ record: RepoRecord, _ hidden: Bool) {
        do {
            _ = try manager.setHidden(record.id, hidden)
            registryChanged()
        } catch {
            report(error)
        }
    }

    /// Untracks without touching the folder.
    func stopTracking(_ record: RepoRecord) {
        do {
            _ = try manager.setTracked(record.id, false)
            registryChanged()
            flash("Stopped tracking \(record.key.displayName). The folder is still on disk.")
        } catch {
            report(error)
        }
    }

    /// Checks the clone, then asks for confirmation with what would be lost.
    func requestRemoval(_ record: RepoRecord) async {
        do {
            pendingRemoval = (record, try await manager.removalCheck(record.id))
        } catch {
            report(title: "Could not check \(record.key.displayName)", error)
        }
    }

    /// After the person confirmed, with the losses in front of them.
    func confirmRemoval() async {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try await manager.removeClone(pending.record.id, force: true)
            if selectedId == pending.record.id { selectedId = nil }
            registryChanged()
            flash("Moved \(pending.record.key.name) to the Trash")
        } catch {
            report(title: "Could not delete \(pending.record.key.displayName)", error)
        }
    }

    /// Reloads here and tells Settings and any other listener.
    private func registryChanged() {
        reloadRecords()
        NotificationCenter.default.post(name: .repoRegistryChanged, object: nil)
        Task { await refreshStatuses() }
    }

    /// Local status of every tracked repository: no network.
    func refreshStatuses() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let results = await manager.status(for: allTracked)
        statuses = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func fetch(_ ids: [String]) async {
        let records = allTracked.filter { ids.contains($0.id) }
        isFetching.formUnion(ids)
        let results = await manager.run(.fetch, on: records)
        isFetching.subtract(ids)
        let failures = results.filter { !$0.succeeded }
        if !failures.isEmpty {
            report(title: "Fetch failed", failures.map { "\($0.displayName): \($0.error ?? "unknown error")" }.joined(separator: "\n"))
        }
        await refreshStatuses()
    }

    // MARK: - Selection

    private func selectionChanged() {
        files = []
        tree = []
        expandedFolders = []
        clearGrep()
        parkCurrentDocument(root: lastRoot)
        document = nil
        git.attach(copy, protectedBranches: selected.map(manager.protectedBranches(for:)) ?? [])
        Task {
            await loadSelected()
            await git.refresh()
        }
    }

    /// The selected repository's file list, for the Files panel.
    func loadSelected() async {
        guard let copy, let id = selectedId else { return }
        do {
            let paths = try await copy.listFiles()
            guard id == selectedId else { return }
            files = paths
            tree = RepoFileTree.build(paths)
        } catch {
            report(error)
        }
    }

    /// After git changed the working tree (commit, discard, pull, branch
    /// switch): the file list, an unedited open file, and the list row.
    func workingTreeChanged() async {
        guard let copy else { return }
        if let paths = try? await copy.listFiles() {
            files = paths
            tree = RepoFileTree.build(paths)
            reloadOpenDocumentFromDisk()
        }
        if let record = selected {
            statuses[record.id] = await manager.status(for: record)
        }
    }

    // MARK: - Search

    func grep(_ query: String) async {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard let copy, !pattern.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            grepResults = try await copy.grep(pattern, ignoreCase: true, fixedStrings: true, limit: 500)
            grepQuery = pattern
        } catch {
            report(title: "Search failed", error)
        }
    }

    func clearGrep() {
        grepQuery = nil
        grepResults = []
    }

    // MARK: - Editor

    func open(_ path: String, line: Int? = nil) {
        guard let copy else { return }
        if let document, document.path == path {
            document.revealLine = line
            revealToken += 1
            return
        }
        parkCurrentDocument(root: copy.path)
        let absolute = (copy.path as NSString).appendingPathComponent(path)
        if let parked = unsaved.removeValue(forKey: absolute) {
            parked.revealLine = line
            document = parked
            isDirty = true
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: absolute)[.size] as? Int) ?? 0
        do {
            let data = try copy.readFile(path)
            if let text = RepoTextFile.decode(data) {
                document = RepoEditorDocument(path: path, text: text, isReadOnly: size > RepoTextFile.editableLimit, revealLine: line)
            } else {
                document = RepoEditorDocument(path: path, text: "This file is not text (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))). Reveal it in Finder to open it with another app.", isReadOnly: true)
            }
            isDirty = false
        } catch {
            report(title: "Could not open \(path)", error)
        }
    }

    func editorTextChanged() {
        guard let document else { return }
        let dirty = document.text != document.savedText
        if dirty != isDirty { isDirty = dirty }
    }

    func save() {
        guard let copy, let document, !document.isReadOnly, isDirty else { return }
        do {
            try copy.writeFile(document.path, contents: Data(document.text.utf8))
            document.savedText = document.text
            isDirty = false
            flash("Saved \((document.path as NSString).lastPathComponent)")
            Task { await git.refresh() }
        } catch {
            report(title: "Save failed", error)
        }
    }

    /// After git rewrote the working tree (discard, pull, branch switch), an
    /// open file with no unsaved edits shows what is now on disk.
    private func reloadOpenDocumentFromDisk() {
        guard let document, !isDirty, let copy else { return }
        let path = document.path
        self.document = nil
        if FileManager.default.fileExists(atPath: (copy.path as NSString).appendingPathComponent(path)) {
            open(path)
        }
    }

    /// Throws away unsaved edits to the open file (after the view confirms).
    func revert() {
        guard let document else { return }
        document.text = document.savedText
        isDirty = false
        self.document = nil
        open(document.path)
    }

    func closeEditor() {
        parkCurrentDocument(root: selectedPath)
        document = nil
        isDirty = false
    }

    /// Whether `path` in the selected repository has edits not yet saved.
    func hasUnsavedEdits(_ path: String) -> Bool {
        if isDirty, document?.path == path { return true }
        guard let root = selectedPath else { return false }
        return unsaved[(root as NSString).appendingPathComponent(path)] != nil
    }

    /// Unsaved edits are never dropped and never block with a prompt: moving
    /// to another file keeps them in memory, and reopening the file brings
    /// them back.
    private func parkCurrentDocument(root: String?) {
        guard isDirty, let document, let root else { return }
        unsaved[(root as NSString).appendingPathComponent(document.path)] = document
        isDirty = false
    }

    /// Unsaved documents by absolute path, across repositories.
    private var unsaved: [String: RepoEditorDocument] = [:]
    /// The selected checkout before the selection changed, so a document
    /// being parked on a switch is filed under the repository it came from.
    private var lastRoot: String?

    func unsavedCount(under root: String) -> Int {
        unsaved.keys.filter { $0.hasPrefix(root + "/") }.count + (isDirty ? 1 : 0)
    }

    // MARK: - Feedback

    private func report(title: String = "Action failed", _ error: Error) {
        report(title: title, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func report(title: String, _ message: String) {
        actionErrorTitle = title
        actionError = message
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }
}

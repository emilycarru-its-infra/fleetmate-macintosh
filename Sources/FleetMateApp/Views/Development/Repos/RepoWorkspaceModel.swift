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

    init() {
        git.onError = { [weak self] title, message in self?.report(title: title, message) }
        git.onRefreshed = { [weak self] in await self?.workingTreeChanged() }
        git.unsavedEdits = { [weak self] in
            guard let self, let root = self.selectedPath else { return 0 }
            return self.unsavedCount(under: root)
        }
    }

    // Repository list
    @Published private(set) var tracked: [RepoRecord] = []
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

    var selected: RepoRecord? { tracked.first { $0.id == selectedId } }
    var selectedPath: String? { selected?.local?.path }
    var selectedStatus: RepoStatus? { selectedId.flatMap { statuses[$0] } }

    private var copy: GitWorkingCopy? { selectedPath.map(GitWorkingCopy.init(path:)) }

    // MARK: - List

    /// Rereads the registry. Cheap: one JSON file and the catalog cache.
    func reloadRecords() {
        do {
            tracked = try manager.records().filter(\.isTracked)
                .sorted { $0.key.displayName.localizedStandardCompare($1.key.displayName) == .orderedAscending }
        } catch {
            report(error)
        }
        if let selectedId, !tracked.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        if selectedId == nil { selectedId = tracked.first?.id }
    }

    /// Local status of every tracked repository: no network.
    func refreshStatuses() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let results = await manager.status(for: tracked)
        statuses = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func fetch(_ ids: [String]) async {
        let records = tracked.filter { ids.contains($0.id) }
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

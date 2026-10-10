import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Left pane

/// The Repos sidebar: the workspace's mode (Changes, History, Files,
/// Insights) on top, then tracked repositories grouped the way checkouts sit
/// on disk — host, then project or owner — with a filter and sort below.
/// Status refreshes on appear and every 30 seconds while shown; fetch is on
/// demand. Sort, grouping, filter and which groups are collapsed persist.
struct ReposListView: View {
    @ObservedObject var model: RepoWorkspaceModel
    @AppStorage("settings.selectedTab") private var settingsTab: Int = 0
    @AppStorage("repos.sidebar.sort") private var sort: RepoSidebarSort = .name
    @AppStorage("repos.sidebar.grouped") private var grouped = true
    @AppStorage("repos.sidebar.filter") private var filter = ""
    /// Collapsed section and group ids, newline-separated. Collapsed rather
    /// than expanded is stored so a newly tracked project starts open.
    @AppStorage("repos.sidebar.collapsed") private var collapsedStorage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelPicker
            Divider()
            if model.tracked.isEmpty {
                ContentUnavailableView {
                    Label("No tracked repositories", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Track repositories in Settings › Repositories, or run `fleetmate repos link <path>` in a terminal.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                        .simultaneousGesture(TapGesture().onEnded { settingsTab = RepositoriesSettingsView.tabTag })
                }
                .frame(maxHeight: .infinity)
            } else {
                repositoryList
            }
            Divider()
            bottomBar
        }
        .task {
            model.reloadRecords()
            await model.refreshStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await model.refreshStatuses()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoRegistryChanged)) { _ in
            model.reloadRecords()
            Task { await model.refreshStatuses() }
        }
    }

    // MARK: Mode

    /// Switches what the rest of the window shows for the selected
    /// repository. It sits above the list because it is a mode of the whole
    /// workspace: it stays put as the selection moves between repositories.
    private var panelPicker: some View {
        Picker("View", selection: Bindable(model.git).focusedPanel) {
            ForEach(GitPaneState.Panel.allCases, id: \.self) { panel in
                Text(panel.title).tag(panel)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help("Changes, History, Files or Insights for the selected repository (keys 1–4)")
    }

    // MARK: List

    private var repositoryList: some View {
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        return List(selection: $model.selectedId) {
            if grouped {
                let sections = RepoSidebarOrganizer.sections(model.tracked, statuses: model.statuses, sort: sort, matching: filter)
                ForEach(sections) { section in
                    Section(isExpanded: expansion(section.id, forcedOpen: filtering)) {
                        ForEach(section.groups) { group in
                            DisclosureGroup(isExpanded: expansion(group.id, forcedOpen: filtering)) {
                                ForEach(group.records) { record in
                                    row(record, showScope: false)
                                }
                            } label: {
                                Label(group.scope, systemImage: "folder")
                                    .help(group.title)
                            }
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            } else {
                ForEach(RepoSidebarOrganizer.flat(model.tracked, statuses: model.statuses, sort: sort, matching: filter)) { record in
                    row(record, showScope: true)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if filtering, RepoSidebarOrganizer.flat(model.tracked, statuses: [:], sort: .name, matching: filter).isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
    }

    private func row(_ record: RepoRecord, showScope: Bool) -> some View {
        RepoListRow(record: record, status: model.statuses[record.id], isFetching: model.isFetching.contains(record.id), showScope: showScope)
            .tag(record.id)
            .contextMenu { rowMenu(record) }
    }

    @ViewBuilder
    private func rowMenu(_ record: RepoRecord) -> some View {
        if let path = record.local?.path {
            Button("Fetch") { Task { await model.fetch([record.id]) } }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.key.displayName, forType: .string)
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedStorage.split(separator: "\n").map(String.init))
    }

    /// A group's disclosure state. While a filter is typed every group is
    /// open, so a match is never hidden inside a collapsed folder; the stored
    /// state comes back when the filter is cleared.
    private func expansion(_ id: String, forcedOpen: Bool) -> Binding<Bool> {
        Binding(
            get: { forcedOpen || !collapsed.contains(id) },
            set: { open in
                guard !forcedOpen else { return }
                var set = collapsed
                if open { set.remove(id) } else { set.insert(id) }
                collapsedStorage = set.sorted().joined(separator: "\n")
            }
        )
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.35)))

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(RepoSidebarSort.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Group by Source", isOn: $grouped)
                if grouped {
                    Button("Expand All") { collapsedStorage = "" }
                    Button("Collapse All") {
                        let sections = RepoSidebarOrganizer.sections(model.tracked, statuses: [:], sort: .name)
                        collapsedStorage = sections.flatMap { $0.groups.map(\.id) }.sorted().joined(separator: "\n")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by \(sort.title.lowercased())\(grouped ? ", grouped by source" : "")")

            if model.isRefreshing || !model.isFetching.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.fetch(model.tracked.map(\.id)) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.tracked.isEmpty || !model.isFetching.isEmpty)
            .help("Fetch every tracked repository from its remote")
            .accessibilityLabel("Fetch All")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct RepoListRow: View {
    let record: RepoRecord
    let status: RepoStatus?
    let isFetching: Bool
    /// In the ungrouped list the project or owner is not implied by a folder.
    let showScope: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(record.key.name).appFont(.body, weight: .medium).lineLimit(1)
                if showScope {
                    Text(record.key.scope).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isFetching { ProgressView().controlSize(.mini) }
            }
            metadata
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(record.local.map { repoAbbreviatedPath($0.path) } ?? record.key.displayName)
    }

    @ViewBuilder
    private var metadata: some View {
        if let error = status?.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let status {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    Text(status.branch ?? "detached").truncationMode(.middle)
                }
                if status.ahead > 0 || status.behind > 0 {
                    Text(syncText(status)).monospacedDigit()
                        .help("\(status.ahead) ahead, \(status.behind) behind \(status.upstream ?? "upstream")")
                }
                if status.changedCount > 0 {
                    Text("\(status.changedCount) changed").monospacedDigit()
                } else if status.isClean {
                    Text("clean")
                }
            }
            .layoutPriority(1)
        } else {
            Text(record.key.scope)
        }
    }

    private func syncText(_ status: RepoStatus) -> String {
        [status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

func repoAbbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: Files

struct RepoFilesPane: View {
    @ObservedObject var model: RepoWorkspaceModel
    let searchText: String

    private var filtering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
            Divider()
            if let query = model.grepQuery {
                grepResults(query)
            } else {
                tree
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Text(model.grepQuery == nil ? "Files" : "Search").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if model.isSearching { ProgressView().controlSize(.mini) }
            Spacer()
            if model.grepQuery != nil {
                Button("Show Files") { model.clearGrep() }
                    .buttonStyle(.borderless)
                    .appFont(.caption)
            } else if filtering {
                Text("Press Return to search contents").appFont(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var tree: some View {
        let nodes = RepoFileTree.filter(model.tree, matching: searchText)
        let expanded = filtering ? RepoFileTree.folderPaths(nodes) : model.expandedFolders
        let rows = RepoFileTree.visibleRows(nodes, expanded: expanded)
        let openPath = model.document?.path
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FileTreeRow(
                        row: row,
                        isOpen: row.node.path == openPath,
                        isUnsaved: !row.node.isFolder && model.hasUnsavedEdits(row.node.path)
                    ) {
                        if row.node.isFolder {
                            guard !filtering else { return }
                            if model.expandedFolders.contains(row.node.path) {
                                model.expandedFolders.remove(row.node.path)
                            } else {
                                model.expandedFolders.insert(row.node.path)
                            }
                        } else {
                            model.open(row.node.path)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if rows.isEmpty {
                Text(model.tree.isEmpty ? "Loading…" : "No file names match")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func grepResults(_ query: String) -> some View {
        List {
            if model.grepResults.isEmpty, !model.isSearching {
                Text("Nothing in this repository contains “\(query)”.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            let grouped = Dictionary(grouping: model.grepResults, by: \.path)
            ForEach(grouped.keys.sorted(), id: \.self) { path in
                Section {
                    ForEach(grouped[path] ?? [], id: \.self) { match in
                        Button {
                            model.open(match.path, line: match.line)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(match.line)")
                                    .appFont(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(minWidth: 28, alignment: .trailing)
                                Text(match.text.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(path).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FileTreeRow: View {
    let row: RepoFileRow
    let isOpen: Bool
    let isUnsaved: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .appFont(fixed: 9, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .opacity(row.node.isFolder ? 1 : 0)
            Image(systemName: row.node.isFolder ? "folder" : "doc")
                .appFont(fixed: 11)
                .foregroundStyle(row.node.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(row.node.name).appFont(fixed: 12).lineLimit(1)
            if isUnsaved {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved edits")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(isOpen ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.node.isFolder ? "Folder \(row.node.name)" : row.node.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: Editor

/// The Files panel's right side: the open file in FleetMate's editor.
struct RepoEditorPane: View {
    @ObservedObject var model: RepoWorkspaceModel
    @State private var confirmRevert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                CodeEditorView(document: document, revealToken: model.revealToken) { model.editorTextChanged() }
            } else {
                ContentUnavailableView(
                    "No file open",
                    systemImage: "doc.text",
                    description: Text("Pick a file on the left. Filter with the toolbar search field; press Return to search every file's contents.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let document = model.document {
                GitFileGlyph(relativePath: document.path)
                Text(document.path).lineLimit(1).truncationMode(.middle)
                if model.isDirty { Text("Edited").foregroundStyle(.secondary) }
                if document.isReadOnly { Text("Read only").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert") { confirmRevert = true }
                    .disabled(!model.isDirty)
                Button("Close") { model.closeEditor() }
            } else {
                Text("Editor").foregroundStyle(.secondary)
                Spacer()
            }
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
        .confirmationDialog("Discard your unsaved edits?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file goes back to what is saved on disk.")
        }
    }
}

import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Left pane

/// Tracked repositories with branch, sync and change state. Refreshed on
/// appear and every 30 seconds while shown; fetch is on demand.
struct ReposListView: View {
    @ObservedObject var model: RepoWorkspaceModel
    @AppStorage("settings.selectedTab") private var settingsTab: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                List(selection: $model.selectedId) {
                    ForEach(model.tracked) { record in
                        RepoListRow(record: record, status: model.statuses[record.id], isFetching: model.isFetching.contains(record.id))
                            .tag(record.id)
                    }
                }
                .listStyle(.sidebar)
            }
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

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tracked").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if model.isRefreshing { ProgressView().controlSize(.mini) }
            Spacer()
            Button {
                Task { await model.fetch(model.tracked.map(\.id)) }
            } label: {
                Label("Fetch All", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.tracked.isEmpty || !model.isFetching.isEmpty)
            .help("Fetch every tracked repository from its remote")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct RepoListRow: View {
    let record: RepoRecord
    let status: RepoStatus?
    let isFetching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: record.key.provider == .gitHub ? "chevron.left.forwardslash.chevron.right" : "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(record.key.name).appFont(.body, weight: .medium).lineLimit(1)
                Spacer(minLength: 4)
                if isFetching { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 8) {
                if let error = status?.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let status {
                    Label(status.branch ?? "detached", systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                    if status.ahead > 0 { Text("↑\(status.ahead)") }
                    if status.behind > 0 { Text("↓\(status.behind)") }
                    let changed = status.staged + status.unstaged + status.untracked
                    if changed > 0 {
                        Text("\(changed) changed")
                    } else if status.isClean {
                        Text("clean")
                    }
                } else {
                    Text(record.key.scope)
                }
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
        }
        .padding(.vertical, 2)
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

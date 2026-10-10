import SwiftUI
import AppKit
import FleetMateCore

// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/GitPanels.swift. "Open" goes to FleetMate's own
// editor (the Files panel) rather than MunkiStudio's pkginfo and manifest
// editors, and the history menu offers the actions this port keeps.

/// The working-tree change list: checkbox to stage, status chip, glyph, path.
struct GitFilesPanel: View {
    @Bindable var state: GitPaneState
    /// Opens a repository-relative path in FleetMate's editor.
    let openInEditor: (String) -> Void

    var body: some View {
        if state.files.isEmpty {
            ContentUnavailableView(
                "Working tree clean",
                systemImage: "checkmark.circle",
                description: Text("No uncommitted changes.")
            )
            .padding()
            .frame(maxHeight: .infinity)
        } else {
            List(state.filteredFiles, selection: $state.fileSelection) { entry in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { entry.staged },
                        set: { newValue in
                            Task {
                                if newValue {
                                    await state.stage([entry.relativePath])
                                } else {
                                    await state.unstage([entry.relativePath])
                                }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(entry.staged ? "Unstage \(entry.relativePath)" : "Stage \(entry.relativePath)")
                    GitStatusChip(kind: entry.kind, staged: entry.staged)
                    GitFileGlyph(relativePath: entry.relativePath)
                    Text(entry.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(.rect)
                .onTapGesture(count: 2) { openInEditor(entry.relativePath) }
                .tag(entry.id)
            }
            .contextMenu(forSelectionType: String.self) { selections in
                let targets = selections.isEmpty ? Array(state.fileSelection) : Array(selections)
                if let id = targets.first, let entry = state.files.first(where: { $0.id == id }) {
                    fileContextMenu(entry)
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func fileContextMenu(_ entry: GitStatusEntry) -> some View {
        let relativePath = entry.relativePath
        let fileURL = url(relativePath)
        let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        Button("Open") { openInEditor(relativePath) }
            .disabled(!exists)
        Button("Open in External Editor") { if let fileURL { NSWorkspace.shared.open(fileURL) } }
            .disabled(!exists)
        if let fileURL, exists {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(displayName(for: appURL)) {
                            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
        }
        Button("Show in Finder") { if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } }
            .disabled(!exists)

        Divider()

        Button("Copy Path") { if let fileURL { state.copyToPasteboard(fileURL.path) } }
        Button("Copy Relative Path") { state.copyToPasteboard(relativePath) }
        Button("Copy Filename") { state.copyToPasteboard((relativePath as NSString).lastPathComponent) }

        Divider()

        if entry.staged {
            Button("Unstage") { Task { await state.unstage([relativePath]) } }
        } else {
            Button("Stage") { Task { await state.stage([relativePath]) } }
        }
        Button("Discard Changes…") {
            state.discardRequest = .init(paths: [relativePath])
        }
        .disabled(entry.staged)
    }

    private func url(_ relativePath: String) -> URL? {
        state.copy.map { URL(fileURLWithPath: $0.path).appendingPathComponent(relativePath) }
    }

    private func displayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}

/// History: the commit list with its lane graph and per-commit actions.
struct GitCommitsPanel: View {
    @Bindable var state: GitPaneState
    @State private var pendingAction: CommitAction?

    private static let rowHeight: CGFloat = 46

    var body: some View {
        let commits = state.filteredCommits
        let graph = CommitGraphBuilder.build(commits)
        Group {
            if commits.isEmpty {
                ContentUnavailableView("No commits", systemImage: "clock").padding().frame(maxHeight: .infinity)
            } else {
                List(selection: $state.commitSelection) {
                    ForEach(Array(commits.enumerated()), id: \.element.sha) { index, commit in
                        commitRow(
                            commit,
                            graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                            laneCount: graph.laneCount
                        )
                        .tag(commit.sha)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .contextMenu(forSelectionType: String.self) { shas in
                    let targets = shas.isEmpty ? [state.commitSelection].compactMap { $0 } : Array(shas)
                    if let sha = targets.first, let commit = state.commits.first(where: { $0.sha == sha }) {
                        commitContextMenu(commit)
                    }
                }
            }
        }
        .popover(item: $pendingAction, arrowEdge: .trailing) { action in
            GitCommitActionSheet(
                action: action,
                currentBranch: state.currentBranch,
                perform: { request in await state.run(request) }
            )
        }
    }

    private func commitRow(_ commit: GitCommit, graphRow: GraphRow?, laneCount: Int) -> some View {
        HStack(spacing: 8) {
            if let graphRow {
                GraphCell(row: graphRow, laneCount: laneCount, rowHeight: Self.rowHeight)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ForEach(commit.refs, id: \.self) { ref in
                        refBadge(ref)
                    }
                    Text(commit.subject).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(commit.sha.prefix(8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Text(commit.author).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
    }

    private func refBadge(_ ref: RepoGitRef) -> some View {
        let tint = badgeColor(ref)
        return HStack(spacing: 3) {
            Image(systemName: icon(for: ref.kind)).imageScale(.small)
            Text(ref.name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.18), in: .capsule)
        .foregroundStyle(tint)
        .overlay(Capsule().strokeBorder(ref.isHead ? tint : Color.clear, lineWidth: 1))
    }

    private func icon(for kind: RepoGitRef.Kind) -> String {
        switch kind {
        case .head: "circle.fill"
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }

    private func badgeColor(_ ref: RepoGitRef) -> Color {
        switch ref.kind {
        case .head, .localBranch: .blue
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: GitCommit) -> some View {
        Button("Add Tag…") { pendingAction = .addTag(commit) }
        Button("Create Branch…") { pendingAction = .createBranch(commit) }
        Divider()
        Button("Checkout…") { pendingAction = .checkout(commit) }
        Button("Cherry-Pick…") { pendingAction = .cherryPick(commit) }
        Button("Revert…") { pendingAction = .revert(commit) }
        Divider()
        Button("Copy Commit Hash") { state.copyToPasteboard(commit.sha) }
        Button("Copy Commit Subject") { state.copyToPasteboard(commit.subject) }
        Button("Copy .patch") { Task { await state.copyPatch(for: commit.sha) } }
    }
}

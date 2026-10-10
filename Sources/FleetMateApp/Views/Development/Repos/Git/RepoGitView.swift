import SwiftUI
import AppKit
import FleetMateCore

// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/GitView.swift: the same header, Files/History
// panel strip, commit composer above the list, diff or commit detail on the
// right, and lazygit-style keys. FleetMate adds a third panel, Files, which
// browses every file in the checkout and edits it; an Open in Terminal action
// that starts an agent session in the checkout; and the AGENTS.md marker.
// MunkiStudio's Hooks panel is not ported yet. Alerts become the error banner
// and confirmation dialogs (FleetMate's rule), and red becomes orange.

/// The Repos workspace's detail: the selected repository's git pane.
struct RepoGitView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: RepoWorkspaceModel
    let searchText: String
    @FocusState private var paneFocused: Bool
    @FocusState private var commitFieldFocus: CommitField?

    enum CommitField: Hashable { case subject, body }
    @State private var optionHeld: Bool = false
    @State private var copiedOutputAt: Date?
    @State private var newBranchAction: CommitAction?
    @State private var flagsMonitor: Any?

    private var state: GitPaneState { model.git }

    var body: some View {
        Group {
            if let record = model.selected, let path = model.selectedPath {
                VStack(spacing: 0) {
                    header(record: record, path: path)
                    Divider()
                    mainBody
                }
                .confirmationDialog(
                    discardTitle(for: state.discardRequest),
                    isPresented: discardPresented,
                    titleVisibility: .visible,
                    presenting: state.discardRequest
                ) { request in
                    Button("Discard", role: .destructive) {
                        state.discardRequest = nil
                        Task { await state.performDiscard(request) }
                    }
                    Button("Cancel", role: .cancel) { state.discardRequest = nil }
                } message: { request in
                    Text(discardMessage(for: request))
                }
                .confirmationDialog(
                    "Git index is locked",
                    isPresented: indexLockPresented,
                    titleVisibility: .visible,
                    presenting: state.indexLockRequest
                ) { request in
                    Button("Delete Lock File", role: .destructive) {
                        state.indexLockRequest = nil
                        Task { await state.deleteLockAndRetry(request) }
                    }
                    .disabled(!request.holders.isEmpty)
                    Button("Cancel", role: .cancel) { state.indexLockRequest = nil }
                } message: { request in
                    Text(lockMessage(for: request))
                }
                .focusable()
                .focused($paneFocused)
                .focusEffectDisabled()
                .onKeyPress { press in handleKey(press) }
                .onAppear {
                    paneFocused = true
                    // onModifierKeysChanged needs macOS 15; FleetMate runs on 14.
                    flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                        optionHeld = event.modifierFlags.contains(.option)
                        return event
                    }
                }
                .onDisappear {
                    if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
                    flagsMonitor = nil
                }
                .onChange(of: state.fileSelection) { _, _ in Task { await state.syncDiff() } }
                .onChange(of: state.commitSelection) { _, _ in Task { await state.syncDiff() } }
                .onChange(of: state.focusedPanel) { _, _ in Task { await state.syncDiff() } }
            } else {
                ContentUnavailableView(
                    "Select a repository",
                    systemImage: "folder",
                    description: Text("Browse, edit and commit in any tracked checkout. Agents work in the same checkouts through `fleetmate repos`.")
                )
            }
        }
        .actionErrorBanner($model.actionError, title: model.actionErrorTitle)
    }

    // MARK: Header

    private func header(record: RepoRecord, path: String) -> some View {
        HStack(spacing: 8) {
            branchPicker
            Button { Task { await state.runFetch() } } label: {
                Label("Fetch", systemImage: "arrow.down.to.line")
            }
            .help("git fetch (f)")
            Button { Task { await state.runPull() } } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .help("git pull --ff-only (p)")
            Button { Task { await state.runPush() } } label: {
                Label("Push", systemImage: "arrow.up")
            }
            .help(state.isOnProtectedBranch
                  ? "'\(state.currentBranch ?? "")' is protected: pushing it is refused. Push a branch and open a pull request."
                  : "git push (P)")
            Divider().frame(height: 16)
            Button { Task { await state.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (r)")
            Button { state.helpVisible.toggle() } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Show shortcuts (?)")
            .popover(isPresented: Bindable(state).helpVisible, arrowEdge: .bottom) { GitHelpSheet() }
            Spacer()
            agentsMarker
            Button {
                _ = appState.terminals.open(AgentLaunch(command: appState.agentDefaultLaunch.command, directory: path))
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Open an agent terminal session in this checkout")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .help("Reveal \(repoAbbreviatedPath(path)) in Finder")
        }
        .labelStyle(.titleAndIcon)
        .fontWeight(.semibold)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(item: $newBranchAction, arrowEdge: .bottom) { action in
            GitCommitActionSheet(action: action, currentBranch: state.currentBranch) { request in
                await state.run(request)
            }
        }
    }

    @ViewBuilder
    private var agentsMarker: some View {
        if model.selectedStatus?.agentsFile != nil {
            Button {
                openInEditor("AGENTS.md")
            } label: {
                Label("AGENTS.md", systemImage: "doc.text")
            }
            .buttonStyle(.borderless)
            .fontWeight(.regular)
            .help("Agents read this file before working here. Click to open it.")
        } else {
            Label("No AGENTS.md", systemImage: "doc")
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .help("This repository has no AGENTS.md for agents to read")
        }
    }

    private var branchPicker: some View {
        Menu {
            ForEach(state.branches, id: \.name) { branch in
                Button {
                    Task { await state.switchBranch(branch.name) }
                } label: {
                    // A menu item takes one label; an HStack with an empty
                    // image did not act on selection.
                    let title = branch.upstreamName.map { "\(branch.name)  →  \($0)" } ?? branch.name
                    if branch.isCurrent {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            Divider()
            Button("New Branch…") {
                if let head = state.commits.first(where: { $0.refs.contains(where: \.isHead) }) ?? state.commits.first {
                    newBranchAction = .newBranch(head)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(state.currentBranch ?? "(detached)")
                    .font(.callout.monospaced())
                    .fontWeight(.semibold)
                if !state.files.isEmpty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Uncommitted changes")
                }
                if state.aheadCount > 0 {
                    Image(systemName: "arrow.up").imageScale(.small).foregroundStyle(.secondary)
                    Text("\(state.aheadCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if state.behindCount > 0 {
                    Image(systemName: "arrow.down").imageScale(.small).foregroundStyle(.secondary)
                    Text("\(state.behindCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private var mainBody: some View {
        if state.focusedPanel == .insights {
            RepoInsightsView(model: model)
        } else {
            changesBody
        }
    }

    /// Changes, History and Files: the panel list beside its diff or editor.
    /// The panel switcher sits at the top of the repository sidebar.
    private var changesBody: some View {
        GeometryReader { geometry in
            let leftWidth = max(380, geometry.size.width * 0.42)
            HSplitView {
                VStack(spacing: 0) {
                    if state.focusedPanel == .files {
                        commitComposer
                        Divider()
                    }
                    if state.filterVisible, state.focusedPanel != .browse {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Filter", text: Bindable(state).filter)
                                .textFieldStyle(.plain)
                            Button {
                                state.filter = ""
                                state.filterVisible = false
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                    }
                    focusedPanelContents
                }
                .frame(minWidth: 320, idealWidth: leftWidth, maxWidth: 900)

                Group {
                    switch state.focusedPanel {
                    case .files:
                        GitDiffView(
                            text: state.diffText,
                            mode: .workingTree,
                            anyStaged: state.focusedFileStaged,
                            onStageHunk: { file, hunk in
                                Task { await state.applyChunk(file: file, hunk: hunk, cached: true, reverse: false) }
                            },
                            onUnstageHunk: { file, hunk in
                                Task { await state.applyChunk(file: file, hunk: hunk, cached: true, reverse: true) }
                            },
                            onDiscardHunk: { file, hunk in
                                state.discardRequest = .init(paths: [file.displayPath], hunkPatch: file.patch(forHunk: hunk))
                            }
                        )
                    case .history:
                        GitCommitDetailView(text: state.diffText, commit: state.focusedCommit)
                    case .browse:
                        RepoEditorPane(model: model)
                    case .insights:
                        EmptyView()
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var focusedPanelContents: some View {
        switch state.focusedPanel {
        case .files: GitFilesPanel(state: state, openInEditor: openInEditor)
        case .history: GitCommitsPanel(state: state)
        case .browse: RepoFilesPane(model: model, searchText: searchText)
        case .insights: EmptyView()
        }
    }

    private func openInEditor(_ relativePath: String) {
        state.focusedPanel = .browse
        model.open(relativePath)
    }

    // MARK: Commit composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            commitFieldsHeader
            TextField("Subject", text: Bindable(state).commitSubject)
                .textFieldStyle(.roundedBorder)
                .focused($commitFieldFocus, equals: .subject)
            TextEditor(text: Bindable(state).commitBody)
                .font(.body)
                .frame(minHeight: 50, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .focused($commitFieldFocus, equals: .body)
            commitOptionsRow
            commitActionRow
            if !state.processOutput.isEmpty {
                processOutputPanel
            }
        }
        .padding(12)
    }

    private var processOutputPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    state.copyToPasteboard(state.processOutput)
                    copiedOutputAt = Date()
                } label: {
                    Label(
                        copiedOutputAt != nil ? "Copied" : "Copy",
                        systemImage: copiedOutputAt != nil ? "checkmark" : "doc.on.doc"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy output to clipboard")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            ScrollView {
                Text(state.processOutput)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            .frame(maxHeight: 100)
        }
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: state.processOutput) { _, _ in copiedOutputAt = nil }
        .task(id: copiedOutputAt) {
            guard copiedOutputAt != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedOutputAt = nil
        }
    }

    private var commitFieldsHeader: some View {
        HStack {
            Text("Commit").font(.headline)
            if state.isOnProtectedBranch {
                Label("\(state.currentBranch ?? "") is protected", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Commits and pushes on this branch are refused. Create a branch from the branch menu first.")
            }
            Spacer()
            statusTrailing
        }
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if state.isBusy {
            ProgressView().controlSize(.small)
        } else if let message = state.statusMessage {
            Label(message, systemImage: statusIcon(for: state.statusKind))
                .foregroundStyle(statusColor(for: state.statusKind))
                .font(.callout)
        } else if let stamp = state.lastRefreshedAt {
            TimelineView(.periodic(from: stamp, by: 30)) { _ in
                Text("Last refreshed \(Self.relative(from: stamp))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func relative(from date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private var commitOptionsRow: some View {
        HStack(spacing: 16) {
            Toggle("Amend", isOn: Bindable(state).amend)
                .help("Amend the last commit instead of creating a new one")
            Toggle("Skip Hooks", isOn: Bindable(state).skipHooks)
                .help("Pass --no-verify to bypass pre-commit and commit-msg hooks")
            Spacer()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var commitActionRow: some View {
        HStack {
            Button(optionHeld ? "Unstage All" : "Stage All") {
                Task {
                    if optionHeld { await state.unstageAll() } else { await state.toggleStageAll() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(optionHeld ? !state.files.contains(where: \.staged) : state.files.isEmpty)
            .help(optionHeld
                  ? "Unstage every staged file (hold Option)"
                  : "Stage every change in the working tree — hold Option to Unstage All")
            Spacer()
            Button("Commit") { Task { _ = await state.runCommit() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(state.commitSubject.isEmpty || state.isBusy)
            Button("Commit & Push") { Task { await state.runCommitAndPush() } }
                .buttonStyle(.bordered)
                .disabled(state.commitSubject.isEmpty || state.isBusy)
        }
        .controlSize(.large)
    }

    private func statusIcon(for kind: GitPaneState.StatusKind) -> String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for kind: GitPaneState.StatusKind) -> Color {
        switch kind {
        case .info: .secondary
        case .success: .green
        case .error: .orange
        }
    }

    // MARK: Confirmations

    private var discardPresented: Binding<Bool> {
        Binding(get: { state.discardRequest != nil }, set: { if !$0 { state.discardRequest = nil } })
    }

    private var indexLockPresented: Binding<Bool> {
        Binding(get: { state.indexLockRequest != nil }, set: { if !$0 { state.indexLockRequest = nil } })
    }

    private func discardTitle(for request: GitPaneState.DiscardRequest?) -> String {
        guard let request else { return "" }
        if request.hunkPatch != nil { return "Discard this chunk of \(request.paths.first ?? "the file")?" }
        return request.paths.count == 1
            ? "Discard changes to \(request.paths[0])?"
            : "Discard changes to \(request.paths.count) files?"
    }

    private func discardMessage(for request: GitPaneState.DiscardRequest) -> String {
        request.paths.count <= 1
            ? "This is irreversible."
            : "This is irreversible. Files:\n\n" + request.paths.joined(separator: "\n")
    }

    private func lockMessage(for request: GitPaneState.IndexLockRequest) -> String {
        if request.holders.isEmpty {
            return "\(request.action) could not take \(request.lockPath). No process has it open, so a crashed git command most likely left it behind. Delete it and retry?"
        }
        return "\(request.action) could not take \(request.lockPath). It is still held:\n\n\(request.holders)\n\nQuit that process, then try again."
    }
}

// MARK: Key handling

private extension RepoGitView {
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if commitFieldFocus != nil || state.focusedPanel == .browse { return .ignored }
        switch press.characters {
        case "1": state.focusedPanel = .files; return .handled
        case "2": state.focusedPanel = .history; return .handled
        case "3": state.focusedPanel = .browse; return .handled
        case "4": state.focusedPanel = .insights; return .handled
        case "j": state.moveSelectionDown(); return .handled
        case "k": state.moveSelectionUp(); return .handled
        case " ":
            if state.focusedPanel == .files { Task { await state.toggleStageSelected() } }
            return .handled
        case "a":
            if state.focusedPanel == .files { Task { await state.toggleStageAll() } }
            return .handled
        case "c":
            commitFieldFocus = .subject
            return .handled
        case "C":
            Task { await state.runCommitAndPush() }
            return .handled
        case "P":
            Task { await state.runPush() }
            return .handled
        case "p":
            Task { await state.runPull() }
            return .handled
        case "f":
            Task { await state.runFetch() }
            return .handled
        case "r":
            Task { await state.refresh() }
            return .handled
        case "o":
            if state.focusedPanel == .files, let entry = state.primaryEntry { openInEditor(entry.relativePath) }
            return .handled
        case "d":
            if state.focusedPanel == .files { state.requestDiscardSelected() }
            return .handled
        case "?":
            state.helpVisible.toggle()
            return .handled
        case "/":
            state.filterVisible = true
            return .handled
        default: break
        }

        switch press.key {
        case .tab:
            press.modifiers.contains(.shift) ? state.focusPreviousPanel() : state.focusNextPanel()
            return .handled
        case .upArrow:
            state.moveSelectionUp(); return .handled
        case .downArrow:
            state.moveSelectionDown(); return .handled
        case .escape:
            if state.helpVisible { state.helpVisible = false; return .handled }
            if state.filterVisible {
                state.filter = ""
                state.filterVisible = false
                return .handled
            }
            return .ignored
        default: return .ignored
        }
    }
}

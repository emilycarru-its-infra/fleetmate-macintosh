import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import FleetMateCore

/// Hosts a session's terminal and hands it keyboard focus once it is
/// actually in a window — focus asked for before then is silently dropped.
private final class TerminalContainer: NSView {
    var session: AgentTerminalSession?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    func focusIfWanted() {
        guard let session, session.wantsFocus, let window else { return }
        // Deferred: this runs inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async {
            session.wantsFocus = false
            window.makeFirstResponder(session.view)
        }
    }
}

/// The terminal drawn by a session, hosted in SwiftUI. The session owns the
/// view, so the same NSView is re-hosted when the panel reappears.
private struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: AgentTerminalSession

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        container.focusIfWanted()
    }

    private func attach(to container: TerminalContainer) {
        container.session = session
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.focusIfWanted()
    }
}

/// The bottom panel every tab shares. Sessions are a list down the left —
/// name, folder and state on each row — rather than tabs, because ten or
/// fifteen tabs leave nothing readable. With one session the list is docked to
/// its status dot; from two it shows names, unless toggled by hand.
struct AgentTerminalPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AgentTerminalStore
    let repos: [String]
    let defaultLaunch: AgentLaunch
    /// A hand toggle, kept until the number of sessions changes.
    /// The expanded list's width, dragged at its divider and remembered.
    @AppStorage(AgentSettingsKey.listWidth) private var listWidth: Double = 250
    @State private var listDragStart: Double?
    static let listWidthRange: ClosedRange<Double> = 180...520
    @State private var sectionEditor = false
    @State private var editingSection: String?
    @State private var sectionName = ""
    @AppStorage(AgentSettingsKey.filterActive) private var filterActive = false
    @AppStorage(AgentSettingsKey.filterRunning) private var filterRunning = false
    @AppStorage(AgentSettingsKey.filterPaused) private var filterPaused = false
    @AppStorage(AgentSettingsKey.sortMode) private var sortModeRaw = TerminalSessionSort.manual.rawValue
    @State private var searchText = ""
    @State private var savingWorkspace = false
    @State private var workspaceName = ""
    /// The session being dragged in the list, and the row or section it is over.
    @State private var draggingId: AgentTerminalSession.ID?
    @State private var dropTarget: String?

    /// Rows drag as this private type, so a row dropped on a terminal is not pasted as text.
    static let sessionDragType = UTType(exportedAs: "app.fleetmate.terminal-session")

    private var listCollapsed: Bool { store.listCollapsedOverride ?? (store.sessions.count < 2) }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: listCollapsed ? 34 : CGFloat(min(max(listWidth, Self.listWidthRange.lowerBound), Self.listWidthRange.upperBound)))
            listDivider
            HStack(spacing: 0) {
                if let session = store.selected {
                    pane(session)
                }
                if let split = store.split {
                    Divider()
                    pane(split)
                }
            }
        }
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            if let error = store.workspaceError ?? store.workspaceFileError {
                Text(error).font(.caption).padding(6).background(.regularMaterial)
            }
        }
        .onChange(of: store.sessions.count) { _, _ in store.listCollapsedOverride = nil }
        .onAppear(perform: store.reloadWorkspaces)
        // Back from editing the file by hand, or from tracking a repository
        // elsewhere: read both again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.syncBaseline()
        }
    }

    private func pane(_ session: AgentTerminalSession) -> some View {
        TerminalHost(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            Group {
                if listCollapsed {
                    listToggle
                } else {
                    // Narrow, the title gives way before any control does.
                    ViewThatFits(in: .horizontal) {
                        header(titled: true)
                        header(titled: false)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if listCollapsed {
                // Docked: the header has room only for its toggle, so the
                // controls a single session still needs stack under it.
                VStack(spacing: 8) {
                    newSessionMenu
                        .menuIndicator(.hidden)
                        .fixedSize()
                    layoutButton
                    hideButton
                }
                .padding(.bottom, 6)
            }
            if !listCollapsed {
                // Activity changes without the store publishing; read the
                // counts on the same slow tick as the strip.
                TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                    filterBar
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
            }
            Divider()
            ScrollView {
                if listCollapsed || !filter.isFiltering && sortMode == .manual {
                    sectionedRows(filtered: false)
                } else {
                    TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                        if sortMode == .manual { sectionedRows(filtered: true) } else { sortedRows }
                    }
                }
            }
        }
        .background(SwiftUI.Color.secondary.opacity(0.05))
        .popover(isPresented: $savingWorkspace, arrowEdge: .top) {
            AgentNamePopover(title: "Save Workspace", name: $workspaceName,
                             save: {
                                 store.saveWorkspace(named: workspaceName)
                                 savingWorkspace = false
                             },
                             cancel: { savingWorkspace = false })
        }
        // View › Save Sessions as Workspace… asks here, where the name popover can anchor.
        .onChange(of: store.savingWorkspaceRequested) { _, requested in
            guard requested else { return }
            store.savingWorkspaceRequested = false
            beginSavingWorkspace()
        }
    }

    private func header(titled: Bool) -> some View {
        HStack(spacing: 6) {
            if titled {
                Text("Sessions").appFont(.caption, weight: .semibold).foregroundStyle(.secondary).fixedSize()
                Text("\(store.startedSessions.count)").appFont(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    .help("Sessions running")
            }
            Spacer(minLength: 4)
            workspacesMenu
            newSessionMenu
            Button(action: store.toggleSplit) {
                Label("Split", systemImage: store.splitId == nil ? "rectangle.split.2x1" : "rectangle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(store.splitId == nil ? "Split (⌘D)" : "Unsplit (⌘D)")
            layoutButton
            hideButton
            listToggle
        }
    }

    private var listToggle: some View {
        Button(action: { store.listCollapsedOverride = !listCollapsed }) {
            Label("Collapse", systemImage: listCollapsed ? "sidebar.left" : "sidebar.squares.left")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(listCollapsed ? "Show session names (⌃⌘S)" : "Collapse the session list (⌃⌘S)")
        .accessibilityLabel(listCollapsed ? "Show Session List" : "Collapse Session List")
    }

    /// Fill the window, or go back to sharing it with the tab at the height
    /// the terminal had; View › Terminal Full Window does the same.
    private var layoutButton: some View {
        Button {
            store.isMaximized.toggle()
        } label: {
            Label(store.isMaximized ? "Split View" : "Full Window",
                  systemImage: store.isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(store.isMaximized ? "Share the window with the tab (⇧⌘↩)" : "Fill the window with the terminal (⇧⌘↩)")
    }

    /// Hide the terminal; the toolbar's Agent button, ⌘J or ⌃` bring it back.
    private var hideButton: some View {
        Button(action: store.hide) {
            Label("Hide Agent", systemImage: "chevron.down").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Hide the terminal (⌘J or ⌃`)")
    }

    private var sortMode: TerminalSessionSort { TerminalSessionSort(rawValue: sortModeRaw) ?? .manual }

    private var filter: TerminalSessionFilter {
        TerminalSessionFilter(active: filterActive, running: filterRunning, paused: filterPaused, query: searchText)
    }

    private func traits(_ session: AgentTerminalSession) -> TerminalSessionTraits {
        TerminalSessionTraits(isAgent: session.agentIsForeground,
                              isRunning: session.isRunning,
                              isPaused: session.isPaused,
                              searchable: [session.title, session.shortDirectory, session.breadcrumb, session.section,
                                           session.label ?? "", session.programTitle ?? session.launch.label],
                              lastActivity: session.lastActivity)
    }

    private func row(_ session: AgentTerminalSession, index: Int) -> some View {
        SessionRow(session: session, index: index, collapsed: listCollapsed,
                   isSelected: session.id == store.selectedId,
                   isSplit: session.id == store.splitId,
                   sections: store.sections,
                   move: { store.move(session, to: $0) },
                   select: { store.select(session.id) },
                   close: { store.close(session.id) },
                   rename: { store.rename(session, to: $0) },
                   pin: { store.setPinned(session, $0) },)
        // Drag a row onto another to put it there, in that row's section.
        .onDrag {
            draggingId = session.id
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: Self.sessionDragType.identifier, visibility: .ownProcess) { done in
                done(Data(session.id.uuidString.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [Self.sessionDragType], isTargeted: dropBinding("row:\(session.id)")) { _ in
            drop(before: session.id, in: session.section)
        }
        .overlay(alignment: .top) { dropLine(dropTarget == "row:\(session.id)") }
    }

    private func dropBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { dropTarget == key },
                set: { inside in
                    if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
                })
    }

    private func drop(before target: AgentTerminalSession.ID?, in section: String) -> Bool {
        defer { draggingId = nil; dropTarget = nil }
        guard let id = draggingId else { return false }
        store.moveSession(id, before: target, in: section)
        return true
    }

    private func dropLine(_ shown: Bool) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2).opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Workspaces

    private var workspacesMenu: some View {
        Menu {
            AgentWorkspaceMenuContent(store: store, saveSessions: beginSavingWorkspace)
        } label: {
            Label("Workspaces", systemImage: "square.stack.3d.up").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open, save and choose the workspace FleetMate opens at launch")
        .accessibilityLabel("Workspaces")
    }

    private func beginSavingWorkspace() {
        workspaceName = store.workspaceFile.launchWorkspace?.name ?? ""
        savingWorkspace = true
    }

    /// Drag to widen or narrow the session list; double-click collapses or
    /// expands it, as the sidebar button and View › Show Session List do.
    private var listDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if listCollapsed {
                            store.listCollapsedOverride = false
                        }
                        let start = listDragStart ?? (listCollapsed ? Self.listWidthRange.lowerBound : listWidth)
                        listDragStart = start
                        listWidth = min(max(start + value.translation.width, Self.listWidthRange.lowerBound),
                                        Self.listWidthRange.upperBound)
                    }
                    .onEnded { _ in listDragStart = nil }
            )
            .onTapGesture(count: 2) { store.listCollapsedOverride = !listCollapsed }
            .help("Drag to resize the session list; double-click to collapse or expand it")
            .accessibilityElement()
            .accessibilityLabel("Session list divider")
            .accessibilityValue(listCollapsed ? "Collapsed" : "\(Int(listWidth)) points")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: listCollapsed ? "Expand Session List" : "Collapse Session List") {
                store.listCollapsedOverride = !listCollapsed
            }
    }

    /// Open the workspaces file in its editor, or show it in Finder, writing
    /// an empty one first so there is something to edit.
    static func openWorkspacesFile(reveal: Bool) {
        let path = TerminalWorkspaceStore.defaultPath
        if !FileManager.default.fileExists(atPath: path) {
            try? TerminalWorkspaceStore.save(TerminalWorkspaceFile(), to: path)
        }
        let url = URL(fileURLWithPath: path)
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // JSON may have no default app; TextEdit always opens it.
            let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// Sessions under their section headers. Filtered, sections with no
    /// match are left out and the rest open, so a search finds sessions in
    /// a collapsed section too.
    private func sectionedRows(filtered: Bool) -> some View {
        let indexed = Array(store.sessions.enumerated())
        let shown = filtered ? indexed.filter { filter.matches(traits($0.element)) } : indexed
        let pinned = shown.filter { $0.element.pinned }
        return LazyVStack(spacing: 1) {
            // Pinned sessions head the list, out of their own sections.
            if !pinned.isEmpty {
                if !listCollapsed { pinnedHeader }
                if listCollapsed || filtered || !store.collapsedSections.contains(Self.pinnedSection) {
                    ForEach(pinned, id: \.element.id) { index, session in row(session, index: index) }
                }
            }
            ForEach(store.sections, id: \.self) { section in
                let rows = shown.filter { $0.element.section == section && !$0.element.pinned }
                if !(filtered && rows.isEmpty) {
                    if !listCollapsed { sectionHeader(section) }
                    if listCollapsed || filtered || !store.collapsedSections.contains(section) {
                        ForEach(rows, id: \.element.id) { index, session in row(session, index: index) }
                    }
                }
            }
            if filtered && shown.isEmpty { noMatches }
        }
        .padding(4)
    }

    /// One list across sections, by recent activity.
    private var sortedRows: some View {
        let sessions = store.sessions
        let all = sessions.map(traits)
        let order = TerminalSessionFilter.order(all, by: sortMode).filter { filter.matches(all[$0]) }
        return LazyVStack(spacing: 1) {
            ForEach(order, id: \.self) { index in row(sessions[index], index: index) }
            if order.isEmpty { noMatches }
        }
        .padding(4)
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Text("No Matching Sessions").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            Button("Clear Filters", action: clearFilters).controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func clearFilters() {
        filterActive = false
        filterRunning = false
        filterPaused = false
        searchText = ""
    }

    /// Status toggles with neutral counts, the sort menu and search, as in
    /// the sidebar of a terminal workspace app.
    private var filterBar: some View {
        let all = store.sessions.map(traits)
        return HStack(spacing: 2) {
            SessionFilterToggle(symbol: "circle.fill", symbolScale: 0.75, title: "Active",
                                help: "Show only sessions running an agent",
                                count: all.filter(\.isAgent).count, isOn: $filterActive)
            SessionFilterToggle(symbol: "bolt.fill", symbolScale: 1, title: "Running",
                                help: "Show only sessions that are working",
                                count: all.filter(\.isRunning).count, isOn: $filterRunning)
            SessionFilterToggle(symbol: "pause.fill", symbolScale: 1, title: "Paused",
                                help: "Show only agents waiting on you",
                                count: all.filter(\.isPaused).count, isOn: $filterPaused)
            sortMenu
            SessionSearchField(text: $searchText)
                .frame(minWidth: 60, maxWidth: .infinity)
                .frame(height: 22)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort Sessions", selection: $sortModeRaw) {
                ForEach(TerminalSessionSort.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: sortSymbol)
                .foregroundStyle(sortMode == .manual ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 22)
        .help("Sort: \(sortMode.title)")
        .accessibilityLabel("Sort Sessions")
        .accessibilityValue(sortMode.title)
    }

    private var sortSymbol: String {
        switch sortMode {
        case .manual: "arrow.up.arrow.down"
        case .recentFirst: "arrow.up.to.line"
        case .recentLast: "arrow.down.to.line"
        }
    }

    /// The Pinned group's key in the collapsed set; no section can be named it.
    static let pinnedSection = "\u{1}pinned"

    private var pinnedHeader: some View {
        Button {
            if !store.collapsedSections.insert(Self.pinnedSection).inserted { store.collapsedSections.remove(Self.pinnedSection) }
        } label: {
            Label("Pinned", systemImage: store.collapsedSections.contains(Self.pinnedSection) ? "chevron.right" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Pinned")
        .accessibilityValue(store.collapsedSections.contains(Self.pinnedSection) ? "Collapsed" : "Expanded")
    }

    private func sectionHeader(_ section: String) -> some View {
        Button {
            store.toggleCollapsed(section)
        } label: {
            Label(section, systemImage: store.collapsedSections.contains(section) ? "chevron.right" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(6)
        .popover(isPresented: Binding(
            get: { sectionEditor && editingSection == section },
            set: { sectionEditor = $0 }
        ), arrowEdge: .trailing) {
            sectionNameEditor
        }
        .contextMenu {
            if section != "Sessions" {
                Button("Rename Section…") {
                    editingSection = section
                    sectionName = section
                    sectionEditor = true
                }
                Button("Remove Section") { store.removeSection(section) }
            }
            Button("New Section…", action: newSection)
            Divider()
            Button("Move Section Up") { store.moveSection(section, by: -1) }
                .disabled(store.sections.first == section)
            Button("Move Section Down") { store.moveSection(section, by: 1) }
                .disabled(store.sections.last == section)
        }
        // A row dropped on the header goes to the end of the section.
        .onDrop(of: [Self.sessionDragType], isTargeted: dropBinding("section:\(section)")) { _ in
            drop(before: nil, in: section)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(dropTarget == "section:\(section)" ? 0.15 : 0)))
    }

    private var sectionNameEditor: some View {
        AgentNamePopover(title: editingSection == nil ? "New Section" : "Rename Section",
                         name: $sectionName,
                         existingNames: store.sections.filter { $0 != editingSection },
                         save: {
                             if let editingSection { store.renameSection(editingSection, to: sectionName) }
                             else { store.addSection(sectionName) }
                             sectionEditor = false
                         },
                         cancel: { sectionEditor = false })
    }

    private func newSection() {
        editingSection = nil
        sectionName = ""
        sectionEditor = true
        store.listCollapsedOverride = false
    }

    private var newSessionMenu: some View {
        Menu {
            Button("New \(defaultLaunch.label)") { store.open(defaultLaunch) }
            Button("New Section…", action: newSection)
            Divider()
            ForEach(AgentLaunch.installedPresets, id: \.command) { preset in
                Button(preset.label) { store.open(AgentLaunch(command: preset.command)) }
            }
            if !repos.isEmpty {
                Divider()
                Section("Open in repository") {
                    ForEach(repos, id: \.self) { repo in
                        Button((repo as NSString).lastPathComponent) {
                            store.open(AgentLaunch(command: defaultLaunch.command, directory: repo))
                        }
                    }
                }
            }
        } label: {
            Label("New Session", systemImage: "plus").labelStyle(.iconOnly)
        } primaryAction: {
            store.open(defaultLaunch)
        }
        .menuStyle(.borderlessButton)
        .popover(isPresented: Binding(
            get: { sectionEditor && editingSection == nil },
            set: { sectionEditor = $0 }
        ), arrowEdge: .trailing) {
            sectionNameEditor
        }
        .fixedSize()
        .help("New session (⌘T), or choose what it runs")
    }
}

private struct SessionRow: View {
    @ObservedObject var session: AgentTerminalSession
    let index: Int
    let collapsed: Bool
    let isSelected: Bool
    let isSplit: Bool
    let sections: [String]
    let move: (String) -> Void
    let select: () -> Void
    let close: () -> Void
    let rename: (String) -> Void
    let pin: (Bool) -> Void
    @State private var hovered = false
    @State private var renaming = false
    @State private var name = ""

    /// A repository's row that has not started: closing it takes it out of the list.
    private var isBookmark: Bool { !session.isStarted && session.repoDirectory != nil }

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .appFont(fixed: 11.5, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(session.breadcrumb)
                        .appFont(fixed: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if session.isStarted {
                        // Paused reads the terminal's foreground process,
                        // which publishes nothing; look again on a slow tick.
                        TimelineView(.periodic(from: .now, by: 1.5)) { _ in statusLine }
                    } else if session.resume {
                        // Waiting rows show only their outlined dot; one that
                        // will pick its conversation up again says so.
                        Text("Resumes when opened")
                            .appFont(fixed: 9.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if hovered {
                    Button(action: close) {
                        Image(systemName: "xmark").appFont(fixed: 9)
                    }
                    .buttonStyle(.borderless)
                    .help(closeHelp)
                    .accessibilityLabel(closeTitle)
                } else if index < 9 {
                    Text("⌘\(index + 1)").appFont(fixed: 9).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Rename Session…") { name = session.title; renaming = true }
            Button("Use Automatic Name") { rename("") }
                .disabled(session.customTitle.isEmpty)
            Button(session.pinned ? "Unpin" : "Pin") { pin(!session.pinned) }
            Menu("Move to Section") {
                ForEach(sections, id: \.self) { section in
                    Button(section) { move(section) }
                }
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.directory, forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)])
            }
            Divider()
            Button("Scroll to Top") { session.view.scroll(toPosition: 0) }
                .disabled(!session.isStarted)
            Button("Scroll to Bottom") { session.view.scroll(toPosition: 1) }
                .disabled(!session.isStarted)
            Button(closeTitle, action: close)
        }
        .popover(isPresented: $renaming, arrowEdge: .trailing) {
            AgentNamePopover(title: "Rename Session", name: $name,
                             save: { rename(name); renaming = false },
                             cancel: { renaming = false })
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: session.pinned ? "Unpin" : "Pin") { pin(!session.pinned) }
        .accessibilityAction(named: closeTitle, close)
        .help("\(session.title)\n\(session.shortDirectory)\nProgram: \(session.programTitle ?? session.launch.label)")
    }

    private var closeTitle: String {
        if isBookmark { return "Remove from List" }
        return session.repoDirectory != nil ? "Stop Session" : "Close Session"
    }

    private var closeHelp: String {
        if isBookmark { return "Remove this repository from the session list" }
        return session.repoDirectory != nil ? "Stop the session; the repository stays in the list (⌘W)" : "Close session (⌘W)"
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected { return SwiftUI.Color.accentColor.opacity(0.18) }
        if isSplit { return SwiftUI.Color.accentColor.opacity(0.08) }
        return hovered ? SwiftUI.Color.secondary.opacity(0.08) : .clear
    }

    /// Running with a bolt, Paused, Idle or Ended, for a started session.
    private var statusLine: some View {
        let (symbol, text): (String, String) = switch session.status {
        case .running: ("bolt.fill", "Running")
        case .paused: ("pause.fill", "Paused")
        case .idle: ("moon.zzz", "Idle")
        case .exited: ("stop.fill", "Ended")
        case .notStarted: ("", "")
        }
        return Label(text, systemImage: symbol)
            .labelStyle(StatusLabelStyle())
            .appFont(fixed: 9.5)
            .foregroundStyle(session.status == .running ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }

    /// Green while output streams, orange when a session out of sight rang
    /// its bell (an agent waiting on you), grey when idle or ended, an
    /// outline while it has not started.
    @ViewBuilder
    private var statusDot: some View {
        if !session.isStarted {
            Circle().strokeBorder(SwiftUI.Color.secondary.opacity(0.6), lineWidth: 1)
                .frame(width: 7, height: 7).frame(width: 12)
        } else {
            let color: SwiftUI.Color = switch session.activity {
            case .busy: .green
            case .attention: .orange
            case .idle: session.titleWorking ? .green : .secondary.opacity(0.5)
            case .exited: .secondary.opacity(0.2)
            }
            Circle().fill(color).frame(width: 7, height: 7).frame(width: 12)
        }
    }
}

/// An icon and text tight together, for a row's status line.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// The Workspaces menu, in the session list and under View › Terminal Workspaces.
struct AgentWorkspaceMenuContent: View {
    @ObservedObject var store: AgentTerminalStore
    let saveSessions: () -> Void

    var body: some View {
        let file = store.workspaceFile
        if file.workspaces.isEmpty {
            Text("No Saved Workspaces")
            if store.hasRepoCheckouts {
                Button("Create Workspace from Repos") { store.regenerateBaselineWorkspace() }
            } else {
                // Someone with nothing cloned yet: the way to get started.
                Button("Clone a Repository in Repos…") { store.showRepos?() }
            }
        } else {
            Section("Open Workspace") {
                ForEach(file.workspaces, id: \.name) { workspace in
                    Button("\(workspace.name) — \(workspace.sessionCount == 1 ? "1 session" : "\(workspace.sessionCount) sessions")") {
                        store.open(workspace: workspace, show: true)
                    }
                }
            }
        }
        Divider()
        Button("Save Sessions as Workspace…", action: saveSessions)
            .disabled(store.sessions.isEmpty)
        if !file.workspaces.isEmpty {
            Picker("Open at Launch", selection: Binding(
                get: { file.launchWorkspace?.name ?? "" },
                set: { store.setOpenAtLaunch($0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                ForEach(file.workspaces, id: \.name) { Text($0.name).tag($0.name) }
            }
            Menu("Delete Workspace") {
                ForEach(file.workspaces, id: \.name) { workspace in
                    Button(workspace.name) { store.deleteWorkspace(named: workspace.name) }
                }
            }
        }
        Divider()
        Button("Add Missing Repos") { store.addMissingReposToBaseline() }
            .help("Add checked-out repositories the Repos workspace lacks, keeping your edits")
        Button("Regenerate Repos Workspace") { store.regenerateBaselineWorkspace() }
            .help("Rebuild the Repos workspace from your active checkouts; other workspaces are left alone")
        Divider()
        Button("Edit Workspaces File") { AgentTerminalPanel.openWorkspacesFile(reveal: false) }
        Button("Show Workspaces File in Finder") { AgentTerminalPanel.openWorkspacesFile(reveal: true) }
    }
}

/// A status filter: an icon and a neutral count, tinted while it is on.
private struct SessionFilterToggle: View {
    let symbol: String
    let symbolScale: CGFloat
    let title: String
    let help: String
    let count: Int
    @Binding var isOn: Bool
    @State private var hovered = false

    /// One that is on stays clickable so it can be turned off with no matches.
    private var isDisabled: Bool { count == 0 && !isOn }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .appFont(fixed: 10 * symbolScale, weight: .semibold)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if count > 0 {
                    Text("\(count)").appFont(fixed: 10, weight: .medium).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.15)
                          : hovered && !isDisabled ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovered = $0 }
        .help(isOn ? "Show all sessions" : help)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) \(count == 1 ? "session" : "sessions")")
        .accessibilityHint(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A native search field, so clicking it takes the keyboard from the
/// terminal and Escape or its clear button empties it.
private struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SessionSearchField
        init(_ parent: SessionSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "Search"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Search sessions")
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}

/// Lightweight contextual editing keeps the rest of the workspace available.
private struct AgentNamePopover: View {
    let title: String
    @Binding var name: String
    var existingNames: [String] = []
    let save: () -> Void
    let cancel: () -> Void

    private var canSave: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !existingNames.contains(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            AgentNameField(name: $name, submit: { if canSave { save() } }, cancel: cancel)
                .frame(height: 24)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onExitCommand(perform: cancel)
    }
}

/// SwiftUI can leave the terminal as first responder when its context menu
/// closes. Focus the native field after the popover has a window instead.
private struct AgentNameField: NSViewRepresentable {
    @Binding var name: String
    let submit: () -> Void
    let cancel: () -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
                currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AgentNameField

        init(_ parent: AgentNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.name = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        field.delegate = context.coordinator
        field.stringValue = name
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != name { field.stringValue = name }
    }
}

import SwiftUI
import SwiftTerm
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
    @State private var listOverride: Bool?
    @State private var sectionEditor = false
    @State private var editingSection: String?
    @State private var sectionName = ""
    @AppStorage(AgentSettingsKey.filterActive) private var filterActive = false
    @AppStorage(AgentSettingsKey.filterRunning) private var filterRunning = false
    @AppStorage(AgentSettingsKey.filterPaused) private var filterPaused = false
    @AppStorage(AgentSettingsKey.sortMode) private var sortModeRaw = TerminalSessionSort.manual.rawValue
    @State private var searchText = ""

    private var listCollapsed: Bool { listOverride ?? (store.sessions.count < 2) }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: listCollapsed ? 34 : 250)
            Divider()
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
            if let error = store.workspaceError {
                Text(error).font(.caption).padding(6).background(.regularMaterial)
            }
        }
        .onChange(of: store.sessions.count) { _, _ in listOverride = nil }
    }

    private func pane(_ session: AgentTerminalSession) -> some View {
        TerminalHost(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !listCollapsed {
                    Text("Sessions").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    Text("\(store.sessions.count)").appFont(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    newSessionMenu
                    Button(action: store.toggleSplit) {
                        Label("Split", systemImage: store.splitId == nil ? "rectangle.split.2x1" : "rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(store.splitId == nil ? "Split (⌘D)" : "Unsplit (⌘D)")
                }
                Button(action: { listOverride = !listCollapsed }) {
                    Label("Collapse", systemImage: listCollapsed ? "sidebar.left" : "sidebar.squares.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(listCollapsed ? "Show session names" : "Collapse the session list")
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
    }

    private var sortMode: TerminalSessionSort { TerminalSessionSort(rawValue: sortModeRaw) ?? .manual }

    private var filter: TerminalSessionFilter {
        TerminalSessionFilter(active: filterActive, running: filterRunning, paused: filterPaused, query: searchText)
    }

    private func traits(_ session: AgentTerminalSession) -> TerminalSessionTraits {
        TerminalSessionTraits(isAgent: session.agentIsForeground,
                              isRunning: session.isRunning,
                              isPaused: session.isPaused,
                              searchable: [session.title, session.shortDirectory, session.section,
                                           session.programTitle ?? session.launch.label],
                              lastActivity: session.lastActivity)
    }

    private func row(_ session: AgentTerminalSession, index: Int) -> some View {
        SessionRow(session: session, index: index, collapsed: listCollapsed,
                   isSelected: session.id == store.selectedId,
                   isSplit: session.id == store.splitId,
                   sections: store.sections,
                   move: { store.move(session, to: $0) },
                   select: { store.select(session.id) },
                   close: { store.close(session.id) })
    }

    /// Sessions under their section headers. Filtered, sections with no
    /// match are left out and the rest open, so a search finds sessions in
    /// a collapsed section too.
    private func sectionedRows(filtered: Bool) -> some View {
        let indexed = Array(store.sessions.enumerated())
        let shown = filtered ? indexed.filter { filter.matches(traits($0.element)) } : indexed
        return LazyVStack(spacing: 1) {
            ForEach(store.sections, id: \.self) { section in
                let rows = shown.filter { $0.element.section == section }
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

    private func sectionHeader(_ section: String) -> some View {
        Button {
            if !store.collapsedSections.insert(section).inserted { store.collapsedSections.remove(section) }
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
        }
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
        listOverride = false
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
    @State private var hovered = false
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .appFont(fixed: 11.5, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(session.shortDirectory)
                        .appFont(fixed: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 2)
                if hovered {
                    Button(action: close) {
                        Image(systemName: "xmark").appFont(fixed: 9)
                    }
                    .buttonStyle(.borderless)
                    .help("Close session (⌘W)")
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
            Button("Use Automatic Name") { session.customTitle = "" }
                .disabled(session.customTitle.isEmpty)
            Menu("Move to Section") {
                ForEach(sections, id: \.self) { section in
                    Button(section) { move(section) }
                }
            }
            Divider()
            Button("Scroll to Top") { session.view.scroll(toPosition: 0) }
            Button("Scroll to Bottom") { session.view.scroll(toPosition: 1) }
            Button("Close Session", action: close)
        }
        .popover(isPresented: $renaming, arrowEdge: .trailing) {
            AgentNamePopover(title: "Rename Session", name: $name,
                             save: { session.customTitle = name; renaming = false },
                             cancel: { renaming = false })
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .help("\(session.title)\n\(session.shortDirectory)\nProgram: \(session.programTitle ?? session.launch.label)")
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected { return SwiftUI.Color.accentColor.opacity(0.18) }
        if isSplit { return SwiftUI.Color.accentColor.opacity(0.08) }
        return hovered ? SwiftUI.Color.secondary.opacity(0.08) : .clear
    }

    /// Green while output streams, orange when a session out of sight rang
    /// its bell (an agent waiting on you), grey when idle or ended.
    private var statusDot: some View {
        let color: SwiftUI.Color
        switch session.activity {
        case .busy: color = .green
        case .attention: color = .orange
        case .idle: color = .secondary.opacity(0.5)
        case .exited: color = .secondary.opacity(0.2)
        }
        return Circle().fill(color).frame(width: 7, height: 7).frame(width: 12)
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

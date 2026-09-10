import SwiftUI
import FleetMateCore

/// The Manage tab: roster sidebar, the current room's machines, and a
/// detail panel for the one machine that is selected.
struct ManageView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manage: ManageState
    @State private var searchText = ""

    init(manage: ManageState) {
        self.manage = manage
    }

    /// Share of the working area (everything right of the roster) the command
    /// pane takes. HSplitView cannot promise an opening ratio: it reads
    /// idealWidth once, before the window has its final size, and gives every
    /// later pixel to the machine list, so the pane is sized here instead and
    /// the divider is our own.
    @AppStorage("manage.commandPaneFraction") private var commandPaneFraction: Double = 0.52

    var body: some View {
        HSplitView {
            ManageSidebarView(manage: manage, searchText: $searchText)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if manage.hasSelection {
                CommandPaneSplit(fraction: $commandPaneFraction) {
                    MachineListView(manage: manage)
                } trailing: {
                    VStack(spacing: 0) {
                        CommandToolbar(manage: manage)
                        Divider()
                        ResultsView(manage: manage)
                    }
                }
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            if manage.selectedComputerIDs.count == 1, let computer = manage.selectedComputers.first {
                MachineDetailView(manage: manage, computer: computer)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .searchable(text: $searchText, prompt: "Search hostnames, people, serials, asset tags")
        .findFocusesSearchField()
        .onAppCommand { command in
            switch command {
            case .refresh:
                manage.loadRoster()
                manage.loadCommandLibrary()
                if manage.hasSelection { manage.startScan() }
            case .scan:
                manage.startScan()
            case .selectOnline:
                manage.selectOnline()
            default:
                break
            }
        }
        .task {
            if manage.roster.isEmpty && manage.rosterError == nil {
                manage.loadRoster()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if let error = manage.rosterError {
                ContentUnavailableView {
                    Label("Roster not loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    SettingsLink { Text("Open Settings") }
                    Button("Reload") { manage.loadRoster() }
                }
            } else if manage.isLoadingRoster {
                ProgressView("Loading roster…")
            } else {
                ContentUnavailableView {
                    Label("Select a room or group", systemImage: "desktopcomputer.and.macbook")
                } description: {
                    Text("Rooms come from the enrollment roster. Command-click to combine rooms and groups, or search to build a target set.")
                }
            }
        }
    }
}

/// Two panes with a draggable divider whose split is a fraction of the
/// available width, so it opens at the same proportion whatever the window
/// size and remembers where the user left it.
private struct CommandPaneSplit<Leading: View, Trailing: View>: View {
    @Binding var fraction: Double
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    private let minLeading: CGFloat = 340
    private let minTrailing: CGFloat = 420
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let trailingWidth = clampedTrailingWidth(total: total, fraction: fraction)

            HStack(spacing: 0) {
                leading()
                    .frame(width: max(0, total - trailingWidth))
                    .clipped()

                Divider()
                    .overlay {
                        // A wider invisible grab area than the 1pt divider.
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("commandPaneSplit"))
                                    .onChanged { value in
                                        if dragStartFraction == nil { dragStartFraction = fraction }
                                        let startTrailing = clampedTrailingWidth(total: total, fraction: dragStartFraction ?? fraction)
                                        let proposed = startTrailing - value.translation.width
                                        fraction = Double(clampedTrailingWidth(total: total, width: proposed) / max(total, 1))
                                    }
                                    .onEnded { _ in dragStartFraction = nil }
                            )
                    }
                    .zIndex(1)

                trailing()
                    .frame(width: trailingWidth)
                    .clipped()
            }
            .coordinateSpace(name: "commandPaneSplit")
        }
    }

    private func clampedTrailingWidth(total: CGFloat, fraction: Double) -> CGFloat {
        clampedTrailingWidth(total: total, width: total * CGFloat(fraction))
    }

    private func clampedTrailingWidth(total: CGFloat, width: CGFloat) -> CGFloat {
        let upper = max(minTrailing, total - minLeading)
        return min(max(width, minTrailing), upper)
    }
}

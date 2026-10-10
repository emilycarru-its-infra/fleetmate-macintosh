import AppKit
import SwiftUI

/// Decides what the window toolbar gives up first when it runs out of room.
///
/// SwiftUI on the macOS 26 SDK has no say over overflow, and AppKit's default
/// sent the centred module tab bar into the `>>` menu while the current
/// module's own controls stayed. The tab bar is how every module is reached,
/// so it must be the last thing to go: this bridges to the window's
/// `NSToolbar` and ranks its items —
///
/// - the centred tab bar: `.user`, the highest priority;
/// - the window-wide items (history, Graphs, Recent Activity, Agent,
///   Authentication, Search): `.high`;
/// - everything else, which is the visible module's own toolbar: `.low`.
///
/// Before anything overflows, `compactModuleToolbar` has already folded the
/// module's segment switch into a menu; this ranking only decides what goes
/// once even that is too wide.
///
/// It also names the search field's item, which SwiftUI leaves without a
/// label, so the overflow menu and Customize Toolbar show "Search" rather
/// than a bare magnifier.
struct ToolbarPriorityBridge: NSViewRepresentable {
    /// The labels of the window-wide toolbar items, as their `Label` titles.
    static let windowItemLabels: Set<String> = [
        "Back", "Forward", "Graphs", "Recent Activity", "Agent",
        "Authentication", "Search", "Service Principal",
    ]

    /// Run when the search item is chosen from the overflow menu.
    var onSearch: () -> Void

    func makeNSView(context: Context) -> BridgeView {
        BridgeView()
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onSearch = onSearch
        // SwiftUI rebuilds the toolbar's items when the module changes.
        view.scheduleApply()
    }

    final class BridgeView: NSView {
        var onSearch: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var applyPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSToolbar.willAddItemNotification,
                                                object: nil, queue: .main) { [weak self] note in
                guard let self, let toolbar = note.object as? NSToolbar,
                      toolbar === self.window?.toolbar else { return }
                self.scheduleApply()
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.scheduleApply()
            })
            scheduleApply()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Coalesced and deferred: items are announced before they are added.
        func scheduleApply() {
            guard !applyPending else { return }
            applyPending = true
            DispatchQueue.main.async { [weak self] in
                self?.applyPending = false
                self?.apply()
            }
        }

        private func apply() {
            guard let toolbar = window?.toolbar else { return }
            for item in toolbar.items {
                if item.itemIdentifier == .flexibleSpace || item.itemIdentifier == .space {
                    continue
                }
                let priority: NSToolbarItem.VisibilityPriority
                if item.itemIdentifier == toolbar.centeredItemIdentifier {
                    priority = .user
                } else if item.label.isEmpty, let view = item.view, Self.containsTextField(view) {
                    nameSearchItem(item)
                    priority = .high
                } else if ToolbarPriorityBridge.windowItemLabels.contains(item.label) {
                    priority = .high
                    if item.label == "Agent" { useAgentSymbol(item) }
                } else {
                    priority = .low
                }
                if item.visibilityPriority != priority {
                    item.visibilityPriority = priority
                }
            }
        }

        private func nameSearchItem(_ item: NSToolbarItem) {
            item.label = "Search"
            item.paletteLabel = "Search"
            let menuItem = NSMenuItem(title: "Search", action: #selector(searchChosen), keyEquivalent: "")
            menuItem.target = self
            menuItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            item.menuFormRepresentation = menuItem
        }

        /// The overflow menu drew Agent with a generic glyph; it is the
        /// agent symbol everywhere.
        private func useAgentSymbol(_ item: NSToolbarItem) {
            let image = NSImage(systemSymbolName: ContentView.agentSymbol, accessibilityDescription: "Agent")
            if item.image == nil { item.image = image }
            if let menuItem = item.menuFormRepresentation, menuItem.image?.name() != image?.name() {
                menuItem.image = image
                item.menuFormRepresentation = menuItem
            }
        }

        @objc private func searchChosen() {
            onSearch?()
        }

        private static func containsTextField(_ view: NSView) -> Bool {
            if view is NSTextField, (view as? NSTextField)?.isEditable == true { return true }
            return view.subviews.contains(where: containsTextField)
        }
    }
}

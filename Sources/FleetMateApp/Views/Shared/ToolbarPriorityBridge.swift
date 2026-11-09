import AppKit
import SwiftUI

/// Ranks secondary toolbar actions after the module navigation. Search is
/// reserved independently by PinnedSearchTitlebar and never enters overflow.
struct ToolbarPriorityBridge: NSViewRepresentable {
    /// The labels of the window-wide toolbar items, as their `Label` titles.
    static let windowItemLabels: Set<String> = [
        "Back", "Forward", "Graphs", "Recent Activity", "Agent",
        "Authentication", "Search", "Service Principal",
    ]

    func makeNSView(context: Context) -> BridgeView {
        BridgeView()
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        // SwiftUI rebuilds the toolbar's items when the module changes.
        view.scheduleApply()
    }

    final class BridgeView: NSView {
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

    }
}

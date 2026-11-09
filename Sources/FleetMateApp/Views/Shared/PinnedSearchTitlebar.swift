import AppKit
import SwiftUI

/// Search belongs to the window title bar, outside NSToolbar's overflow system.
/// A trailing accessory reserves its width before AppKit lays out toolbar items.
struct PinnedSearchTitlebar: NSViewRepresentable {
    let appState: AppState
    let width: CGFloat

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.configure(appState: appState, width: width)
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        view.detach()
    }

    final class BridgeView: NSView {
        private var accessory: NSTitlebarAccessoryViewController?
        private var hosting: NSHostingView<AnyView>?
        private weak var attachedWindow: NSWindow?
        private var searchState: AppState?
        private var searchWidth: CGFloat = 320

        func configure(appState: AppState, width: CGFloat) {
            searchState = appState
            searchWidth = width
            install()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if attachedWindow !== window { detach() }
            install()
        }

        private func install() {
            guard let window, let searchState else { return }
            let root = AnyView(GlobalSearchToolbarField(width: searchWidth)
                .environmentObject(searchState)
                .padding(.horizontal, 8)
                .frame(width: searchWidth + 16, height: 44))
            if let hosting {
                hosting.rootView = root
                hosting.setFrameSize(NSSize(width: searchWidth + 16, height: 44))
                return
            }
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: searchWidth + 16, height: 44)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.view = hosting
            // A hidden title tells AppKit to reserve accessory width for the toolbar.
            window.titleVisibility = .hidden
            window.addTitlebarAccessoryViewController(accessory)
            self.hosting = hosting
            self.accessory = accessory
            attachedWindow = window
        }

        func detach() {
            if let window = attachedWindow, let accessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            hosting = nil
            attachedWindow = nil
        }
    }
}

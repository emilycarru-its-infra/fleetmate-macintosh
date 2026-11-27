import AppKit
import SwiftUI

extension View {
    /// A popover that closes the way a native transient popover does: on a
    /// click outside it, a menu-bar command, another window becoming key, or
    /// the app going to the background. SwiftUI leaves a popover anchored to a
    /// toolbar item open when a different toolbar item is clicked or the toolbar
    /// is rebuilt by a mode switch, so every popover goes through this.
    @MainActor func autoClosingPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge? = nil,
        keepsOpenForTextFieldClicks: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            content().modifier(PopoverOutsideDismissal(keepsOpenForTextFieldClicks: keepsOpenForTextFieldClicks))
        }
    }

    @MainActor func autoClosingPopover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        popover(item: item, arrowEdge: arrowEdge) { value in
            content(value).modifier(PopoverOutsideDismissal())
        }
    }
}

private struct PopoverOutsideDismissal: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var keepsOpenForTextFieldClicks = false

    func body(content: Content) -> some View {
        content.background(PopoverOutsideWatcher(keepsOpenForTextFieldClicks: keepsOpenForTextFieldClicks, onOutside: { dismiss() }))
    }
}

private struct PopoverOutsideWatcher: NSViewRepresentable {
    let keepsOpenForTextFieldClicks: Bool
    let onOutside: () -> Void

    func makeNSView(context: Context) -> PopoverWatcherView {
        let view = PopoverWatcherView()
        view.keepsOpenForTextFieldClicks = keepsOpenForTextFieldClicks
        view.onOutside = onOutside
        return view
    }

    func updateNSView(_ view: PopoverWatcherView, context: Context) {
        view.onOutside = onOutside
    }
}

final class PopoverWatcherView: NSView {
    var onOutside: (() -> Void)?
    var keepsOpenForTextFieldClicks = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pressedOutside = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWatchers()
        if window != nil { installWatchers() }
    }

    /// The popover's own window, its parent and anything hanging off either
    /// count as inside, so a menu or nested popover opened from the content
    /// does not dismiss it.
    private func isInside(_ candidate: NSWindow?) -> Bool {
        guard let popoverWindow = window, let candidate else { return false }
        var cursor: NSWindow? = candidate
        while let current = cursor {
            if current === popoverWindow { return true }
            cursor = current.parent
        }
        return false
    }

    /// A click that lands in a text field, such as the search field the
    /// popover hangs from, leaves the popover open so typing can go on.
    private func isTextFieldClick(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        var cursor: NSView? = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        while let view = cursor {
            if view is NSTextField || view is NSTextView { return true }
            cursor = view.superview
        }
        return false
    }

    private func installWatchers() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self, let other = note.object as? NSWindow else { return }
                let parent = self.window?.parent
                if !self.isInside(other), other !== parent, other.level == .normal { self.fire() }
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu, menu === NSApp.mainMenu { self?.fire() }
            }
        })
    }

    private func removeWatchers() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        pressedOutside = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedOutside = !isInside(event.window) && !(keepsOpenForTextFieldClicks && isTextFieldClick(event))
        case .leftMouseUp:
            guard pressedOutside else { return }
            pressedOutside = false
            // After the click lands, so a click on the anchor toggles first.
            DispatchQueue.main.async { [weak self] in self?.fire() }
        default:
            break
        }
    }

    private func fire() {
        guard window != nil else { return }
        onOutside?()
    }
}

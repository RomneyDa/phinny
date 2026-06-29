import SwiftUI
import AppKit

/// Adds Page Up/Down and Cmd+Up/Down (plus Home/End) keyboard scrolling to a
/// SwiftUI `ScrollView`. SwiftUI's scroll views don't respond to these keys on
/// their own, and with several scroll containers on one screen there's no notion
/// of a "focused" one, so this targets whichever container the mouse is hovering
/// over (the "active" scroll container).
///
/// Usage: `.scrollKeyboardNavigation()` on the content *inside* a `ScrollView`.
/// It drops a transparent AppKit view into the scroll content, reaches its
/// `enclosingScrollView`, and installs a local key monitor scoped to that view.
extension View {
    func scrollKeyboardNavigation() -> some View {
        background(ScrollKeyCatcher().allowsHitTesting(false))
    }
}

private struct ScrollKeyCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyCatcherView { KeyCatcherView() }
    func updateNSView(_ nsView: KeyCatcherView, context: Context) {}
}

final class KeyCatcherView: NSView {
    private var monitors: [Any] = []
    /// After a programmatic jump we briefly swallow trackpad momentum events that
    /// are still in flight, otherwise the leftover momentum drags the container
    /// back off the top/bottom we just jumped to.
    private var momentumKillUntil: Date?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitors()
        } else if monitors.isEmpty {
            let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
            let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.shouldSwallowMomentum(event) else { return event }
                return nil
            }
            monitors = [key, wheel].compactMap { $0 }
        }
    }

    deinit { removeMonitors() }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        momentumKillUntil = nil
        monitors = []
    }

    /// True for a residual momentum-phase scroll within the kill window, over this
    /// scroll view. User-initiated scrolls (non-empty `phase`) are never swallowed
    /// and they clear the kill window so a fresh flick scrolls immediately.
    private func shouldSwallowMomentum(_ event: NSEvent) -> Bool {
        if !event.phase.isEmpty { momentumKillUntil = nil; return false }
        guard event.momentumPhase != [],
              let deadline = momentumKillUntil, Date() < deadline,
              let scrollView = enclosingScrollView, let window,
              let hit = window.contentView?.hitTest(window.convertPoint(fromScreen: NSEvent.mouseLocation)),
              hit.enclosingScrollView === scrollView
        else { return false }
        return true
    }

    /// Returns true if the event was consumed (this container was hovered and the
    /// key was one we scroll with).
    private func handle(_ event: NSEvent) -> Bool {
        guard let scrollView = enclosingScrollView,
              let window, window.isKeyWindow else { return false }

        // Don't steal keys from a focused text field / editor.
        if window.firstResponder is NSText { return false }

        // Only the *innermost* scroll container under the mouse acts on the key.
        // These monitors are global, so for nested scroll views (the transactions
        // table lives inside the dashboard scroll) every enclosing catcher would
        // otherwise match the same point and race to consume the event. Hit-test
        // the point and require this to be the nearest enclosing scroll view.
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let hit = window.contentView?.hitTest(windowPoint),
              hit.enclosingScrollView === scrollView else { return false }

        let cmd = event.modifierFlags.contains(.command)
        let clip = scrollView.contentView
        let page = clip.bounds.height * 0.9

        switch Int(event.keyCode) {
        case 116: // Page Up
            scroll(scrollView, by: -page); return true
        case 121: // Page Down
            scroll(scrollView, by: page); return true
        case 115: // Home
            scroll(scrollView, to: 0); return true
        case 119: // End
            scroll(scrollView, to: .greatestFiniteMagnitude); return true
        case 126 where cmd: // Cmd + Up
            scroll(scrollView, to: 0); return true
        case 125 where cmd: // Cmd + Down
            scroll(scrollView, to: .greatestFiniteMagnitude); return true
        default:
            return false
        }
    }

    private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        scroll(scrollView, to: scrollView.contentView.bounds.origin.y + delta)
    }

    private func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        let target = min(max(0, y), maxY)
        let point = NSPoint(x: clip.bounds.origin.x, y: target)
        // Suppress any trackpad momentum still arriving so it can't undo the jump.
        momentumKillUntil = Date().addingTimeInterval(0.6)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(point)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

import AppKit
import SwiftUI

/// Reports whether the window holding this view is on screen.
///
/// The menu-bar popover is never torn down: closing it orders its window out
/// with the dashboard still inside, so SwiftUI's onDisappear does not fire. The
/// store went on believing the dashboard was open, re-rendered both charts in
/// the hidden window on every sample and kept the poller's attention on. The
/// window's occlusion state follows ordering in and out, so it is used instead.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var reported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else {
                report(false)
                return
            }
            // Ordering out and closing both change the occlusion state.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportWindowState() }
            }
            reportWindowState()
        }

        private func reportWindowState() {
            guard let window else {
                report(false)
                return
            }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard reported != visible else { return }
            reported = visible
            onChange?(visible)
        }
    }
}

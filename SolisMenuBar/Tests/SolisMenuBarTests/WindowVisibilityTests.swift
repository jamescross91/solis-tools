import AppKit
import SwiftUI
import XCTest

@testable import SolisMenuBar

/// The popover is closed by ordering its window out with the dashboard still
/// inside, which SwiftUI's onDisappear never reported. This drives a real
/// window through the same transitions.
@MainActor
final class WindowVisibilityTests: XCTestCase {
    func testOrderingTheWindowOutAndInIsReported() throws {
        // Occlusion changes arrive as window server events, which only an
        // application processes.
        NSApplication.shared.setActivationPolicy(.accessory)
        var reports: [Bool] = []
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 120, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: Color.clear.background(WindowVisibilityReader { reports.append($0) })
        )
        defer { window.orderOut(nil) }

        window.orderFrontRegardless()
        // A locked screen or a session without a display never makes a window
        // visible, and there is nothing to test there.
        // Asked of the window itself, so a reader that misses the change fails.
        guard waitFor({ window.occlusionState.contains(.visible) }) else {
            throw XCTSkip("No visible window in this session.")
        }
        XCTAssertTrue(waitFor { reports.last == true })

        window.orderOut(nil)
        XCTAssertTrue(waitFor { reports.last == false })

        window.orderFrontRegardless()
        XCTAssertTrue(waitFor { reports.last == true })
        // Attaching to a window not yet on screen may first report false.
        XCTAssertEqual(Array(reports.drop { $0 == false }), [true, false, true])
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
        return condition()
    }
}

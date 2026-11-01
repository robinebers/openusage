import AppKit
import XCTest

/// Pointer events for a view hosted in a quiet window: the real pointer never reaches an offscreen
/// window, so these deliver what AppKit would. Every `point` is top-left based, in the host's
/// coordinates.
@MainActor
extension QuietWindowTestCase {
    func hover(_ point: CGPoint, _ window: NSWindow, _ host: NSView) throws {
        let area = try XCTUnwrap(host.trackingAreas.first, "nothing on the section tracks the pointer")
        host.mouseEntered(with: NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: point.x, y: host.bounds.height - point.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
            userData: nil
        )!)
        send(.mouseMoved, at: point, window, host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    func leave(_ window: NSWindow, _ host: NSView) throws {
        let area = try XCTUnwrap(host.trackingAreas.first, "nothing on the section tracks the pointer")
        host.mouseExited(with: NSEvent.enterExitEvent(
            with: .mouseExited,
            location: NSPoint(x: -10, y: -10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
            userData: nil
        )!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func click(_ point: CGPoint, _ window: NSWindow, _ host: NSView) {
        send(.mouseMoved, at: point, window, host)
        send(.leftMouseDown, at: point, window, host)
        send(.leftMouseUp, at: point, window, host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// SwiftUI counts a double tap by the time that really passes between the clicks, not by the
    /// events' timestamps, so the clicks go back to back: a run loop that stalls between them on a
    /// busy machine would split them into two single taps.
    func doubleClick(_ point: CGPoint, _ window: NSWindow, _ host: NSView) {
        send(.mouseMoved, at: point, window, host)
        for (type, clickCount) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
            window.sendEvent(event(type, at: point, window, host, clickCount: clickCount))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    func drag(from start: CGPoint, _ window: NSWindow, _ host: NSView) {
        let end = CGPoint(x: start.x, y: start.y + 12)
        send(.leftMouseDown, at: start, window, host)
        send(.leftMouseDragged, at: end, window, host)
        send(.leftMouseUp, at: end, window, host)
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, _ window: NSWindow, _ host: NSView, clickCount: Int = 1) {
        window.sendEvent(event(type, at: point, window, host, clickCount: clickCount))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, _ window: NSWindow, _ host: NSView, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: point.x, y: host.bounds.height - point.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : clickCount,
            pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0
        )!
    }
}

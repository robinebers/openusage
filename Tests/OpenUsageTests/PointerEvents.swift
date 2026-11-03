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
    }

    func click(_ point: CGPoint, _ window: NSWindow, _ host: NSView) {
        send(.leftMouseDown, at: point, window, host)
        send(.leftMouseUp, at: point, window, host)
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, _ window: NSWindow, _ host: NSView) {
        window.sendEvent(event(type, at: point, window, host))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, _ window: NSWindow, _ host: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: point.x, y: host.bounds.height - point.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0
        )!
    }
}

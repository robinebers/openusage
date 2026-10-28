import AppKit
import XCTest
@testable import OpenUsage

/// The panel's rounded corners hold for everything drawn in the window, including the dimming AppKit
/// adds over the panel while a sheet such as Add Account is attached.
@MainActor
final class MenuBarPanelCornerTests: QuietWindowTestCase {
    func testContentAndSheetDimmingStayInsideTheRoundedCorners() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = QuietMenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400))
            panel.appearance = NSAppearance(named: appearance)
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.white.cgColor
            panel.contentView = content
            QuietTestProcess.show(panel, in: self)
            let sheet = QuietWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheet.isReleasedWhenClosed = false

            try await Task.sleep(for: .milliseconds(200))
            let plain = try snapshot(of: panel)
            assertCornersClear(plain, appearance, "without a sheet")
            XCTAssertEqual(plain.pixel(atFraction: 0.5, 0.5).red, 255, "\(appearance): content missing")

            panel.beginSheet(sheet) { _ in }
            for _ in 0..<100 where panel.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 320, height: 460)), display: true)
            try await Task.sleep(for: .milliseconds(600))

            let dimmed = try snapshot(of: panel)
            XCTAssertLessThan(dimmed.pixel(atFraction: 0.5, 0.5).red, 250, "\(appearance): sheet dimming not drawn")
            assertCornersClear(dimmed, appearance, "with a sheet attached")
        }
    }

    private func assertCornersClear(_ image: Snapshot, _ appearance: NSAppearance.Name, _ state: String) {
        let corners = [(1, 1), (image.width - 2, 1), (1, image.height - 2), (image.width - 2, image.height - 2)]
        for (x, y) in corners {
            XCTAssertEqual(image.pixel(x, y).alpha, 0, "\(appearance) \(state): corner (\(x), \(y)) is painted")
        }
    }

    /// Renders the window's frame view, the layer every view and AppKit overlay in the panel sits in,
    /// at 2x.
    private func snapshot(of panel: NSWindow) throws -> Snapshot {
        let frameLayer = try XCTUnwrap(panel.contentView?.superview?.layer)
        let scale: CGFloat = 2
        let width = Int(frameLayer.bounds.width * scale)
        let height = Int(frameLayer.bounds.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        frameLayer.render(in: context)
        let data = try XCTUnwrap(context.data)
        return Snapshot(width: width, height: height, bytes: Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4
        )))
    }
}

private struct Snapshot {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> (red: UInt8, alpha: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 3])
    }

    func pixel(atFraction x: Double, _ y: Double) -> (red: UInt8, alpha: UInt8) {
        pixel(Int(Double(width) * x), Int(Double(height) * y))
    }
}

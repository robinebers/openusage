import AppKit
import XCTest
@testable import OpenUsage

/// An available update forces the app icon, with a dot at its top-right, onto the far right of the status
/// item, whatever the strip shows. Without one, the strip is what it was.
@MainActor
final class MenuBarUpdateIconTests: XCTestCase {
    func testAnUpdateWithNothingRunningOutDotsTheAppIconAtItsOwnSize() throws {
        let plain = MenuBarStripRenderer.appIcon
        let dotted = try XCTUnwrap(MenuBarStripRenderer.image(for: MenuBarContent(items: [], updateAvailable: true)))

        XCTAssertEqual(dotted.size, plain.size)
        XCTAssertTrue(dotted.isTemplate)
        let before = try raster(plain)
        let after = try raster(dotted)
        let corner = before.width / 2
        XCTAssertEqual(before.alpha(x: before.width - 3, y: 2), 0)
        XCTAssertEqual(after.alpha(x: after.width - 3, y: 2), 255, "no dot at the top-right")
        for y in 0..<before.height {
            for x in 0..<before.width where x < corner || y > before.height - corner {
                XCTAssertEqual(after.alpha(x: x, y: y), before.alpha(x: x, y: y), "the dot changed the icon outside its corner at \(x),\(y)")
            }
        }
    }

    func testAnUpdateAddsTheDottedAppIconAfterTheOverflow() throws {
        let strip = MenuBarContent(items: [item("claude.session", "Session", "99%"), item("claude.weekly", "Weekly", "87%")], overflow: 7)
        var updated = strip
        updated.updateAvailable = true

        let without = try XCTUnwrap(MenuBarStripRenderer.image(for: strip))
        let with = try XCTUnwrap(MenuBarStripRenderer.image(for: updated))

        XCTAssertGreaterThan(with.size.width, without.size.width + 20, "the app icon drew nothing")
        XCTAssertTrue(with.isTemplate)
        XCTAssertEqual(with.accessibilityDescription, strip.accessibilityText + "; Update available")
        XCTAssertTrue(try lastColumnInk(of: without).contains(try raster(without).height / 2), "the overflow is no longer last")
        let last = try XCTUnwrap(lastColumnInk(of: with).max())
        XCTAssertLessThan(last, try raster(with).height / 2, "the far right is not the icon's top-right dot")
    }

    private func item(_ id: String, _ label: String, _ value: String) -> MenuBarContent.Item {
        MenuBarContent.Item(
            id: id,
            provider: Provider(id: String(id.prefix { $0 != "." }), kind: .claude),
            label: label,
            shortLabel: label,
            value: value
        )
    }

    /// The rows, counted from the top, with ink in the image's rightmost column.
    private func lastColumnInk(of image: NSImage) throws -> [Int] {
        let pixels = try raster(image)
        return (0..<pixels.height).filter { pixels.alpha(x: pixels.width - 1, y: $0) > 0 }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    }

    /// The image drawn at 2x, read top row first.
    private func raster(_ image: NSImage) throws -> Raster {
        let width = Int((image.size.width * 2).rounded(.up))
        let height = Int((image.size.height * 2).rounded(.up))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return Raster(width: width, height: height, bytes: bytes)
    }
}

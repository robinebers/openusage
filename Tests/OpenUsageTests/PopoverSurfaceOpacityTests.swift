import XCTest
import AppKit
@testable import OpenUsage

/// Guards the popover's core invariant: the backdrop and card surfaces are fully opaque, so the data
/// region never shows the desktop through it. This is the regression from `a234aeb` ("restore
/// translucent footer with behind-window glass"), which swapped the opaque tray for a behind-window
/// vibrancy view and shipped translucent in v0.7.0-beta.13. Glass is reserved for the footer chrome;
/// the tray and cards themselves must stay solid in both appearances.
final class PopoverSurfaceOpacityTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    func testTraySurfaceIsFullyOpaqueInBothAppearances() {
        assertOpaque(Theme.trayNSColor, label: "tray")
    }

    // The grouped card is the opaque tray with a translucent `.fill.quaternary` composited on top (see
    // `Theme.cardSurface`), so the card surface is opaque by construction as long as the tray is — which
    // the test above guards. There's no longer a standalone card `NSColor` to assert.

    /// Resolves the dynamic (light/dark) color in each appearance and asserts it is fully opaque.
    private func assertOpaque(_ color: NSColor, label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for name in appearances {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("missing appearance \(name.rawValue)", file: file, line: line)
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                guard let resolved = color.usingColorSpace(.sRGB) else {
                    XCTFail("could not resolve \(label) color in \(name.rawValue)", file: file, line: line)
                    return
                }
                XCTAssertEqual(resolved.alphaComponent, 1, accuracy: 0.0001,
                               "\(label) surface must be fully opaque in \(name.rawValue)",
                               file: file, line: line)
            }
        }
    }
}

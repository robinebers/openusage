import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class BalancedLinesTests: XCTestCase {
    private func text(_ string: String) -> some View {
        Text(string).font(.system(size: 12)).multilineTextAlignment(.center)
    }

    /// Sized to fit with no width offered, as a tooltip is, it keeps short text on one line and wraps long
    /// text within its cap onto as few lines as plain wrapping, each about as wide as the others.
    func testWrapsOntoAsFewLinesOfAboutEqualWidthWithinItsCap() {
        let cap: CGFloat = 264
        let short = "Refresh now (⌘R)"
        XCTAssertEqual(NSHostingView(rootView: BalancedLines(maxWidth: cap) { text(short) }).fittingSize,
                       NSHostingView(rootView: text(short).fixedSize()).fittingSize, "one line keeps its natural size")

        let long = "OpenUsage intelligently displays the usage icons at risk of running out and that require your attention."
        let balanced = NSHostingView(rootView: BalancedLines(maxWidth: cap) { text(long) }).fittingSize
        let plain = NSHostingView(rootView: text(long).frame(width: cap).fixedSize(horizontal: false, vertical: true)).fittingSize
        let oneLine = NSHostingView(rootView: text(long).fixedSize()).fittingSize.width
        XCTAssertEqual(balanced.height, plain.height, accuracy: 0.5, "no more lines than plain wrapping")
        let lines = (oneLine / cap).rounded(.up)
        XCTAssertLessThan(balanced.width, oneLine / lines + 30, "each line is about an equal share of the text")
    }
}

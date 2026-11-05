import SwiftUI
import XCTest
import os
@testable import OpenUsage

@MainActor
final class CapsuleSegmentsTests: QuietWindowTestCase {
    /// Only the thumb slides: the content a segment picks swaps at once, as under a native segmented
    /// control. It used to change inside the thumb's spring, which cross-faded Priority and All Usage.
    func testPickingASegmentSwapsTheContentWithoutAnimating() async throws {
        let model = SegmentModel()
        let (window, host) = show(SegmentsAndContent(model: model), in: .borderless, size: CGSize(width: 200, height: 60))

        click(CGPoint(x: 150, y: 14), window, host)
        try await waitUntil { model.selection == "B" }
        try await Task.sleep(for: .milliseconds(150))

        let inBetween = ContentProgress.inBetween.withLock { $0 }
        XCTAssertTrue(inBetween.isEmpty, "the picked content animated in through \(inBetween.prefix(3))")
    }
}

@MainActor
@Observable
private final class SegmentModel {
    var selection = "A"
}

private struct SegmentsAndContent: View {
    let model: SegmentModel

    var body: some View {
        VStack(spacing: 0) {
            CapsuleSegments(options: [("A", "A"), ("B", "B")], selection: Bindable(model).selection)
            Text(model.selection)
                .modifier(ContentProgress(value: model.selection == "B" ? 1 : 0))
        }
        .frame(width: 200)
    }
}

/// Records every value between the content's two states that an animation would pass through.
private struct ContentProgress: GeometryEffect {
    static let inBetween = OSAllocatedUnfairLock(initialState: [Double]())
    var value: Double

    var animatableData: Double {
        get { value }
        set {
            value = newValue
            if newValue > 0, newValue < 1 { Self.inBetween.withLock { $0.append(newValue) } }
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform() }
}

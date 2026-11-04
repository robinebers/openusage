import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

struct InkMap {
    private let inked: [Bool]
    let width: Int
    let height: Int
    let scale: CGFloat

    @MainActor
    init(rendering content: some View, width: CGFloat, scale: CGFloat = 1) throws {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let data = rep.bitmapData!
        let bytesPerPixel = rep.bitsPerPixel / 8
        self.width = rep.pixelsWide
        self.height = rep.pixelsHigh
        self.scale = scale
        var map = [Bool](repeating: false, count: self.width * self.height)
        for y in 0..<self.height {
            let reference = (0..<bytesPerPixel).map { data[y * rep.bytesPerRow + Int(6 * scale) * bytesPerPixel + $0] }
            for x in 0..<self.width {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                map[y * self.width + x] = (0..<bytesPerPixel).contains {
                    abs(Int(data[offset + $0]) - Int(reference[$0])) > 40
                }
            }
        }
        inked = map
    }

    func count(x: Range<CGFloat>, y: Range<CGFloat>) -> Int {
        var count = 0
        for row in pixels(y, limit: height) {
            for column in pixels(x, limit: width) where inked[row * width + column] { count += 1 }
        }
        return count
    }

    private func pixels(_ points: Range<CGFloat>, limit: Int) -> Range<Int> {
        let lower = max(0, Int(points.lowerBound * scale))
        return lower..<max(lower, min(limit, Int(points.upperBound * scale)))
    }
}

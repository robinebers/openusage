import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

struct InkMap {
    enum Background {
        case topLeft
        case column(CGFloat)
    }

    private let inked: [Bool]
    let width: Int
    let height: Int
    let scale: CGFloat

    init(_ rep: NSBitmapImageRep, size: CGSize, threshold: Int = 24, background: Background = .topLeft) {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let scale = CGFloat(rep.pixelsWide) / size.width
        let data = rep.bitmapData!
        let bytesPerPixel = rep.bitsPerPixel / 8
        var map = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let reference: [UInt8] = switch background {
            case .topLeft: (0..<bytesPerPixel).map { data[$0] }
            case .column(let x): (0..<bytesPerPixel).map { data[y * rep.bytesPerRow + Int(x * scale) * bytesPerPixel + $0] }
            }
            for x in 0..<width {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                map[y * width + x] = (0..<bytesPerPixel).contains {
                    abs(Int(data[offset + $0]) - Int(reference[$0])) > threshold
                }
            }
        }
        inked = map
        self.width = width
        self.height = height
        self.scale = scale
    }

    @MainActor
    init(of host: NSView, threshold: Int = 24, background: Background = .topLeft) {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        self.init(rep, size: host.bounds.size, threshold: threshold, background: background)
    }

    @MainActor
    init(rendering content: some View, width: CGFloat, scale: CGFloat = 1) throws {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        self.init(NSBitmapImageRep(cgImage: image), size: size, threshold: 40, background: .column(6))
    }

    func count(x: Range<CGFloat>, y: Range<CGFloat>) -> Int {
        var count = 0
        for row in pixels(y, limit: height) {
            for column in pixels(x, limit: width) where inked[row * width + column] { count += 1 }
        }
        return count
    }

    func bounds(y: Range<CGFloat>) -> CGRect? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in pixels(y, limit: height) {
            for column in 0..<width where inked[row * width + column] {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func pixels(_ points: Range<CGFloat>, limit: Int) -> Range<Int> {
        let lower = max(0, Int(points.lowerBound * scale))
        return lower..<max(lower, min(limit, Int(points.upperBound * scale)))
    }
}

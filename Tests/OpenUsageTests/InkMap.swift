import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Which pixels of a render are ink: those that differ from the background by more than `threshold` in
/// any channel. Positions are points from the top-left corner.
struct InkMap {
    /// The pixel the others are measured against.
    enum Background {
        /// The top-left pixel.
        case topLeft
        /// Each row's pixel this many points in, for a render whose rows differ (a card's rounded edge).
        case column(CGFloat)
        /// Opaque white, for a view drawn on white in a window whose edge pixels are transparent: a
        /// transparent pixel is not ink.
        case white
    }

    struct Span {
        /// The x (or y) of the first and last ink, in points.
        let first: CGFloat
        let last: CGFloat
        var width: CGFloat { last - first }
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
            case .white: [UInt8](repeating: 255, count: bytesPerPixel)
            }
            for x in 0..<width {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                if case .white = background, bytesPerPixel == 4, data[offset + 3] <= 200 { continue }
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

    /// `host` as drawn now.
    @MainActor
    init(of host: NSView, threshold: Int = 24, background: Background = .topLeft) {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        self.init(rep, size: host.bounds.size, threshold: threshold, background: background)
    }

    /// `content` rendered offscreen in light mode at `width`, its ink read against each row's pixel 6 pt in,
    /// where only a card's rounded edge can be.
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

    /// The box around the inked pixels of the rows in `y`, or nil when there are none.
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

    /// The first and last ink between two x positions in points (the whole width by default), or `nil`
    /// when there is none.
    func span(from start: CGFloat = 0, to end: CGFloat? = nil) -> Span? {
        let columns = pixels(start..<(end ?? CGFloat(width) / scale), limit: width)
        let inked = columns.filter { x in (0..<height).contains { self.inked[$0 * width + x] } }
        guard let first = inked.first, let last = inked.last else { return nil }
        return Span(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale)
    }

    /// The first and last ink row between two x positions, in points from the top.
    func rows(from start: CGFloat, to end: CGFloat) -> Span? {
        let columns = pixels(start..<end, limit: width)
        let inked = (0..<height).filter { y in columns.contains { self.inked[y * width + $0] } }
        guard let first = inked.first, let last = inked.last else { return nil }
        return Span(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale)
    }

    /// Each horizontal band of ink, top to bottom: a line of text, or the provider's mark. The 6 pt at
    /// either side hold only a grouped box's rounded edge, and so do bands under 4 pt tall, so neither
    /// counts.
    func bands() -> [Span] {
        let edge = Int(6 * scale)
        var bands: [Span] = []
        var top: Int?
        var first = Int.max, last = Int.min
        for y in 0...height {
            let ink = y < height ? (edge..<(width - edge)).filter { inked[y * width + $0] } : []
            if let x = ink.first, let end = ink.last {
                top = top ?? y
                first = min(first, x)
                last = max(last, end)
            } else if let start = top {
                if CGFloat(y - start) >= 4 * scale {
                    bands.append(Span(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale))
                }
                top = nil
                first = .max
                last = .min
            }
        }
        return bands
    }

    private func pixels(_ points: Range<CGFloat>, limit: Int) -> Range<Int> {
        let lower = max(0, Int(points.lowerBound * scale))
        return lower..<max(lower, min(limit, Int(points.upperBound * scale)))
    }
}

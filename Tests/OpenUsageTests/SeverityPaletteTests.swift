import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class SeverityPaletteTests: XCTestCase {
    private let d: TimeInterval = 86400

    private static let palette: [(WidgetData.MeterSeverity, String)] = [
        (.normal, "systemBlue"), (.warning, "systemOrange"), (.critical, "systemRed"),
    ]

    private static let candidates: [(String, NSColor)] = [
        ("systemBlue", .systemBlue), ("systemOrange", .systemOrange), ("systemRed", .systemRed),
        ("systemYellow", .systemYellow), ("controlAccent", .controlAccentColor),
        ("swiftUIOrange", NSColor(Color.orange)), ("swiftUIRed", NSColor(Color.red)),
    ]

    func testEachSeverityMapsToItsSystemColour() {
        for (severity, name) in Self.palette {
            XCTAssertEqual(Self.nearest(NSColor(Theme.severityColor(severity))), name, "\(severity)")
        }
    }

    func testMeterValueTimelineDotAndBannerAgree() throws {
        for (severity, name) in Self.palette {
            let meter = UsageMeterBar(fill: 1, severity: severity).frame(width: 60)
            XCTAssertEqual(try dominant(meter), name, "meter \(severity)")

            if severity != .normal {
                let row = DashboardMetricRow(model: DashboardRowModel(label: "Weekly", mark: .bar(fill: 0, severity: severity, value: "0%", reset: "1d 8h")))
                    .frame(width: 292)
                XCTAssertEqual(try dominant(row), name, "value \(severity)")
                let count = DashboardMetricRow(model: DashboardRowModel(label: "Limit Resets", mark: .value("2 available", severity: severity)))
                    .frame(width: 292)
                XCTAssertEqual(try dominant(count), name, "count \(severity)")
            }
            if severity == .critical {
                let flame = DashboardMetricRow(model: DashboardRowModel(label: "Weekly", mark: .bar(fill: 0, severity: .normal, value: "60%", reset: "1d 8h", flame: true)))
                    .frame(width: 292)
                XCTAssertEqual(try dominant(flame), name, "flame")
            }

            let expiry = Date().addingTimeInterval(expiryOffset(severity))
            let timeline = RateLimitResetsDetail(count: 1, expiries: [expiry], onHoverChange: { _ in })
            XCTAssertEqual(try dominant(timeline), name, "timeline dot \(severity)")
        }

        let banners: [(ResetClaimOutcome, String)] = [
            (.nothingToReset, "systemBlue"), (.unavailableNow(until: nil), "systemOrange"), (.failed(.refused), "systemRed"),
        ]
        for (outcome, name) in banners {
            XCTAssertEqual(Self.nearest(NSColor(RateLimitResetsDetail.banner(for: outcome).tint)), name, "banner \(outcome)")
        }
    }

    func testSourcesNeverUseYellow() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let banned = try NSRegularExpression(pattern: #"systemYellow|\.yellow\b"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hit = banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertNil(hit, "\(file.lastPathComponent) uses yellow; take the warning colour from Theme.severityColor")
        }
    }

    private func expiryOffset(_ severity: WidgetData.MeterSeverity) -> TimeInterval {
        switch severity {
        case .critical: return 1 * d
        case .warning: return 5 * d
        case .normal: return 20 * d
        }
    }

    private func dominant(_ view: some View) throws -> String {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var counts: [UInt32: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] == 255 {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            guard Int(max(r, g, b)) - Int(min(r, g, b)) > 64 else { continue }
            counts[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), default: 0] += 1
        }
        let key = try XCTUnwrap(counts.max { $0.value < $1.value }?.key, "no saturated pixels")
        let rgb = SIMD3(Double(key >> 16 & 0xFF), Double(key >> 8 & 0xFF), Double(key & 0xFF)) / 255
        return Self.nearest(rgb)
    }

    private static func nearest(_ color: NSColor) -> String {
        nearest(resolve(color, .aqua))
    }

    private static func nearest(_ rgb: SIMD3<Double>) -> String {
        candidates.min { distance(rgb, $0.1) < distance(rgb, $1.1) }!.0
    }

    private static func distance(_ rgb: SIMD3<Double>, _ color: NSColor) -> Double {
        [NSAppearance.Name.aqua, .darkAqua].map { name in
            let delta = resolve(color, name) - rgb
            return (delta * delta).sum()
        }.min()!
    }

    private static func resolve(_ color: NSColor, _ appearance: NSAppearance.Name) -> SIMD3<Double> {
        var rgb = SIMD3<Double>(repeating: -1)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            rgb = SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return rgb
    }
}

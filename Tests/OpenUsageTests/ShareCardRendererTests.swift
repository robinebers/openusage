import AppKit
import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    func testProviderScreenshotRedactsEmailButIncludesACustomName() throws {
        func png(label: String?) throws -> Data {
            var provider = MockData.claude
            provider.accountLabel = label
            let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
            let account = DashboardAccount(provider: provider, lines: lines)
            let family = DashboardFamily(id: provider.id, provider: provider, accounts: [account])
            let card = ShareCardView(family: family, appearance: .light)
            return try XCTUnwrap(ShareCardRenderer.png(for: card))
        }

        let redacted = try png(label: "private@example.com")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: redacted))
        // Without a plan the caption exists only when the account's name is printed.
        let unnamed = try XCTUnwrap(NSBitmapImageRep(data: try png(label: nil)))
        let named = try XCTUnwrap(NSBitmapImageRep(data: try png(label: "Work")))
        XCTAssertEqual(bitmap.pixelsHigh, unnamed.pixelsHigh)
        XCTAssertGreaterThan(named.pixelsHigh, bitmap.pixelsHigh)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(ShareCardView.width))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertTrue(redacted.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testEveryShareImageEndsInATintedBandWithTheTagline() throws {
        let provider = MockData.claude
        let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
        let family = DashboardFamily(id: provider.id, provider: provider, accounts: [DashboardAccount(provider: provider, lines: lines)])
        let board = PriorityBoard.make(accounts: family.accounts, pinned: Set(lines.prefix(1).map(\.id)), now: Date())

        for appearance in [ColorScheme.light, .dark] {
            let cards: [(String, AnyView)] = [
                ("account", AnyView(ShareCardView(family: family, appearance: appearance))),
                ("priority", AnyView(PriorityShareCard(board: board, now: Date(), appearance: appearance))),
            ]
            for (name, card) in cards {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: card))))
                let body = try rgb(bitmap, x: 2, y: 2)
                let band = try rgb(bitmap, x: 2, y: bitmap.pixelsHigh - 2)
                XCTAssertNotEqual(band, body, "\(name) \(appearance): the footer has no band of its own")

                let text = try recognizedText(in: try XCTUnwrap(bitmap.cgImage)).lowercased()
                XCTAssertTrue(text.contains("limits at a glance"), "\(name) \(appearance) reads: \(text)")
                XCTAssertFalse(text.contains("monitor your"), "\(name) \(appearance) reads: \(text)")
            }
        }
    }

    private func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Int] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

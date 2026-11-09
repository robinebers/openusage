import AppKit
import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func cards(label: String?, blursAccountNames: Bool) throws -> [NSBitmapImageRep] {
        var provider = MockData.claude
        provider.accountLabel = label
        let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
        let family = DashboardFamily(id: provider.id, provider: provider, accounts: [DashboardAccount(provider: provider, lines: lines)])
        let board = PriorityBoard.make(accounts: family.accounts, pinned: Set(lines.prefix(1).map(\.id)), now: Date())
        return try [
            AnyView(ShareCardView(family: family, appearance: .light, blursAccountNames: blursAccountNames)),
            AnyView(PriorityShareCard(board: board, now: Date(), appearance: .light, blursAccountNames: blursAccountNames)),
        ].map { try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: $0)))) }
    }

    func testWithTheSettingOffACopiedCardLeavesAnEmailOutAndPrintsACustomName() throws {
        let email = try XCTUnwrap(cards(label: "private@example.com", blursAccountNames: false).first)
        let unnamed = try XCTUnwrap(cards(label: nil, blursAccountNames: false).first)
        let named = try XCTUnwrap(cards(label: "Sunstory Studio", blursAccountNames: false).first)
        XCTAssertEqual(email.pixelsHigh, unnamed.pixelsHigh, "the email's caption is left out")
        XCTAssertGreaterThan(named.pixelsHigh, email.pixelsHigh)
        XCTAssertFalse(try recognizedText(in: try XCTUnwrap(email.cgImage)).lowercased().contains("example"))
        XCTAssertTrue(try recognizedText(in: try XCTUnwrap(named.cgImage)).lowercased().contains("sunstory"))
    }

    func testWithTheSettingOnCopiedCardsBlurEveryAccountNameInItsRow() throws {
        let unnamed = try cards(label: nil, blursAccountNames: true)
        for label in ["private@example.com", "Sunstory Studio"] {
            for (card, plain) in zip(try cards(label: label, blursAccountNames: true), unnamed) {
                let text = try recognizedText(in: try XCTUnwrap(card.cgImage)).lowercased()
                for word in label.lowercased().split(whereSeparator: { "@. ".contains($0) }) where word.count > 3 {
                    XCTAssertFalse(text.contains(word), "\(label) reads: \(text)")
                }
                XCTAssertTrue(text.contains("session"), text)
                XCTAssertGreaterThanOrEqual(card.pixelsHigh, plain.pixelsHigh, "the name keeps its row, blurred")
            }
        }
    }

    func testThePanelBlursEveryAccountNameOnlyWhileConcealing() throws {
        func reads(_ label: String, concealing: Bool) throws -> String {
            let row = AccountListRow(provider: Provider(id: "codex@1", kind: .codex, accountLabel: label), grip: { EmptyView() })
                .frame(width: ShareCardView.width)
                .background(.white)
                .environment(\.colorScheme, .light)
                .environment(\.concealsAccountNames, concealing)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: row))))
            return try recognizedText(in: try XCTUnwrap(bitmap.cgImage)).lowercased()
        }

        for (label, word) in [("private@example.com", "example"), ("Sunstory Studio", "sunstory")] {
            XCTAssertTrue(try reads(label, concealing: false).contains(word), "nothing blurs without a capture")
            let concealed = try reads(label, concealing: true)
            XCTAssertFalse(concealed.contains(word), concealed)
            XCTAssertTrue(concealed.contains("chatgpt"), "the provider's name stays readable: \(concealed)")
        }
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

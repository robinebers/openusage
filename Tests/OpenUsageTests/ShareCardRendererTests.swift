import AppKit
import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    func testCopiedCardsBlurAnEmailNameInItsRowAndKeepACustomName() throws {
        func cards(label: String) throws -> [NSBitmapImageRep] {
            var provider = MockData.claude
            provider.accountLabel = label
            let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
            let family = DashboardFamily(id: provider.id, provider: provider, accounts: [DashboardAccount(provider: provider, lines: lines)])
            let board = PriorityBoard.make(accounts: family.accounts, pinned: Set(lines.prefix(1).map(\.id)), now: Date())
            return try [
                AnyView(ShareCardView(family: family, appearance: .light)),
                AnyView(PriorityShareCard(board: board, now: Date(), appearance: .light)),
            ].map { try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: $0)))) }
        }

        let email = try cards(label: "private@example.com")
        let named = try cards(label: "Sunstory Studio")
        for (email, named) in zip(email, named) {
            XCTAssertEqual(email.pixelsHigh, named.pixelsHigh, "the email keeps its row, blurred")
            let blurred = try recognizedText(in: try XCTUnwrap(email.cgImage)).lowercased()
            XCTAssertFalse(blurred.contains("example"), blurred)
            XCTAssertFalse(blurred.contains("private"), blurred)
            let custom = try recognizedText(in: try XCTUnwrap(named.cgImage)).lowercased()
            XCTAssertTrue(custom.contains("sunstory"), custom)
        }
    }

    func testThePanelBlursOnlyAnEmailNameAndOnlyWhileConcealing() throws {
        func reads(_ label: String, concealing: Bool) throws -> String {
            let row = AccountListRow(provider: Provider(id: "codex@1", kind: .codex, accountLabel: label), grip: { EmptyView() })
                .frame(width: ShareCardView.width)
                .background(.white)
                .environment(\.colorScheme, .light)
                .environment(\.concealsEmails, concealing)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: row))))
            return try recognizedText(in: try XCTUnwrap(bitmap.cgImage)).lowercased()
        }

        XCTAssertTrue(try reads("private@example.com", concealing: false).contains("example.com"))
        let concealed = try reads("private@example.com", concealing: true)
        XCTAssertFalse(concealed.contains("example"), concealed)
        XCTAssertTrue(concealed.contains("chatgpt"), "only the name blurs: \(concealed)")
        XCTAssertTrue(try reads("Sunstory Studio", concealing: true).contains("sunstory"))
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

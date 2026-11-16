import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Optional, reproducible PR evidence. These fixtures contain no account names or email addresses.
@MainActor
final class MenuBarEvidenceTests: XCTestCase {
    func testHealthyClassicStripAndExportEvidence() throws {
        let accounts = [
            account(.claude, values: [10, 40]),
            account(.codex, values: [17, 28]),
            account(.cursor, keys: ["auto", "api"], values: [24, 46]),
        ]
        let board = PriorityBoard.make(accounts: accounts, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(board.pinned.isEmpty && board.attention.isEmpty && board.useItOrLoseIt.isEmpty && board.usedUp.isEmpty)
        let classic = MenuBarContentBuilder.build(board: board, limit: .upToThree, alwaysShows: true)
        XCTAssertEqual(classic.groups.count, 3)
        XCTAssertEqual(classic.items.map(\.value), ["90%", "60%", "83%", "72%", "76%", "54%"])
        XCTAssertEqual(classic.groups.map { $0.items.count }, [2, 2, 2])
        let image = try XCTUnwrap(MenuBarStripRenderer.image(for: classic))
        XCTAssertLessThanOrEqual(image.size.height, 22)

        guard let directory = ProcessInfo.processInfo.environment["OPENUSAGE_EVIDENCE_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // On main, Always Show combined only these four empty Priority sections, producing the app icon.
        try export(MenuBarStripRenderer.appIcon, title: "Before: Main", to: destination.appendingPathComponent("before.png"))
        try export(image, title: "After: Classic Provider Strip", to: destination.appendingPathComponent("after.png"))
    }

    private func account(_ kind: ProviderKind, keys: [String] = ["session", "weekly"], values: [Double]) -> DashboardAccount {
        let provider = Provider(id: kind.rawValue, kind: kind)
        return DashboardAccount(provider: provider, lines: zip(keys, values).map { key, used in
            var data = WidgetData(title: key.capitalized, kind: .percent, used: used, limit: 100)
            data.displayMode = .remaining
            let descriptor = WidgetDescriptor(provider: provider, key: key, metricLabel: data.title, sample: data)
            return DashboardLine(descriptor: descriptor, data: data)
        })
    }

    private func export(_ image: NSImage, title: String, to url: URL) throws {
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text("Always Show: On  ·  Max Items: 3  ·  Usage: Left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Image(nsImage: image).renderingMode(.template)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))
            Text("Synthetic test data · No accounts or email addresses")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class UsageHistoryClassificationTests: XCTestCase {
    func testEverySpendProviderHasOneExplicitHistoryClassification() {
        let descriptorSets = [
            ClaudeProvider().widgetDescriptors,
            CodexProvider().widgetDescriptors,
            CursorProvider().widgetDescriptors,
            GrokProvider().widgetDescriptors,
            OpenCodeProvider().widgetDescriptors
        ]

        for descriptors in descriptorSets {
            XCTAssertTrue(descriptors.contains(where: \.isSpendTile))
            XCTAssertEqual(descriptors.compactMap(\.historyResource).count, 1)
        }

        let classifications = Dictionary(uniqueKeysWithValues: descriptorSets.compactMap { descriptors in
            descriptors.compactMap(\.historyResource).first.map { (descriptors[0].providerID, $0.scope) }
        })
        XCTAssertEqual(classifications, [
            "claude": .machineLocal,
            "codex": .machineLocal,
            "cursor": .accountWide,
            "grok": .machineLocal,
            "opencode": .machineLocal
        ])
    }
}

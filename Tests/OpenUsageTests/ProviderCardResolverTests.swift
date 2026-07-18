import XCTest
@testable import OpenUsage

/// Pins `ProviderCardResolver`'s alias rule ORDER (default-source holder → sole enabled family card →
/// family empty state) so multi-account phases only swap the inputs, never the semantics.
final class ProviderCardResolverTests: XCTestCase {
    func testNonFamilyIDsPassThroughUntouched() {
        let resolver = ProviderCardResolver.make(
            registryProviderIDs: ["claude", "codex", "cursor"],
            defaultResolvedFamilyIDs: ["claude"],
            isProviderEnabled: { _ in true }
        )
        XCTAssertEqual(resolver.resolve("cursor"), "cursor")
        XCTAssertEqual(resolver.resolve("claude@ab12cd34"), "claude@ab12cd34", "direct card ids are addressed directly")
        XCTAssertEqual(resolver.resolve("nonsense"), "nonsense", "unknown ids fall through to the caller's 404")
    }

    func testDefaultSourceHolderWinsEvenWhenDisabled() {
        // Rule 1 beats rule 2: with a resolved default login, the bare id answers with the holder's
        // card even when several family cards are enabled — or none.
        let resolver = ProviderCardResolver.make(
            registryProviderIDs: ["claude", "claude@ab12cd34"],
            defaultResolvedFamilyIDs: ["claude"],
            isProviderEnabled: { _ in false }
        )
        XCTAssertEqual(resolver.resolve("claude"), "claude")
    }

    func testSoleEnabledFamilyCardAnswersWhenNoDefaultLoginExists() {
        let resolver = ProviderCardResolver.make(
            registryProviderIDs: ["claude", "claude@ab12cd34", "codex"],
            defaultResolvedFamilyIDs: [],
            isProviderEnabled: { $0 == "claude@ab12cd34" }
        )
        XCTAssertEqual(resolver.resolve("claude"), "claude@ab12cd34")
    }

    func testFamilyEmptyStateFallsBackToTheBareID() {
        // No default login and zero (or several) enabled family cards: the bare id answers itself.
        let none = ProviderCardResolver.make(
            registryProviderIDs: ["claude", "claude@ab12cd34"],
            defaultResolvedFamilyIDs: [],
            isProviderEnabled: { _ in false }
        )
        XCTAssertEqual(none.resolve("claude"), "claude")

        let several = ProviderCardResolver.make(
            registryProviderIDs: ["claude", "claude@ab12cd34"],
            defaultResolvedFamilyIDs: [],
            isProviderEnabled: { _ in true }
        )
        XCTAssertEqual(several.resolve("claude"), "claude", "an ambiguous family never guesses")
    }
}

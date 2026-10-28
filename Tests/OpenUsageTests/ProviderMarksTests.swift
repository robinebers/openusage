import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testEveryBundledMarkLoadsNativelyAtANonZeroSize() throws {
        let urls = try XCTUnwrap(Bundle.openUsageResources.urls(forResourcesWithExtension: "svg", subdirectory: "ProviderIcons"))
        let ids = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertTrue(ids.isSuperset(of: ProviderKind.allCases.map(\.rawValue) + ["openusage"]), "\(ids.sorted())")
        for id in ids.sorted() {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load")
            XCTAssertGreaterThan(mark.bounds.width, 0, id)
            XCTAssertGreaterThan(mark.bounds.height, 0, id)
        }
    }
}

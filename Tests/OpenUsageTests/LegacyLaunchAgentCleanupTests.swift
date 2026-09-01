import XCTest
@testable import OpenUsage

final class LegacyLaunchAgentCleanupTests: XCTestCase {
    // MARK: - Removal decision (pure)

    func testRemovalRequiresAProgramInsideTheCurrentAppBundle() {
        let bundle = "/Applications/OpenUsage.app"
        let scenarios: [(name: String, program: String?, bundle: String, remove: Bool)] = [
            ("legacy lowercase executable", "\(bundle)/Contents/MacOS/openusage", bundle, true),
            ("current executable", "\(bundle)/Contents/MacOS/OpenUsage", bundle, true),
            ("foreign executable", "/usr/local/bin/openusage", bundle, false),
            ("missing executable", nil, bundle, false),
            ("unbundled development build", "/Users/dev/.build/OpenUsage", "/Users/dev/.build", false),
            ("sibling with matching prefix", "\(bundle)2/Contents/MacOS/openusage", bundle, false),
            ("bundle itself", bundle, bundle, false)
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                LegacyLaunchAgentCleanup.shouldRemove(programPath: scenario.program, bundlePath: scenario.bundle),
                scenario.remove,
                scenario.name
            )
        }
    }

    // MARK: - Plist parsing

    func testParseReadsFirstProgramArgument() throws {
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist([
            "ProgramArguments": ["/Applications/OpenUsage.app/Contents/MacOS/openusage"]
        ]))
        XCTAssertEqual(agent.programPath, "/Applications/OpenUsage.app/Contents/MacOS/openusage")
    }

    func testParsePrefersProgramKeyOverProgramArguments() throws {
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist([
            "Program": "/Applications/OpenUsage.app/Contents/MacOS/OpenUsage",
            "ProgramArguments": ["/somewhere/else"]
        ]))
        XCTAssertEqual(agent.programPath, "/Applications/OpenUsage.app/Contents/MacOS/OpenUsage")
    }

    func testParseWithoutProgramKeysYieldsNil() throws {
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist(["Label": "OpenUsage"]))
        XCTAssertNil(agent.programPath)
    }

    func testParseRejectsNonPlistData() {
        XCTAssertThrowsError(try LegacyLaunchAgentCleanup.parse(plistData: Data("not a plist".utf8)))
    }

    // MARK: - End to end (temp filesystem)

    func testLeftoverTauriAgentFileIsDeleted() throws {
        let agentURL = try writeAgent([
            "ProgramArguments": ["/Applications/OpenUsage.app/Contents/MacOS/openusage"]
        ])
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/OpenUsage.app"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testForeignAgentFileIsKept() throws {
        let agentURL = try writeAgent([
            "ProgramArguments": ["/usr/local/bin/something-else"]
        ])
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/OpenUsage.app"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testUnreadableAgentFileIsKept() throws {
        let agentURL = try writeRaw(Data("not a plist".utf8))
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/OpenUsage.app"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testMissingAgentFileIsANoOp() {
        let agentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-agent-\(UUID().uuidString)")
            .appendingPathComponent("OpenUsage.plist")

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/OpenUsage.app"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    // MARK: - Helpers

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func writeAgent(_ dict: [String: Any]) throws -> URL {
        try writeRaw(plist(dict))
    }

    private func writeRaw(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("OpenUsage.plist")
        try data.write(to: url)
        return url
    }
}

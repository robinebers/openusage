import XCTest
@testable import OpenUsage

final class LegacyLaunchAgentCleanupTests: XCTestCase {
    // MARK: - Removal decision (pure)

    /// The real-world case from #874: the Tauri-era agent points at the lowercase binary name, which
    /// case-insensitive APFS resolves into this edition's bundle.
    func testTauriLowercaseProgramInsideBundleIsRemoved() {
        XCTAssertTrue(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/OpenUsage.app/Contents/MacOS/openusage",
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    func testExactCaseProgramInsideBundleIsRemoved() {
        XCTAssertTrue(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/OpenUsage.app/Contents/MacOS/OpenUsage",
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    /// A hand-rolled agent pointing anywhere else must be left alone.
    func testProgramOutsideBundleIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/usr/local/bin/openusage",
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    func testMissingProgramIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: nil,
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    /// Unbundled runs (`swift run`) report a build directory as the bundle path; that must never
    /// match, so a dev run can't delete a user's real agent by accident.
    func testNonAppBundlePathNeverMatches() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Users/dev/openusage/.build/debug/OpenUsage",
            bundlePath: "/Users/dev/openusage/.build/debug"
        ))
    }

    /// Prefix matching must be component-wise: a sibling like `OpenUsage.app2` shares the string
    /// prefix but is a different bundle.
    func testSiblingDirectorySharingPrefixIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/OpenUsage.app2/Contents/MacOS/openusage",
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    /// The bundle path itself (no inner component) is not a program inside the bundle.
    func testProgramEqualToBundlePathIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/OpenUsage.app",
            bundlePath: "/Applications/OpenUsage.app"
        ))
    }

    // MARK: - Plist parsing

    func testParseReadsFirstProgramArgument() throws {
        // Shape-faithful to what tauri-plugin-autostart wrote (see #874).
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist([
            "Label": "OpenUsage",
            "ProgramArguments": ["/Applications/OpenUsage.app/Contents/MacOS/openusage"],
            "RunAtLoad": true
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
            "Label": "OpenUsage",
            "ProgramArguments": ["/Applications/OpenUsage.app/Contents/MacOS/openusage"],
            "RunAtLoad": true
        ])
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/OpenUsage.app"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testForeignAgentFileIsKept() throws {
        let agentURL = try writeAgent([
            "Label": "OpenUsage",
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

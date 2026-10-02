import XCTest
@testable import OpenUsage

final class ZcodePathsTests: XCTestCase {
    private struct Environment: EnvironmentReading {
        let override: String?
        func value(for key: String) -> String? { key == "ZCODE_HOME" ? override : nil }
    }

    func testHomeOverrideAndDefault() {
        let home = URL(fileURLWithPath: "/example/home")
        XCTAssertEqual(ZcodePaths.homeDirectory(environment: Environment(override: nil), homeDirectory: home),
                       "/example/home/.zcode")
        XCTAssertEqual(ZcodePaths.homeDirectory(environment: Environment(override: "  /custom/zcode/  "),
                                                homeDirectory: home), "/custom/zcode")
        XCTAssertEqual(ZcodePaths.homeDirectory(environment: Environment(override: "  "), homeDirectory: home),
                       "/example/home/.zcode")
    }

    func testDiscoverySortsDatabasesAndExcludesSidecars() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = home.appendingPathComponent("cli/db")
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["shard.sqlite", "db.sqlite", "db.sqlite-wal", "db.sqlite-shm"] {
            try Data().write(to: db.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: db.appendingPathComponent("folder.sqlite"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(try ZcodePaths.databaseFiles(in: home.path),
                       [db.appendingPathComponent("db.sqlite").path, db.appendingPathComponent("shard.sqlite").path])
    }

    func testMissingDirectoryIsNotInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try ZcodePaths.databaseFiles(in: home.path), [])
    }
}

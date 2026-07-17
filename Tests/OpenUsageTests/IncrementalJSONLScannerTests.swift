import Foundation
import XCTest
@testable import OpenUsage

final class IncrementalJSONLScannerTests: XCTestCase {
    func testPersistedCacheSurvivesFreshScannerInstanceAndIsScopedByIdentity() async throws {
        let base = try makeDirectory("Persistence")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )

        let firstCounter = ParseCounter()
        let first = IncrementalJSONLScanner<Int>(persistence: persistence)
        let firstItems = await first.items(
            from: [file], since: .distantPast, cacheIdentity: "home-a", parse: firstCounter.parse
        )
        XCTAssertEqual(firstItems, [7])
        XCTAssertEqual(firstCounter.count, 1)
        await first.waitForPendingWritesForTesting()

        let relaunchedCounter = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let relaunchedItems = await relaunched.items(
            from: [file], since: .distantPast, cacheIdentity: "home-a", parse: relaunchedCounter.parse
        )
        XCTAssertEqual(relaunchedItems, [7])
        XCTAssertEqual(relaunchedCounter.count, 0, "an unchanged file should decode from the persisted cache")

        let otherHomeCounter = ParseCounter()
        let otherHome = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await otherHome.items(
            from: [file], since: .distantPast, cacheIdentity: "home-b", parse: otherHomeCounter.parse
        )
        XCTAssertEqual(otherHomeCounter.count, 1, "a different home identity must not inherit another home's cache")
        await otherHome.waitForPendingWritesForTesting()
    }

    func testPersistedCacheInvalidatesWhenSizeOrMtimeChanges() async throws {
        let base = try makeDirectory("StatInvalidation")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )

        let seed = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await seed.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await seed.waitForPendingWritesForTesting()

        let firstURL = URL(fileURLWithPath: firstFile.path)
        try Data("11".utf8).write(to: firstURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: firstFile.path)
        let resizedMtime = try XCTUnwrap(
            firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let resized = JSONLScanning.DiscoveredFile(path: firstFile.path, size: 2, mtime: resizedMtime)
        let sizeCounter = ParseCounter()
        let afterSizeChange = IncrementalJSONLScanner<Int>(persistence: persistence)
        let resizedItems = await afterSizeChange.items(
            from: [resized, secondFile], since: .distantPast, cacheIdentity: "home", parse: sizeCounter.parse
        )
        XCTAssertEqual(resizedItems, [11, 2])
        XCTAssertEqual(sizeCounter.count, 1)
        await afterSizeChange.waitForPendingWritesForTesting()

        let secondURL = URL(fileURLWithPath: secondFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: secondFile.path
        )
        let touchedMtime = try XCTUnwrap(
            secondURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let touched = JSONLScanning.DiscoveredFile(
            path: secondFile.path, size: secondFile.size, mtime: touchedMtime
        )
        let mtimeCounter = ParseCounter()
        let afterMtimeChange = IncrementalJSONLScanner<Int>(persistence: persistence)
        let touchedItems = await afterMtimeChange.items(
            from: [resized, touched], since: .distantPast, cacheIdentity: "home", parse: mtimeCounter.parse
        )
        XCTAssertEqual(touchedItems, [11, 2])
        XCTAssertEqual(mtimeCounter.count, 1)
        await afterMtimeChange.waitForPendingWritesForTesting()
    }

    func testPersistedCacheInvalidatesOnSchemaVersionChange() async throws {
        let base = try makeDirectory("SchemaInvalidation")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let cacheDirectory = base.appendingPathComponent("cache")
        let versionOne = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1, directory: cacheDirectory, writeDebounce: .milliseconds(1)
        )
        let seed = IncrementalJSONLScanner<Int>(persistence: versionOne)
        _ = await seed.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse)
        await seed.waitForPendingWritesForTesting()

        let versionTwo = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 2, directory: cacheDirectory, writeDebounce: .milliseconds(1)
        )
        let counter = ParseCounter()
        let rebuilt = IncrementalJSONLScanner<Int>(persistence: versionTwo)
        let rebuiltItems = await rebuilt.items(
            from: [file], since: .distantPast, cacheIdentity: "home", parse: counter.parse
        )
        XCTAssertEqual(rebuiltItems, [7])
        XCTAssertEqual(counter.count, 1)
        await rebuilt.waitForPendingWritesForTesting()
    }

    func testDebouncedPersistenceWritesLatestPrunedSnapshot() async throws {
        let base = try makeDirectory("Pruning")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(
            named: "a.jsonl", contents: "1", in: base, mtime: now.addingTimeInterval(-10)
        )
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let parser = ParseCounter()

        _ = await scanner.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        _ = await scanner.items(
            from: [secondFile], since: now.addingTimeInterval(-1), cacheIdentity: "home", parse: parser.parse
        )
        await scanner.waitForPendingWritesForTesting()

        let relaunchedParser = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let relaunchedItems = await relaunched.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: relaunchedParser.parse
        )
        XCTAssertEqual(relaunchedItems, [1, 2])
        XCTAssertEqual(relaunchedParser.count, 1, "the pruned file should reparse while the retained file stays cached")
        await relaunched.waitForPendingWritesForTesting()
    }

    func testChangingOneFileRewritesOnlyItsPersistedRecord() async throws {
        let base = try makeDirectory("IncrementalWrites")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        let firstRecordValue = await scanner.cacheRecordURLForTesting(identity: "home", filePath: firstFile.path)
        let secondRecordValue = await scanner.cacheRecordURLForTesting(identity: "home", filePath: secondFile.path)
        let firstRecord = try XCTUnwrap(firstRecordValue)
        let secondRecord = try XCTUnwrap(secondRecordValue)
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: firstRecord.path)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: secondRecord.path)

        let changedURL = URL(fileURLWithPath: firstFile.path)
        try Data("11".utf8).write(to: changedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: firstFile.path
        )
        let changedMtime = try XCTUnwrap(
            changedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let changed = JSONLScanning.DiscoveredFile(
            path: firstFile.path, size: 2, mtime: changedMtime
        )
        _ = await scanner.items(
            from: [changed, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        let firstMtime = try modificationDate(of: firstRecord)
        let secondMtime = try modificationDate(of: secondRecord)
        XCTAssertGreaterThan(firstMtime, sentinel)
        XCTAssertEqual(secondMtime, sentinel, "an unchanged source record must not be rewritten")
    }

    func testDisjointScansSharingIdentityKeepEachOthersParsedFiles() async throws {
        let base = try makeDirectory("SharedSubsets")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let parser = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)

        let firstItems = await scanner.items(
            from: [firstFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        let secondItems = await scanner.items(
            from: [secondFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        let firstItemsAgain = await scanner.items(
            from: [firstFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        XCTAssertEqual(firstItems, [1])
        XCTAssertEqual(secondItems, [2])
        XCTAssertEqual(firstItemsAgain, [1])
        XCTAssertEqual(parser.count, 2)
        await scanner.waitForPendingWritesForTesting()

        let relaunchedParser = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let allItems = await relaunched.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: relaunchedParser.parse
        )
        XCTAssertEqual(allItems, [1, 2])
        XCTAssertEqual(relaunchedParser.count, 0)
    }

    func testStaleIdentityDirectoryIsPruned() async throws {
        let base = try makeDirectory("IdentityPruning")
        defer { try? FileManager.default.removeItem(at: base) }
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1,
            directory: base.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(from: [file], since: .distantPast, cacheIdentity: "old-home", parse: ParseCounter().parse)
        await scanner.waitForPendingWritesForTesting()

        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: "old-home"
        )
        let old = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: identityDirectory.path)
        await JSONLScanCacheWriter.shared.pruneStaleIdentities(
            persistence: persistence,
            before: Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: identityDirectory.path))
    }

    func testConcurrentScansOfSameIdentityParseEachFileOnce() async throws {
        let base = try makeDirectory("SharedScanner")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let parser = ParseCounter(delay: 0.03)
        let scanner = IncrementalJSONLScanner<Int>()

        async let first = scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: parser.parse
        )
        async let second = scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: parser.parse
        )

        let results = await [first, second]
        XCTAssertEqual(results, [[7], [7]])
        XCTAssertEqual(parser.count, 1)
    }

    func testLimitsConcurrentParsesAndKeepsFileOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let files = try (0..<20).map { index in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            let data = Data("\(index)".utf8)
            try data.write(to: url)
            return JSONLScanning.DiscoveredFile(path: url.path, size: data.count, mtime: now)
        }
        let probe = ConcurrencyProbe()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 3)

        let items = await scanner.items(from: files, since: now.addingTimeInterval(-1)) { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        XCTAssertEqual(items, Array(0..<20))
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
    }

    func testUnreadableFileWarnsOnceUntilItRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerWarnings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("unreadable.jsonl")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = JSONLScanning.DiscoveredFile(path: path.path, size: 0, mtime: Date())
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let parse: @Sendable (Data) -> [Int]? = { data in
            String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        _ = await scanner.items(from: [file], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [file], since: .distantPast, parse: parse)
        XCTAssertEqual(warnings.counts, [1])

        try FileManager.default.removeItem(at: path)
        try Data("7".utf8).write(to: path)
        let recoveredFile = JSONLScanning.DiscoveredFile(
            path: path.path,
            size: 1,
            mtime: file.mtime.addingTimeInterval(1)
        )
        let recovered = await scanner.items(from: [recoveredFile], since: .distantPast, parse: parse)
        XCTAssertEqual(recovered, [7])

        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let failedAgainFile = JSONLScanning.DiscoveredFile(
            path: path.path,
            size: 0,
            mtime: file.mtime.addingTimeInterval(2)
        )
        _ = await scanner.items(from: [failedAgainFile], since: .distantPast, parse: parse)
        XCTAssertEqual(warnings.counts, [1, 1])
    }

    func testScanningAnotherBatchDoesNotForgetAnUnreadableFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerWarningBatches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unreadableURL = directory.appendingPathComponent("a.jsonl")
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: true)
        let readableURL = directory.appendingPathComponent("b.jsonl")
        try Data("7".utf8).write(to: readableURL)

        let now = Date()
        let unreadable = JSONLScanning.DiscoveredFile(path: unreadableURL.path, size: 0, mtime: now)
        let readable = JSONLScanning.DiscoveredFile(path: readableURL.path, size: 1, mtime: now)
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let parse: @Sendable (Data) -> [Int]? = { data in
            String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        _ = await scanner.items(from: [unreadable], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [readable], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [unreadable], since: .distantPast, parse: parse)

        XCTAssertEqual(warnings.counts, [1])
    }

    func testJsonlFilesFollowsSymlinkedRoot() throws {
        // Users symlink log dirs into synced folders (`~/.claude/projects -> ~/Dropbox/...`);
        // `FileManager.enumerator` yields nothing for a symlinked root, so discovery must resolve it.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerSymlink-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("{}".utf8).write(to: real.appendingPathComponent("a.jsonl"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let files = JSONLScanning.jsonlFiles(under: link)

        XCTAssertEqual(files.map { ($0.path as NSString).lastPathComponent }, ["a.jsonl"])
    }

    func testMissingFileDoesNotWarn() async {
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let file = JSONLScanning.DiscoveredFile(
            path: "/tmp/openusage-missing-\(UUID().uuidString).jsonl",
            size: 0,
            mtime: Date()
        )

        _ = await scanner.items(from: [file], since: .distantPast) { _ in [] }

        XCTAssertEqual(warnings.counts, [])
    }

    private func makeDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScanner\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(named name: String, contents: String, in directory: URL, mtime: Date) throws
        -> JSONLScanning.DiscoveredFile
    {
        let url = directory.appendingPathComponent(name)
        let data = Data(contents.utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }
}

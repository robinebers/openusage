import Foundation
import XCTest
@testable import OpenUsage

final class JSONLScanCacheStoreTests: XCTestCase {
    func testWriterMergesDisjointPathUpdatesFromSeparateSnapshots() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache")
        )
        let identity = "home"
        let first = try writeSource(
            "first",
            to: base.appendingPathComponent("first.jsonl"),
            mtime: Date(timeIntervalSince1970: 2_000)
        )
        let second = try writeSource(
            "second",
            to: base.appendingPathComponent("second.jsonl"),
            mtime: Date(timeIntervalSince1970: 3_000)
        )
        let firstBatch = makeBatch(
            persistence: persistence,
            identity: identity,
            file: first,
            recordData: Data("first-record".utf8)
        )
        let secondBatch = makeBatch(
            persistence: persistence,
            identity: identity,
            file: second,
            recordData: Data("second-record".utf8)
        )
        let firstWriter = JSONLScanCacheWriter()
        let secondWriter = JSONLScanCacheWriter()

        async let firstCommit = firstWriter.commit(firstBatch)
        async let secondCommit = secondWriter.commit(secondBatch)
        _ = try await (firstCommit, secondCommit)
        let loaded = try firstWriter.load(
            persistence: persistence,
            identity: identity,
            itemType: Int.self
        )
        let snapshot = try XCTUnwrap(loaded)

        XCTAssertEqual(Set(snapshot.manifest.files.keys), Set([first.path, second.path]))
        let firstRecordURL = JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: JSONLScanCachePaths.recordFileName(path: first.path)
        )
        let secondRecordURL = JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: JSONLScanCachePaths.recordFileName(path: second.path)
        )
        XCTAssertEqual(try Data(contentsOf: firstRecordURL), Data("first-record".utf8))
        XCTAssertEqual(try Data(contentsOf: secondRecordURL), Data("second-record".utf8))
    }

    func testWriterRejectsAStaleUpsertAfterTheSourceChanges() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheStaleSourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache")
        )
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let stale = try writeSource("old", to: sourceURL, mtime: Date(timeIntervalSince1970: 2_000))
        let staleBatch = makeBatch(
            persistence: persistence,
            identity: "home",
            file: stale,
            recordData: Data("stale-record".utf8)
        )
        _ = try writeSource("newer", to: sourceURL, mtime: Date(timeIntervalSince1970: 3_000))

        let result = try await JSONLScanCacheWriter().commit(staleBatch)

        XCTAssertTrue(result.manifest.files.isEmpty)
        XCTAssertTrue(result.acceptedUpsertPaths.isEmpty)
    }

    func testStaleRemovalDoesNotDeleteANewerPathUpdate() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheRemovalMergeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache")
        )
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let oldFile = try writeSource("old", to: sourceURL, mtime: Date(timeIntervalSince1970: 2_000))
        let oldBatch = makeBatch(
            persistence: persistence,
            identity: "home",
            file: oldFile,
            recordData: Data("old-record".utf8)
        )
        let writer = JSONLScanCacheWriter()
        let oldResult = try await writer.commit(oldBatch)
        let oldMetadata = try XCTUnwrap(oldResult.manifest.files[oldFile.path])

        let newFile = try writeSource("newer", to: sourceURL, mtime: Date(timeIntervalSince1970: 3_000))
        let newResult = try await writer.commit(makeBatch(
            persistence: persistence,
            identity: "home",
            file: newFile,
            recordData: Data("new-record".utf8)
        ))
        let newMetadata = try XCTUnwrap(newResult.manifest.files[newFile.path])
        let staleRemoval = JSONLScanCacheWriteBatch(
            persistence: persistence,
            identity: "home",
            upserts: [:],
            removals: [oldFile.path: oldMetadata]
        )

        let result = try await writer.commit(staleRemoval)

        XCTAssertEqual(result.manifest.files[newFile.path], newMetadata)
        let recordURL = JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: "home",
            fileName: newMetadata.recordFileName
        )
        XCTAssertEqual(try Data(contentsOf: recordURL), Data("new-record".utf8))
    }

    func testLoadingAnOldIdentityTouchesItBeforeStalePruning() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheLoadTouchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache")
        )
        let file = try writeSource(
            "value",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let writer = JSONLScanCacheWriter()
        _ = try await writer.commit(makeBatch(
            persistence: persistence,
            identity: "home",
            file: file,
            recordData: Data("record".utf8)
        ))
        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: "home"
        )
        let old = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: identityDirectory.path)

        _ = try writer.load(
            persistence: persistence,
            identity: "home",
            itemType: Int.self
        )
        await writer.pruneStaleIdentities(
            persistence: persistence,
            before: Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: identityDirectory.path))
    }

    func testFreshScannerCanPersistAfterAnotherScannerHasWrittenRepeatedly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheGenerationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let firstScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let baseDate = Date(timeIntervalSince1970: 10_000)

        for (index, contents) in ["1", "22", "333"].enumerated() {
            let file = try writeSource(
                contents,
                to: sourceURL,
                mtime: baseDate.addingTimeInterval(Double(index))
            )
            let scanned = await firstScanner.items(
                from: [file],
                since: .distantPast,
                cacheIdentity: "home",
                parse: ParseCounter().parse
            )
            XCTAssertEqual(scanned, [try XCTUnwrap(Int(contents))])
            await firstScanner.waitForPendingWritesForTesting()
        }

        let finalFile = try writeSource(
            "4444",
            to: sourceURL,
            mtime: baseDate.addingTimeInterval(3)
        )
        let freshScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let finalItems = await freshScanner.items(
            from: [finalFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )
        XCTAssertEqual(finalItems, [4444])
        await freshScanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [finalFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [4444])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testFlushPendingWritesBypassesTheDebounceForOneShotProcesses() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheFlushTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = try writeSource(
            "7",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache"),
            writeDebounce: .seconds(60)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )

        await scanner.flushPendingWrites()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [7])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testFlushRetriesDirtyWriteAfterDebouncedFailure() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheFlushRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = try writeSource(
            "7",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let cacheDirectory = base.appendingPathComponent("cache")
        try Data("blocks-directory-creation".utf8).write(to: cacheDirectory)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: cacheDirectory,
            writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        // The failed debounce has no live task handle now, but its dirty source must still be drained.
        try FileManager.default.removeItem(at: cacheDirectory)
        await scanner.flushPendingWrites()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [7])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testParseLimitIsSharedAcrossDifferentIdentities() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCachePermitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Date()
        let firstFiles = try makeIntegerFiles(range: 0..<8, prefix: "a", in: base, mtime: now)
        let secondFiles = try makeIntegerFiles(range: 8..<16, prefix: "b", in: base, mtime: now)
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 3)
        let probe = ConcurrencyProbe()
        let parse: @Sendable (Data) -> [Int]? = { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        async let first = scanner.items(
            from: firstFiles,
            since: .distantPast,
            cacheIdentity: "home-a",
            parse: parse
        )
        async let second = scanner.items(
            from: secondFiles,
            since: .distantPast,
            cacheIdentity: "home-b",
            parse: parse
        )
        let results = await (first, second)

        XCTAssertEqual(results.0, Array(0..<8))
        XCTAssertEqual(results.1, Array(8..<16))
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
    }

    func testStaleLocalEvictionCannotRemoveANewerExternalRecord() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheExternalUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let identity = "home"
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let primaryURL = base.appendingPathComponent("primary.jsonl")
        let originalPrimary = try writeSource("1", to: primaryURL, mtime: baseDate)
        let firstScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await firstScanner.items(
            from: [originalPrimary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()

        let updatedPrimary = try writeSource(
            "2",
            to: primaryURL,
            mtime: baseDate.addingTimeInterval(10)
        )
        let externalScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await externalScanner.items(
            from: [updatedPrimary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await externalScanner.waitForPendingWritesForTesting()

        let secondary = try writeSource(
            "20",
            to: base.appendingPathComponent("secondary.jsonl"),
            mtime: baseDate.addingTimeInterval(20)
        )
        _ = await firstScanner.items(
            from: [secondary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()
        _ = await firstScanner.items(
            from: [secondary],
            since: baseDate.addingTimeInterval(5),
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [updatedPrimary, secondary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [2, 20])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    private func makeBatch(
        persistence: JSONLScanCachePersistence,
        identity: String,
        file: JSONLScanning.DiscoveredFile,
        recordData: Data
    ) -> JSONLScanCacheWriteBatch {
        let metadata = JSONLScanCacheFileMetadata(
            size: file.size,
            mtime: file.mtime,
            recordFileName: JSONLScanCachePaths.recordFileName(path: file.path)
        )
        return JSONLScanCacheWriteBatch(
            persistence: persistence,
            identity: identity,
            upserts: [file.path: JSONLScanCacheUpsert(metadata: metadata, recordData: recordData)],
            removals: [:]
        )
    }

    private func writeSource(
        _ contents: String,
        to url: URL,
        mtime: Date
    ) throws -> JSONLScanning.DiscoveredFile {
        let data = Data(contents.utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(attributes[.size] as? NSNumber).intValue,
            mtime: try XCTUnwrap(attributes[.modificationDate] as? Date)
        )
    }

    private func makeIntegerFiles(
        range: Range<Int>,
        prefix: String,
        in directory: URL,
        mtime: Date
    ) throws -> [JSONLScanning.DiscoveredFile] {
        try range.map { value in
            try writeSource(
                String(value),
                to: directory.appendingPathComponent("\(prefix)-\(value).jsonl"),
                mtime: mtime
            )
        }
    }
}

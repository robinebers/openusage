import Foundation
import XCTest
@testable import OpenUsage

final class IncrementalJSONLScannerTests: XCTestCase {
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
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int {
        lock.withLock { maximum }
    }

    func begin() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func end() {
        lock.withLock {
            active -= 1
        }
    }
}

private final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] {
        lock.withLock { recordedCounts }
    }

    func record(_ count: Int) {
        lock.withLock {
            recordedCounts.append(count)
        }
    }
}

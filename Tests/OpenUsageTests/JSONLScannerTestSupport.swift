import Foundation

final class ConcurrencyProbe: @unchecked Sendable {
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

final class WarningRecorder: @unchecked Sendable {
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

final class ParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var recordedCount = 0

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var count: Int {
        lock.withLock { recordedCount }
    }

    func parse(_ data: Data) -> [Int]? {
        lock.withLock { recordedCount += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
    }
}

/// Blocks its first parse until `unblock()`, then delegates to `finish`. Generic over the scanner's
/// item type so the integer fixtures and the Claude-entry cancellation test share one blocker.
final class BlockingParser<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)
    private let finish: @Sendable (Data) -> [Item]?

    init(finish: @escaping @Sendable (Data) -> [Item]?) {
        self.finish = finish
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func parse(_ data: Data) -> [Item]? {
        lock.withLock { started = true }
        release.wait()
        return finish(data)
    }

    func unblock() {
        release.signal()
    }
}

extension BlockingParser where Item == Int {
    /// The one-integer-per-file shape the scanner fixtures write.
    convenience init() {
        self.init { String(data: $0, encoding: .utf8).flatMap(Int.init).map { [$0] } }
    }
}

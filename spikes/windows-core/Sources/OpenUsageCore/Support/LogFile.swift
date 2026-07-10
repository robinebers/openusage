import Foundation

/// Minimal file log sink for the Windows core spike (replaces macOS `~/Library/Logs/OpenUsage/` appender).
struct LogFile: Sendable {
    static let shared = LogFile()

    static var url: URL {
        WellKnownPaths.localAppData
            .appendingPathComponent("OpenUsage/logs", isDirectory: true)
            .appendingPathComponent("OpenUsage.log")
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var isOpen = false

    mutating func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else { return }
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.url.path) {
            FileManager.default.createFile(atPath: Self.url.path, contents: nil)
        }
        isOpen = true
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: Self.url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        if let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

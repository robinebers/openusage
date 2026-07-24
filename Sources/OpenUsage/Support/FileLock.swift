import Darwin
import Foundation

/// `flock`-based advisory locking around a critical section, for the places where OpenUsage shares a
/// file with another writer that locks the same path: the JSONL scan-cache manifest (app vs. CLI) and
/// the Kimi CLI's OAuth credentials rotation.
///
/// The lock is always taken on a dedicated lock file, never on the file being protected — the credential
/// and manifest writes replace their target via `rename(2)`, which swaps the inode and would strand a
/// lock held on the old one.
enum FileLock {
    /// - Parameters:
    ///   - directoryMode: POSIX permissions to assert on the lock file's parent directory. Pass `nil`
    ///     (the default) for a directory another tool owns — OpenUsage has no business re-permissioning
    ///     it — and a mode only for directories OpenUsage itself creates.
    static func withExclusive<Result>(
        at url: URL,
        nonblocking: Bool = false,
        directoryMode: NSNumber? = nil,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(
            at: url,
            operation: LOCK_EX | (nonblocking ? LOCK_NB : 0),
            directoryMode: directoryMode,
            body
        )
    }

    static func withShared<Result>(
        at url: URL,
        directoryMode: NSNumber? = nil,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(at: url, operation: LOCK_SH, directoryMode: directoryMode, body)
    }

    private static func withLock<Result>(
        at url: URL,
        operation: Int32,
        directoryMode: NSNumber?,
        _ body: () throws -> Result
    ) throws -> Result {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let directoryMode {
            try FileManager.default.setAttributes(
                [.posixPermissions: directoryMode],
                ofItemAtPath: directory.path
            )
        }
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, operation) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return try body()
    }
}

/// An exclusive lock held around a credential read-modify-write, injected into the auth stores that need
/// one so tests can exercise the locked code path without creating real lock files on disk.
protocol FileLocking: Sendable {
    func withExclusiveLock(at path: String, _ body: () throws -> Void) throws
}

struct LocalFileLock: FileLocking {
    func withExclusiveLock(at path: String, _ body: () throws -> Void) throws {
        try FileLock.withExclusive(at: URL(fileURLWithPath: expandHome(path)), body)
    }
}

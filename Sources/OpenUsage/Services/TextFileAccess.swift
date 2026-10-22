import Darwin
import Foundation

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// Read a UTF-8 file when it exists. `nil` means the path is absent; permission, encoding, and
    /// other failures still throw so credential callers do not confuse broken storage with logout.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// `writeText` without creating the parent directory: for a credential rotated in place, whose
    /// home must stay gone when the user removed it between the read and this write.
    func replaceText(_ path: String, _ text: String) throws
    /// Runs `body` while holding an exclusive lock on the directory that contains `path`, against
    /// every other holder in this process and in any other OpenUsage process (the `openusage` CLI
    /// rotates the same credentials). A check-then-write on a credential file goes inside it. On a
    /// volume that cannot lock a directory (network shares) the body still runs, unlocked.
    func withExclusiveAccess<T>(toDirectoryOf path: String, _ body: () throws -> T) throws -> T
    /// Remove the file at `path`. A missing file is not an error — the caller wants the key gone, and
    /// it already is. Used by the in-app API-key editor's Remove / Clear-override actions.
    func remove(_ path: String) throws
}

extension TextFileAccessing {
    /// In-memory doubles have no directories to bring back; only the disk accessor tells the two apart.
    func replaceText(_ path: String, _ text: String) throws {
        try writeText(path, text)
    }

    /// In-memory doubles are never shared with another process; only the disk accessor locks.
    func withExclusiveAccess<T>(toDirectoryOf path: String, _ body: () throws -> T) throws -> T {
        try body()
    }

    /// Compatibility path for test doubles. The production accessor classifies the read error directly
    /// so it does not have an exists-then-read race.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// Credential and token files must never be readable by another local account. Write through a
    /// private temporary file in the destination directory, flush it, then rename it over the target:
    /// the final replacement is atomic and has mode 0600 from the moment it becomes addressable.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)
    /// `flock` outside tests; a test stands in a volume that refuses directory locks.
    var lock: @Sendable (_ descriptor: Int32, _ operation: Int32) -> Int32 = { flock($0, $1) }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expanded).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try replacePrivately(at: expanded, with: text)
    }

    /// The parent must already exist: the temporary file is created inside it, so a directory that
    /// disappeared fails here (`ENOENT`) instead of coming back with default permissions.
    func replaceText(_ path: String, _ text: String) throws {
        try replacePrivately(at: expandHome(path), with: text)
    }

    /// An advisory `flock` on the directory itself. The directory's inode outlives every atomic
    /// rename inside it, which a lock on the file would not: a writer that locked the old inode
    /// would keep "holding" a file that was just replaced. No lock file is left in the user's home.
    /// A volume that cannot lock a directory (smbfs answers `EISDIR`, an NFS mount without locking
    /// `ENOTSUP`) gets the write anyway, as every write did before this lock existed — losing a
    /// rotated token there would cost the login — with a warning in the log.
    func withExclusiveAccess<T>(toDirectoryOf path: String, _ body: () throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: expandHome(path)).deletingLastPathComponent().path
        let descriptor = directory.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        while lock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EISDIR || code == ENOTSUP || code == EOPNOTSUPP else { throw Self.currentPOSIXError() }
            AppLog.warn(.auth, "this volume cannot lock a credential folder (\(String(cString: strerror(code)))); writing without the cross-process lock")
            return try body()
        }
        defer { _ = lock(descriptor, LOCK_UN) }
        return try body()
    }

    private func replacePrivately(at expanded: String, with text: String) throws {
        let destination = URL(fileURLWithPath: expanded)
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // A process umask may only remove permissions at creation. Reassert the exact private mode on
        // the still-unpublished inode before writing or renaming it into place.
        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

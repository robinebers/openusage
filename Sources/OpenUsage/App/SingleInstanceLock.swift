import Darwin
import Foundation

/// Kernel-backed single-instance lock. macOS can fire two independent launch triggers on reboot
/// (session restoration and the login item), and an `NSRunningApplication` snapshot can't close that
/// race: when two copies launch near-simultaneously LaunchServices can hand each a snapshot containing
/// only itself. An exclusive `flock` on a per-bundle file is atomic in the kernel: exactly one process
/// holds it no matter how the launches interleave. The kernel also releases it when the holder exits
/// or crashes, so a stale lock can never block a relaunch.
enum SingleInstanceLock {
    enum Acquisition {
        case acquired(Token)
        case alreadyRunning
        case failed(String)
    }

    final class Token {
        private let fd: CInt

        fileprivate init(fd: CInt) {
            self.fd = fd
        }

        deinit {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }

    static func acquire(bundleIdentifier: String) -> Acquisition {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .failed("Application Support directory unavailable")
        }
        let lockURL = appSupport
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).lock")
        return acquire(at: lockURL)
    }

    static func acquire(at lockURL: URL) -> Acquisition {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            return .failed(String(cString: strerror(errno)))
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fd)
            return lockError == EWOULDBLOCK ? .alreadyRunning : .failed(String(cString: strerror(lockError)))
        }

        return .acquired(Token(fd: fd))
    }
}

import Darwin
import Foundation
import os

/// Runs the Codex CLI's interactive login for a managed home. Split from `ProcessRunning` because a
/// login streams instructions (the sign-in URL) while it waits on the browser, and must die when the
/// user cancels — neither fits the one-shot capture-everything runner.
protocol CodexLoginLaunching: Sendable {
    /// Returns the exit status. Each chunk of stdout/stderr reaches `onOutput` as it arrives, and
    /// every chunk has been delivered by the time this returns. Task cancellation and `timeout` both
    /// stop the child and every process in its process group, and return only once that group is
    /// empty, so a caller can clean its home up without racing a straggler. (A process that left
    /// the group, e.g. through `setsid`, is outside this contract.)
    func runLogin(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

enum CodexLoginLaunchError: Error, LocalizedError, Equatable {
    case timedOut
    /// The pipe or `posix_spawn` failed before the CLI ran; `errno` is the system's reason (a wrapper
    /// script whose interpreter is gone reads as `ENOENT`, for instance).
    case spawnFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Sign-in timed out. Try again."
        case .spawnFailed(let code):
            return "Couldn't start Codex (\(String(cString: strerror(code)))). Check the Codex CLI installation, then try again."
        }
    }
}

/// Spawns the login in a process group of its own (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`), so
/// stopping it means signalling the whole group: a `codex` that is really a shell wrapper, and any
/// CLI it respawns after a child dies, all go together. The login counts as finished only when the
/// group is empty — a wrapper that exits early leaves nothing behind. The contract ends at the
/// group: a wrapper that detaches its CLI into a new session (`setsid`) is outside it and is not
/// supported. `Foundation.Process` offers no process group, which is why the login does not go
/// through it.
struct SystemCodexLoginLauncher: CodexLoginLaunching {
    func runLogin(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        // A cancelled sign-in must never reach the browser.
        try Task.checkCancellation()
        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")
        let child = try CodexLoginProcesses.spawnRegistered {
            try CodexLoginProcess.spawn(executable: executable, arguments: arguments, environment: environment)
        }
        let drained = child.startDraining(idleSecondsAfterGroupExit: 2, onOutput)

        let stopper = GroupStopper(pgid: child.pid)
        stopper.armDeadline(after: timeout)
        let status = await withTaskCancellationHandler {
            await child.waitForGroupExit(stopper: stopper)
        } onCancel: {
            stopper.stop(reason: .cancelled)
        }
        // The group is empty: nothing may be signalled from here on, by the stopper or by a quit.
        stopper.disarm()
        CodexLoginProcesses.unregister(child.pid)
        // The group is gone, so everything the CLI wrote — its error line included — is in the pipe
        // or already in the reader's hands. The reader alone decides when it is done: it delivers
        // what is there (a chunk parked in a slow callback too), then reports back here. It gives up
        // only on a pipe nobody writes to for the idle bound, which means a writer that escaped the
        // group (`setsid`) still holds it.
        drained.markGroupExited()
        if !(await drained.waitUntilFinished()) {
            AppLog.warn(.subprocess, "codex login output still open after exit; a detached process kept the pipe")
        }
        AppLog.debug(.subprocess, "exit \(status)")
        switch stopper.reason {
        case .timedOut: throw CodexLoginLaunchError.timedOut
        case .cancelled: throw CancellationError()
        case nil: return status
        }
    }
}

/// The login's process-group ids, so a Quit mid-sign-in can take the CLI (and its browser callback
/// server) down with the app instead of leaving an orphan that later writes a credential nobody
/// tracks. Entries live from spawn until the group is empty.
enum CodexLoginProcesses {
    private struct State {
        var groups: Set<pid_t> = []
        /// Set by `terminateAll`: from then on no login may start, or it would outlive the app.
        var shuttingDown = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `spawn` under the registry's lock and registers the result before releasing it, so a
    /// quit either comes first and refuses the spawn, or comes after and finds the group registered.
    /// A spawn that lands after the app began quitting is cancelled: its process would be left
    /// running with nobody to stop it.
    static func spawnRegistered(_ spawn: @Sendable () throws -> CodexLoginProcess) throws -> CodexLoginProcess {
        try state.withLock { state in
            guard !state.shuttingDown else { throw CancellationError() }
            let child = try spawn()
            state.groups.insert(child.pid)
            return child
        }
    }

    static func unregister(_ pgid: pid_t) { state.withLock { _ = $0.groups.remove(pgid) } }

    /// Lets logins start again after `terminateAll`, which otherwise refuses them for the rest of
    /// the process. Tests only: the app quits right after terminating.
    static func resumeAfterTerminateForTesting() { state.withLock { $0.shuttingDown = false } }

    /// How many groups a quit would still signal. Tests only.
    static var registeredGroupCountForTesting: Int { state.withLock { $0.groups.count } }

    /// Synchronous on purpose: called from `applicationWillTerminate`, after which nothing async
    /// runs — so the SIGKILL escalation the launcher would normally schedule happens inline here.
    static func terminateAll() {
        // Signals go only to groups still registered, and only under the lock `unregister` takes:
        // a login that finished on its own and let its id go is never signalled from a stale copy.
        let running = state.withLock { state in
            state.shuttingDown = true
            for pgid in state.groups { kill(-pgid, SIGTERM) }
            return state.groups
        }
        guard !running.isEmpty else { return }
        for _ in 0..<10 where state.withLock({ $0.groups }).contains(where: CodexLoginProcess.groupHasMembers) {
            usleep(50_000)
        }
        state.withLock { state in
            for pgid in state.groups where CodexLoginProcess.groupHasMembers(pgid) { kill(-pgid, SIGKILL) }
        }
        AppLog.info(.subprocess, "stopped \(running.count) Codex sign-in process group(s) on quit")
    }
}

/// One spawned login: its pid (which is also its process-group id), the read end of its merged
/// stdout/stderr pipe, and the leader's exit status once reaped. The pipe is read — and closed — by
/// the drain queue only, and the status written by exactly one `waitpid` call, which is why the
/// unchecked conformance holds.
final class CodexLoginProcess: @unchecked Sendable {
    let pid: pid_t
    private let outputDescriptor: Int32
    private let lock = NSLock()
    private var leaderStatus: Int32?
    private var leaderContinuation: CheckedContinuation<Int32, Never>?

    private init(pid: pid_t, outputDescriptor: Int32) {
        self.pid = pid
        self.outputDescriptor = outputDescriptor
        // Reaped on a dedicated thread: `waitpid` blocks, and the login can sit on the browser for
        // minutes.
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            let status = Self.exitCode(fromWaitStatus: raw)
            lock.lock()
            leaderStatus = status
            let waiting = leaderContinuation
            leaderContinuation = nil
            lock.unlock()
            waiting?.resume(returning: status)
        }
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String]) throws -> CodexLoginProcess {
        var pipeDescriptors: [Int32] = [-1, -1]
        guard pipe(&pipeDescriptors) == 0 else { throw CodexLoginLaunchError.spawnFailed(errno: errno) }
        let readEnd = pipeDescriptors[0]
        let writeEnd = pipeDescriptors[1]

        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // A login never reads stdin; an inherited terminal would let the CLI block on a prompt.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid == pid) so the whole login tree can be signalled at once; every
        // other descriptor closes on exec so the child inherits nothing but its pipe; signals start
        // unblocked and at their defaults, so the CLI can actually honor SIGTERM (a Swift worker
        // thread may carry a mask the child must not inherit).
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        ))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw CodexLoginLaunchError.spawnFailed(errno: result)
        }
        return CodexLoginProcess(pid: pid, outputDescriptor: readEnd)
    }

    /// Reads the merged pipe on its own queue, forwarding whole UTF-8 sequences, until EOF — or,
    /// once the launcher has reported the process group gone, until nothing has arrived for
    /// `idleSecondsAfterGroupExit` (a writer that escaped the group holds the pipe; its output is
    /// not waited for). The reader closes the descriptor itself: nothing else may, since a reader
    /// blocked in a slow callback would otherwise come back to a descriptor number some unrelated
    /// file now owns. The returned signal fires only after the last chunk has been delivered, so
    /// nobody infers "drained" from this thread's progress.
    func startDraining(
        idleSecondsAfterGroupExit: Double, _ onOutput: @escaping @Sendable (String) -> Void
    ) -> DrainSignal {
        let signal = DrainSignal()
        DispatchQueue(label: "com.openusage.codex-login-drain", qos: .utility).async { [outputDescriptor] in
            var pending: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var lastDataAt = Date()
            var reachedEOF = false
            while true {
                // Blocking only in `poll`, never in `read`: the idle check runs here, where "nothing
                // is ready" is a fact, not a guess about a read that may already hold bytes.
                var request = pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&request, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    if let exitedAt = signal.groupExitedAt,
                       Date().timeIntervalSince(max(exitedAt, lastDataAt)) >= idleSecondsAfterGroupExit {
                        break
                    }
                    continue
                }
                let count = read(outputDescriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    reachedEOF = count == 0
                    break
                }
                lastDataAt = Date()
                pending.append(contentsOf: chunk[0..<count])
                let complete = Self.completeUTF8PrefixLength(of: pending)
                if complete > 0 {
                    onOutput(String(decoding: pending[0..<complete], as: UTF8.self))
                    pending.removeFirst(complete)
                }
            }
            if !pending.isEmpty { onOutput(String(decoding: pending, as: UTF8.self)) }
            close(outputDescriptor)
            signal.finish(reachedEOF: reachedEOF)
        }
        return signal
    }

    /// Bytes that end on a UTF-8 sequence boundary; an incomplete trailing sequence waits for the
    /// next read instead of decoding into replacement characters.
    static func completeUTF8PrefixLength(of bytes: [UInt8]) -> Int {
        guard let lastLead = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return bytes.count }
        let lead = bytes[lastLead]
        let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - lastLead >= needed ? bytes.count : lastLead
    }

    /// Resolves once the leader is reaped AND no process of its group is left. A wrapper that exits
    /// while its CLI keeps running therefore never ends the login early; the deadline keeps running
    /// and, on timeout or cancel, the stopper kills what remains.
    func waitForGroupExit(stopper: GroupStopper) async -> Int32 {
        let status = await withCheckedContinuation { continuation in
            lock.lock()
            if let leaderStatus {
                lock.unlock()
                continuation.resume(returning: leaderStatus)
            } else {
                leaderContinuation = continuation
                lock.unlock()
            }
        }
        while Self.groupHasMembers(pid) {
            if stopper.reason != nil { stopper.escalateNow() }
            // Not `Task.sleep`: a cancelled task would skip the pause and spin until the group dies.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
            }
        }
        return status
    }

    /// Whether any process still belongs to the group. The leader itself is reaped before this is
    /// consulted, so a positive answer means descendants. `ESRCH` is the normal "nobody left".
    /// `EPERM` means a member exists that this process may not signal — impossible for the login's
    /// own same-user descendants, so it is logged and treated as nothing we could stop anyway.
    static func groupHasMembers(_ pgid: pid_t) -> Bool {
        if kill(-pgid, 0) == 0 { return true }
        if errno == EPERM {
            AppLog.warn(.subprocess, "a process in the Codex login's group cannot be signalled; leaving it")
        }
        return false
    }

    /// Shell conventions: a signal death reads as 128 + signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }
}

/// The handshake between the launcher and the drain queue: the launcher says when the process group
/// is gone, the reader says when it has delivered everything and closed the pipe. Until the group is
/// gone the reader never gives up, however long the CLI sits silent on the browser.
final class DrainSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exitedAt: Date?
    private var reachedEOF: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    /// When the launcher reported the group empty; `nil` while the login still runs.
    var groupExitedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return exitedAt
    }

    func markGroupExited() {
        lock.lock()
        if exitedAt == nil { exitedAt = Date() }
        lock.unlock()
    }

    /// Called by the reader after its last callback returned and the descriptor is closed.
    /// `reachedEOF` is false when it gave up on a pipe a detached writer still held.
    func finish(reachedEOF: Bool) {
        lock.lock()
        self.reachedEOF = reachedEOF
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: reachedEOF)
    }

    /// Resolves once the reader has finished, with whether it read the pipe to EOF.
    func waitUntilFinished() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let reachedEOF {
                lock.unlock()
                continuation.resume(returning: reachedEOF)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Stops the login's process group and remembers why, so the launcher can report the right outcome
/// once the group is gone. Cancellation arrives on the main thread from a button; signalling a
/// group is a single syscall, so it needs no hop off that thread.
final class GroupStopper: @unchecked Sendable {
    enum Reason { case timedOut, cancelled }

    private let pgid: pid_t
    private let signal: @Sendable (pid_t, Int32) -> Void
    private let lock = NSLock()
    private var stopReason: Reason?
    private var deadline: DispatchWorkItem?
    private var escalation: DispatchWorkItem?
    /// Set once the group is gone. From then on nothing may be signalled: the id can already belong
    /// to an unrelated process group.
    private var disarmed = false

    /// `signal` is `kill` outside tests.
    init(pgid: pid_t, signal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = kill($0, $1) }) {
        self.pgid = pgid
        self.signal = signal
    }

    var reason: Reason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    /// Stops the group once `timeout` passes.
    func armDeadline(after timeout: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.stop(reason: .timedOut) }
        lock.lock()
        deadline = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Called once the group is empty; nothing is left to signal, and nothing may be from now on.
    func disarm() {
        lock.lock()
        disarmed = true
        deadline?.cancel()
        deadline = nil
        escalation?.cancel()
        escalation = nil
        lock.unlock()
    }

    /// SIGTERM to the whole group now, SIGKILL to whatever is still there a second later — including
    /// a child the wrapper respawned in between, since it joins the same group. One critical
    /// section, so a stop that races `disarm` (the group died on its own just then) either runs
    /// entirely before it or signals nothing at all: `kill` does not block, and `disarm` waits on
    /// the same lock rather than slipping in between the check and the signal.
    func stop(reason: Reason) {
        lock.lock()
        defer { lock.unlock() }
        guard stopReason == nil, !disarmed else { return }
        stopReason = reason
        signal(-pgid, SIGTERM)
        let item = DispatchWorkItem { [weak self] in self?.escalateUnlessDisarmed() }
        escalation = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: item)
    }

    /// The escalation: an item already dequeued when `disarm` cancels it must still see the flag,
    /// so it checks under the lock — and `disarm` waits for an escalation that is mid-signal.
    func escalateUnlessDisarmed() {
        lock.lock()
        defer { lock.unlock() }
        guard !disarmed else { return }
        signal(-pgid, SIGKILL)
    }

    /// The leader is gone but members remain after a stop: no reason to wait out the grace period.
    func escalateNow() {
        signal(-pgid, SIGKILL)
    }
}

/// Finds the `codex` executable for a GUI launch, whose process PATH is launchd's minimal one. The
/// login-shell PATH comes first (that is where `npm -g`, Homebrew, Bun, and Volta installs live), then
/// the process PATH, then the usual install prefixes as a last resort.
enum CodexExecutableLocator {
    static let fallbackDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin",
        "~/.bun/bin", "~/.volta/bin", "~/.codex/bin",
    ]

    static func searchPath(shellPATH: String?, processPATH: String?, home: URL) -> [String] {
        var seen = Set<String>()
        let candidates = [shellPATH, processPATH].compactMap { $0 }.flatMap { $0.split(separator: ":").map(String.init) }
            + fallbackDirectories
        return candidates.compactMap { raw in
            let expanded = raw.hasPrefix("~/") ? home.path + raw.dropFirst(1) : raw
            guard !expanded.isEmpty, seen.insert(expanded).inserted else { return nil }
            return expanded
        }
    }

    static func locate(
        searchPath: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchPath.lazy.map { $0.trimmingTrailingSlashes + "/codex" }.first(where: isExecutable)
    }
}

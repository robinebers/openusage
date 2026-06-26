import Foundation
import Darwin

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Debug-only, basename + arg count only: arg *values* can carry paths/identifiers, so they
        // are never logged here.
        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes on background queues, started BEFORE the child runs. A child that writes
        // more than the OS pipe buffer (~64KB) would otherwise block on write, never exit, and trip the
        // timeout below — reading only after exit deadlocks. (`ps -ax -o command=` alone is ~240KB.)
        let output = SubprocessOutput()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained)
        drain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained)

        // One kernel-level wait instead of a 50ms poll loop: the termination handler trips the
        // group (registered before `run()` so an instantly-exiting child can't race it), and
        // `wait` blocks this thread exactly once until exit or the deadline.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateProcessTree(rootPID: process.processIdentifier)
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            drained.wait() // the killed child closed its pipes, so the drains hit EOF and finish
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        }

        process.waitUntilExit()
        drained.wait()
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.stdoutString, stderr: output.stderrString)
    }

    /// Read a pipe to EOF on a background queue, accumulating into `output`. Started before the child
    /// runs so the pipe is continuously drained and can never fill (EOF arrives when the child exits and
    /// closes its write end).
    private func drain(_ handle: FileHandle, into output: SubprocessOutput, isStdout: Bool, group: DispatchGroup) {
        let box = FileHandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = box.handle.readDataToEndOfFile()
            if isStdout { output.setStdout(data) } else { output.setStderr(data) }
            group.leave()
        }
    }

    private func terminateProcessTree(rootPID: Int32) {
        let children = childPIDs(of: rootPID)
        for child in children {
            terminateProcessTree(rootPID: child)
        }
        kill(rootPID, SIGTERM)
        for child in children {
            kill(child, SIGKILL)
        }
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return []
        }

        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout))s."
        }
    }
}

/// Passes a non-Sendable `FileHandle` into the background drain closure under Swift 6 strict
/// concurrency. The handle is read by exactly one queue, so the unchecked conformance is sound.
private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// Lock-guarded accumulator for the two concurrently-drained pipes.
private final class SubprocessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}


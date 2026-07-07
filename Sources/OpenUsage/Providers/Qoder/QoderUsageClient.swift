import Foundation
import Darwin

struct QoderStreamProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol QoderStreamProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: String,
        timeout: TimeInterval
    ) throws -> QoderStreamProcessResult
}

struct QoderUsageClient: Sendable {
    static let sdkEntrypoint = "sdk-ts"
    static let sdkVersion = "0.1.0"

    var processRunner: QoderStreamProcessRunning

    init(processRunner: QoderStreamProcessRunning = QoderCLIProcessRunner()) {
        self.processRunner = processRunner
    }

    func fetchUsage(auth: QoderAuth) throws -> QoderUsageInfo {
        let authPayload = try makeAuthPayload(auth.method)
        defer { cleanupAuthPayload(at: authPayload.directory) }

        let usageRequestID = "usage-\(UUID().uuidString)"
        let stdin = [
            controlRequest(id: "init-\(UUID().uuidString)", request: [
                "type": "initialize",
                "modelPolicyProvider": false,
                "supportsCatalogReadyInitialize": true,
                "initializeTimeoutMs": 120_000
            ]),
            controlRequest(id: usageRequestID, request: ["type": "get_usage_info"])
        ].joined(separator: "\n") + "\n"

        let result: QoderStreamProcessResult
        do {
            result = try processRunner.run(
                executable: auth.executable,
                arguments: [
                    "--print",
                    "--output-format", "stream-json",
                    "--input-format", "stream-json",
                    "--tools", ""
                ],
                environment: [
                    "QODER_AGENT_SDK_ENTRYPOINT": Self.sdkEntrypoint,
                    "QODER_AGENT_SDK_VERSION": Self.sdkVersion,
                    "QODER_SDK_AUTH_PAYLOAD_FILE": authPayload.file.path
                ],
                stdin: stdin,
                timeout: 30
            )
        } catch ProcessRunnerError.timedOut(_, _) {
            throw QoderUsageError.timedOut
        } catch {
            throw QoderUsageError.connectionFailed
        }

        guard result.succeeded else {
            AppLog.warn(LogTag.plugin("qoder"), "qodercli usage exited \(result.exitCode)")
            throw QoderUsageError.processFailed(result.exitCode)
        }

        return try parseUsage(from: result.stdout, requestID: usageRequestID, auth: auth)
    }

    private func parseUsage(from stdout: String, requestID: String, auth: QoderAuth) throws -> QoderUsageInfo {
        var sawAuthFailure = false
        var sawMalformedJSON = false

        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sawMalformedJSON = true
                continue
            }

            if let type = root["type"] as? String,
               type == "auth_status",
               root["error"] != nil {
                sawAuthFailure = true
            }

            guard let type = root["type"] as? String,
                  type == "control_response",
                  let response = root["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else {
                continue
            }

            if response["subtype"] as? String == "error" {
                if isAuthError(response) { throw QoderUsageError.invalidAuth }
                throw QoderUsageError.invalidResponse
            }

            guard let payload = response["response"] as? [String: Any] else {
                throw auth.method.isAccessToken ? QoderUsageError.invalidAuth : QoderUsageError.unsupportedCLI
            }
            guard let usage = payload["usage"], !(usage is NSNull) else {
                throw auth.method.isAccessToken ? QoderUsageError.invalidAuth : QoderUsageError.unsupportedCLI
            }
            guard JSONSerialization.isValidJSONObject(usage),
                  let usageData = try? JSONSerialization.data(withJSONObject: usage),
                  let decoded = try? JSONDecoder().decode(QoderUsageInfo.self, from: usageData) else {
                throw QoderUsageError.invalidResponse
            }
            return decoded
        }

        if sawAuthFailure { throw QoderUsageError.invalidAuth }
        if sawMalformedJSON { throw QoderUsageError.invalidResponse }
        throw QoderUsageError.unsupportedCLI
    }

    private func isAuthError(_ response: [String: Any]) -> Bool {
        let joined = [
            response["code"] as? String,
            response["error"] as? String
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        return joined.contains("auth") || joined.contains("unauthor") || joined.contains("token")
    }

    private func controlRequest(id: String, request: [String: Any]) -> String {
        let object: [String: Any] = [
            "type": "control_request",
            "request_id": id,
            "request": request
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeAuthPayload(_ method: QoderAuth.Method) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-qoder-auth-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("payload.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONSerialization.data(withJSONObject: authPayloadObject(method), options: [.sortedKeys])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return (directory, file)
        } catch {
            cleanupAuthPayload(at: directory)
            throw QoderUsageError.authPayloadFailed
        }
    }

    private func authPayloadObject(_ method: QoderAuth.Method) -> [String: Any] {
        switch method {
        case .qodercli:
            return ["type": "qodercli"]
        case .accessToken(let token):
            return ["type": "accessToken", "accessToken": token]
        }
    }

    private func cleanupAuthPayload(at directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            AppLog.warn(LogTag.plugin("qoder"), "failed to remove temporary auth payload: \(error.localizedDescription)")
        }
    }
}

private extension QoderAuth.Method {
    var isAccessToken: Bool {
        if case .accessToken = self { return true }
        return false
    }
}

enum QoderUsageError: Error, LocalizedError, Equatable {
    case authPayloadFailed
    case connectionFailed
    case timedOut
    case invalidAuth
    case invalidResponse
    case processFailed(Int32)
    case unsupportedCLI

    var errorDescription: String? {
        switch self {
        case .authPayloadFailed:
            return "Couldn't prepare Qoder authentication."
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .timedOut:
            return "Qoder CLI usage request timed out."
        case .invalidAuth:
            return "Qoder authentication failed. Run qodercli login again or update QODER_PERSONAL_ACCESS_TOKEN."
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .processFailed(let exitCode):
            return "Qoder CLI usage request failed (exit \(exitCode)). Try updating qodercli."
        case .unsupportedCLI:
            return "Qoder CLI does not support usage info. Update qodercli."
        }
    }
}

struct QoderCLIProcessRunner: QoderStreamProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: String,
        timeout: TimeInterval
    ) throws -> QoderStreamProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let output = QoderSubprocessOutput()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained)
        drain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained)

        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateProcessTree(rootPID: process.processIdentifier)
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            waitForDrains(drained, executable: executable)
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        }

        process.waitUntilExit()
        waitForDrains(drained, executable: executable)
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return QoderStreamProcessResult(
            exitCode: process.terminationStatus,
            stdout: output.stdoutString,
            stderr: output.stderrString
        )
    }

    private func drain(_ handle: FileHandle, into output: QoderSubprocessOutput, isStdout: Bool, group: DispatchGroup) {
        let box = QoderFileHandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = box.handle.readDataToEndOfFile()
            if isStdout { output.setStdout(data) } else { output.setStderr(data) }
            group.leave()
        }
    }

    private func waitForDrains(_ group: DispatchGroup, executable: String) {
        if group.wait(timeout: .now() + 1) == .timedOut {
            AppLog.warn(.subprocess, "pipe drain timed out for \((executable as NSString).lastPathComponent)")
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

private final class QoderFileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

private final class QoderSubprocessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}

import AppKit
import Foundation
import Observation

/// Installs the bundled one-shot CLI on the stock macOS PATH without copying it out of the app.
/// The symlink survives in-place Sparkle updates because its destination path stays stable.
@MainActor
@Observable
final class CommandLineToolInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        case conflict
    }

    enum Operation { case install, uninstall }
    enum OperationResult { case success, cancelled, failure(String) }

    private(set) var status: Status
    private(set) var errorMessage: String?

    let destinationPath: String
    private let sourcePath: String
    private let fileManager: FileManager
    private let performPrivileged: @MainActor (Operation, String, String) -> OperationResult

    init(
        sourcePath: String = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/openusage").path,
        destinationPath: String = "/usr/local/bin/openusage",
        fileManager: FileManager = .default,
        performPrivileged: (@MainActor (Operation, String, String) -> OperationResult)? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileManager = fileManager
        self.performPrivileged = performPrivileged ?? { operation, source, destination in
            CommandLineToolInstaller.runPrivileged(
                operation: operation,
                sourcePath: source,
                destinationPath: destination
            )
        }
        self.status = Self.currentStatus(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            fileManager: fileManager
        )
    }

    func refreshStatus() {
        status = Self.currentStatus(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            fileManager: fileManager
        )
    }

    func install() {
        refreshStatus()
        guard status != .installed else { return }
        guard status != .conflict else {
            errorMessage = "\(destinationPath) already exists and wasn't installed by OpenUsage."
            return
        }
        guard fileManager.isExecutableFile(atPath: sourcePath) else {
            errorMessage = "The bundled terminal helper couldn't be found. Reinstall OpenUsage and try again."
            return
        }
        handle(performPrivileged(.install, sourcePath, destinationPath), action: "install")
    }

    func uninstall() {
        refreshStatus()
        guard status == .installed else { return }
        handle(performPrivileged(.uninstall, sourcePath, destinationPath), action: "remove")
    }

    private func handle(_ result: OperationResult, action: String) {
        switch result {
        case .success:
            errorMessage = nil
        case .cancelled:
            break
        case .failure(let message):
            errorMessage = "Couldn't \(action) the terminal helper: \(message)"
            AppLog.error(.config, "Terminal helper \(action) failed: \(message)")
        }
        refreshStatus()
    }

    private static func currentStatus(
        sourcePath: String,
        destinationPath: String,
        fileManager: FileManager
    ) -> Status {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: destinationPath) else {
            return fileManager.fileExists(atPath: destinationPath) ? .conflict : .notInstalled
        }
        // The installer always writes this exact absolute target, and uninstall checks the same string
        // again under privilege. A manually-created relative/equivalent link is therefore foreign.
        return target == sourcePath ? .installed : .conflict
    }

    private static func runPrivileged(
        operation: Operation,
        sourcePath: String,
        destinationPath: String
    ) -> OperationResult {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let command: String
        switch operation {
        case .install:
            command = """
            if [ -e \(shellQuote(destinationPath)) ] || [ -L \(shellQuote(destinationPath)) ]; then exit 73; fi
            /bin/mkdir -p \(shellQuote(directory)) && /bin/ln -s \(shellQuote(sourcePath)) \(shellQuote(destinationPath))
            """
        case .uninstall:
            command = """
            target=$(/usr/bin/readlink \(shellQuote(destinationPath))) || exit 74
            [ "$target" = \(shellQuote(sourcePath)) ] || exit 75
            /bin/rm \(shellQuote(destinationPath))
            """
        }

        let source = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return .failure("macOS couldn't prepare the authorization request.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success }
        if let code = errorInfo[NSAppleScript.errorNumber] as? Int, code == -128 {
            return .cancelled
        }
        return .failure(
            (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "macOS rejected the authorization request."
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

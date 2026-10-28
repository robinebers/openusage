import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CommandLineToolInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// The link was written by another copy of OpenUsage (an earlier version, a build in another
        /// folder, or one that has since moved); Install points it at this app.
        case linkedToAnotherCopy(String)
        case conflict
    }

    enum Operation: Equatable {
        case install(replacing: String?)
        case uninstall
    }
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
        var replacing: String?
        if case .linkedToAnotherCopy(let target) = status { replacing = target }
        handle(performPrivileged(.install(replacing: replacing), sourcePath, destinationPath), action: "install")
    }

    func uninstall() {
        refreshStatus()
        guard status == .installed else { return }
        handle(performPrivileged(.uninstall, sourcePath, destinationPath), action: "remove")
    }

    /// Every OpenUsage installer, main's included, links the command to `<OpenUsage….app>/Contents/Helpers/openusage`.
    static func isOpenUsageHelper(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count >= 4, Array(components.suffix(3)) == ["Contents", "Helpers", "openusage"] else { return false }
        let bundle = components[components.count - 4]
        return bundle.hasPrefix("OpenUsage") && bundle.hasSuffix(".app")
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
        if target == sourcePath { return .installed }
        return isOpenUsageHelper(target) ? .linkedToAnotherCopy(target) : .conflict
    }

    private static func runPrivileged(
        operation: Operation,
        sourcePath: String,
        destinationPath: String
    ) -> OperationResult {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let command: String
        switch operation {
        case .install(replacing: nil):
            command = """
            if [ -e \(shellQuote(destinationPath)) ] || [ -L \(shellQuote(destinationPath)) ]; then exit 73; fi
            /bin/mkdir -p \(shellQuote(directory)) && /bin/ln -s \(shellQuote(sourcePath)) \(shellQuote(destinationPath))
            """
        case .install(replacing: let target?):
            command = """
            existing=$(/usr/bin/readlink \(shellQuote(destinationPath))) || exit 73
            [ "$existing" = \(shellQuote(target)) ] || exit 73
            /bin/rm \(shellQuote(destinationPath)) && /bin/ln -s \(shellQuote(sourcePath)) \(shellQuote(destinationPath))
            """
        case .uninstall:
            command = """
            existing=$(/usr/bin/readlink \(shellQuote(destinationPath))) || exit 74
            [ "$existing" = \(shellQuote(sourcePath)) ] || exit 75
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

#if OPENUSAGE_DEVELOPMENT
import AppKit
import Observation

/// The running bundle is the source of truth. Switching launches the other isolated dev app.
@MainActor
@Observable
final class DevelopmentDataMode {
    static let normalBundleID = "com.robinebers.openusage.dev"
    static let demoBundleID = "com.robinebers.openusage.dev.demo"

    let isAvailable: Bool
    let isOn: Bool
    private(set) var isSwitching = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let identifierOfBundle: @MainActor (URL) -> String?
    @ObservationIgnored private let openApplication: @MainActor (URL) async throws -> Void
    @ObservationIgnored private let terminate: @MainActor () -> Void

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        bundleURL: URL = Bundle.main.bundleURL,
        identifierOfBundle: @escaping @MainActor (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        openApplication: @escaping @MainActor (URL) async throws -> Void = DevelopmentDataMode.openApplication,
        terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        isAvailable = bundleIdentifier == Self.normalBundleID || bundleIdentifier == Self.demoBundleID
        isOn = bundleIdentifier == Self.demoBundleID
        self.bundleURL = bundleURL
        self.identifierOfBundle = identifierOfBundle
        self.openApplication = openApplication
        self.terminate = terminate
    }

    func setSampleData(_ enabled: Bool) {
        Task { await switchToSampleData(enabled) }
    }

    func switchToSampleData(_ enabled: Bool) async {
        guard isAvailable else {
            fail("Sample data is available only in the local development apps.")
            return
        }
        guard enabled != isOn, !isSwitching else { return }
        isSwitching = true
        errorMessage = nil
        defer { isSwitching = false }

        let name = enabled ? "OpenUsage Demo.app" : "OpenUsage.app"
        let destination = bundleURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        let expectedID = enabled ? Self.demoBundleID : Self.normalBundleID
        guard bundleURL.pathExtension == "app", identifierOfBundle(destination) == expectedID else {
            fail("The other development app is missing or invalid. Rebuild with script/build_and_run.sh and try again.")
            return
        }
        do {
            try await openApplication(destination)
            terminate()
        } catch {
            AppLog.error(.lifecycle, "cannot switch development data mode: \(error.localizedDescription)")
            errorMessage = "OpenUsage couldn't open the other development app. Your current app is still running. Try again."
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        AppLog.error(.lifecycle, message)
    }

    private static func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.executableNotLoadable))
                }
            }
        }
    }
}
#endif

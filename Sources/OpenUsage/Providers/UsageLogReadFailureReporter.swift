import Foundation

/// Logs only when a local usage file newly becomes unreadable. Repeated refreshes stay quiet until
/// the file recovers and fails again.
actor UsageLogReadFailureReporter {
    typealias Warning = @Sendable (Int) -> Void

    private var failingPaths: Set<String> = []
    private let warning: Warning

    init(logTag: String, warning: Warning? = nil) {
        self.warning = warning ?? { count in
            let noun = count == 1 ? "file" : "files"
            AppLog.warn(logTag, "Could not read \(count) local usage log \(noun); skipped for this refresh")
        }
    }

    func update(failingPaths nextFailingPaths: Set<String>) {
        let newlyFailing = nextFailingPaths.subtracting(failingPaths)
        failingPaths = nextFailingPaths
        guard !newlyFailing.isEmpty else { return }
        warning(newlyFailing.count)
    }
}

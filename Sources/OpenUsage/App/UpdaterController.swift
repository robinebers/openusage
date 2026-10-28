import AppKit
import Combine
import Foundation
import Observation
import Sparkle

/// Wraps Sparkle's standard updater so the rest of the app stays Sparkle-agnostic.
///
/// The updater starts whenever the app runs from a packaged bundle that declares a `SUFeedURL`. Only the
/// signed release build bakes one in, so the Settings "Updates" section appears there alone. A bare
/// `swift run` and the in-place dev build ship no feed, leaving the updater dormant and the section
/// hidden. See `docs/updates.md` for the user-facing behavior.
///
/// It is also both of Sparkle's delegates. `SPUUpdaterDelegate` is main-actor isolated in Sparkle;
/// `SPUStandardUserDriverDelegate` is nonisolated, so its methods are `nonisolated` here and assume the
/// main actor, which Sparkle calls them on.
@MainActor
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    private(set) var isActive = false
    private(set) var canCheckForUpdates = false
    var availableUpdateVersion: String?

    var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
            controller?.updater.resetUpdateCycle()
            AppLog.info(.updates, "channel set to \(self.betaChannelEnabled ? "early access" : "stable")")
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
        super.init()
    }

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.info(.updates, "disabled: no SUFeedURL (unbundled or dev build)")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        isActive = true
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        AppLog.info(.updates, "started (feed present)")
    }

    func checkForUpdates() {
        guard let controller else { return }
        // Sparkle 2.9.4 also activates dockless apps with `ignoringOtherApps`, but promote OpenUsage
        // before handing control over so the activation-policy transition cannot leave Sparkle's
        // checking window behind the currently active app. The next-runloop handoff mirrors the
        // workaround verified in sparkle-project/Sparkle#2889.
        bringToFront(reason: "user initiated check")
        DispatchQueue.main.async {
            controller.checkForUpdates(nil)
        }
    }

    func dismissAvailableUpdate() {
        availableUpdateVersion = nil
    }

    /// The app runs as an accessory (no Dock icon), so Sparkle's update window would open behind
    /// everything and without focus. Become a regular app while the update UI is on screen.
    /// `NSApplication.activate()` is unreliable when another app is active (sparkle-project/Sparkle#2889),
    /// so this deliberately uses the older API that ignores the current foreground app.
    private func bringToFront(reason: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.info(.updates, "foreground updater (reason=\(reason))")
    }

    /// Stable channel is the default (every user). Returning `["beta"]` additionally opts a user into
    /// pre-release items tagged `<sparkle:channel>beta</sparkle:channel>`; Sparkle always includes the
    /// default channel regardless, so stable users are never starved of stable releases.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        betaChannelEnabled ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let channel = betaChannelEnabled ? "early access" : "stable"
        guard let error else {
            AppLog.info(.updates, "check finished (channel=\(channel), no error)")
            return
        }
        let code = (error as NSError).code
        if code == Int(SUError.noUpdateError.rawValue) {
            AppLog.info(.updates, "check finished (channel=\(channel), no update available)")
        } else if code == Int(SUError.installationCanceledError.rawValue) {
            AppLog.info(.updates, "check finished (channel=\(channel), user canceled)")
        } else {
            AppLog.warn(.updates, "check/download failed: \(error.localizedDescription)")
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Take over showing *scheduled* updates entirely: for a dockless app macOS would put Sparkle's
    /// window behind everything (even the "immediate focus" launch case is unreliable), so instead of
    /// a buried window the update surfaces as the in-popover banner. User-initiated checks never reach
    /// this method — Sparkle always shows those itself, in front.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            guard handleShowingUpdate else {
                availableUpdateVersion = version
                AppLog.info(.updates, "scheduled check found \(version); showing in-app banner")
                return
            }
            bringToFront(reason: "Sparkle will show update")
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            availableUpdateVersion = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            AppLog.info(.updates, "finish updater presentation")
            availableUpdateVersion = nil
        }
    }
}

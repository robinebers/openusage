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
    /// `UserDefaults` key for the beta-channel opt-in.
    private static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    /// True once the real updater is running (release build with a feed). Settings reads this to decide
    /// whether to show the Updates section at all.
    private(set) var isActive = false
    /// Mirrors Sparkle's KVO `canCheckForUpdates`; drives the "Check for Updates…" button's enabled state.
    private(set) var canCheckForUpdates = false
    /// The display version of an update a *scheduled* check found (e.g. "0.8.1"), or `nil` when there's
    /// none pending. Set instead of showing Sparkle's window (which macOS keeps behind other apps for
    /// dockless apps); the dashboard renders it as an "Update Available" banner whose install button
    /// routes through `checkForUpdates()` — a user-initiated check, which Sparkle brings to the front.
    var availableUpdateVersion: String?

    /// Backs the "Beta Updates" toggle. Persisted to `UserDefaults`; flipping it resets Sparkle's update
    /// cycle so the new channel set takes effect on the next scheduled check instead of a day later.
    var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
            controller?.updater.resetUpdateCycle()
            AppLog.info(.updates, "channel set to \(self.betaChannelEnabled ? "early access" : "stable")")
        }
    }

    /// Backs the "Check Automatically" toggle. Sparkle persists this in `UserDefaults` itself,
    /// so this is a thin pass-through rather than a shadow preference.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
        super.init()
    }

    /// Starts the updater if (and only if) this build ships an appcast feed. Safe to call once at launch.
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
        // Bridge Sparkle's KVO property into our `@Observable` state so SwiftUI tracks button enablement.
        // Delivery is forced onto the main queue so the main-actor mutation below is always valid.
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        AppLog.info(.updates, "started (feed present)")
    }

    /// User-initiated check. Shows Sparkle's standard UI (progress, release notes, install prompt).
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

    /// The banner's dismiss action for this found update. Sparkle's next scheduled check re-surfaces
    /// it, so a dismissal is a snooze — not a permanent skip (that stays in Sparkle's own window).
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

    // MARK: - SPUUpdaterDelegate

    /// Stable channel is the default (every user). Returning `["beta"]` additionally opts a user into
    /// pre-release items tagged `<sparkle:channel>beta</sparkle:channel>`; Sparkle always includes the
    /// default channel regardless, so stable users are never starved of stable releases.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        betaChannelEnabled ? ["beta"] : []
    }

    /// Records the result of each update cycle. `SUNoUpdateError`/`SUInstallationCanceledError` are
    /// normal outcomes, not failures, so they log at Info; a genuine error (network, download) logs at
    /// Warn. The error is framework-sourced (no secrets) but still routed through `AppLog` for one
    /// consistent format.
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

    // MARK: - SPUStandardUserDriverDelegate

    /// Opt into "gentle" reminders: as a menu-bar (accessory) app we don't want Sparkle stealing focus
    /// with an alert for scheduled checks.
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

    /// Comes to the front only when Sparkle will actually show its window (`handleShowingUpdate`). For a
    /// scheduled update declined above, it passes `false` and shows no window — that's where the banner
    /// state gets published instead; flipping to `.regular` there would flash a Dock icon with nothing
    /// behind it.
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

    /// The user reached Sparkle's window for this update (e.g. via the banner's install button) — the
    /// banner has done its job, drop it.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            availableUpdateVersion = nil
        }
    }

    /// Drops back to a pure menu-bar app once the update session ends, and clears any in-app indicator
    /// still left behind by a dismissal, skip, install, or failure.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            AppLog.info(.updates, "finish updater presentation")
            availableUpdateVersion = nil
        }
    }
}

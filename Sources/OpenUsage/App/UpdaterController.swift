import AppKit
import Combine
import Foundation
import Observation
import os
import Sparkle

/// Wraps Sparkle's standard updater so the rest of the app stays Sparkle-agnostic.
///
/// The updater starts whenever the app runs from a packaged bundle that declares a `SUFeedURL`. Only the
/// signed release build bakes one in, so the Settings "Updates" section appears there alone. A bare
/// `swift run` and the in-place dev build ship no feed, leaving the updater dormant and the section
/// hidden. See `docs/updates.md` for the user-facing behavior.
@MainActor
@Observable
final class UpdaterController {
    /// `UserDefaults` key for the early-access (beta channel) opt-in. Read in two places — the SwiftUI
    /// toggle here and the Sparkle channel delegate's `allowedChannels` — so the stored default is the
    /// single source of truth rather than a cached property.
    static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    private static let logger = Logger(subsystem: "OpenUsage", category: "Updater")

    // Two delegates on purpose: SPUUpdaterDelegate is main-actor isolated in Sparkle, while
    // SPUStandardUserDriverDelegate is nonisolated. Conforming to both from one class would infer a
    // single isolation and break one of the two conformances under Swift 6.
    private let channelDelegate = UpdaterChannelDelegate()
    private let userDriverDelegate = UpdaterUserDriverDelegate()
    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    /// True once the real updater is running (release build with a feed). Settings reads this to decide
    /// whether to show the Updates section at all.
    private(set) var isActive = false
    /// Mirrors Sparkle's KVO `canCheckForUpdates`; drives the "Check for Updates…" button's enabled state.
    private(set) var canCheckForUpdates = false

    /// Backs the early-access toggle. Persisted to `UserDefaults`; flipping it resets Sparkle's update
    /// cycle so the new channel set takes effect on the next scheduled check instead of a day later.
    var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
            controller?.updater.resetUpdateCycle()
            Self.logger.info("Update channel set to \(self.betaChannelEnabled ? "early access" : "stable", privacy: .public)")
        }
    }

    /// Backs the "Automatically Check for Updates" toggle. Sparkle persists this in `UserDefaults` itself,
    /// so this is a thin pass-through rather than a shadow preference.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    init() {
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
    }

    /// Starts the updater if (and only if) this build ships an appcast feed. Safe to call once at launch.
    func start() {
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            Self.logger.notice("Updater disabled: no SUFeedURL (unbundled or dev build)")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: userDriverDelegate
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
        Self.logger.info("Updater started (feed present)")
    }

    /// User-initiated check. Shows Sparkle's standard UI (progress, release notes, install prompt).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Channel selection. `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR` (main-actor) in Sparkle, so this
/// delegate is too — which lets `allowedChannels` read the main-actor-isolated defaults key directly.
@MainActor
private final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    /// Stable channel is the default (every user). Returning `["beta"]` additionally opts a user into
    /// early-access items tagged `<sparkle:channel>beta</sparkle:channel>`; Sparkle always includes the
    /// default channel regardless, so stable users are never starved of stable releases.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? ["beta"] : []
    }
}

/// The accessory-app activation dance. `SPUStandardUserDriverDelegate` is nonisolated in Sparkle, so
/// this delegate stays nonisolated; its callbacks run on the main thread, so they assume main-actor
/// isolation to touch `NSApp`.
private final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Opt into "gentle" reminders: as a menu-bar (accessory) app we don't want Sparkle stealing focus
    /// with an alert for scheduled checks.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The app runs as an accessory (no Dock icon), so Sparkle's update window would open behind
    /// everything and without focus. Become a regular app while the update UI is on screen…
    ///
    /// Only when Sparkle will actually show that window (`handleShowingUpdate`). For a gentle scheduled
    /// reminder it passes `false` and shows no window, so flipping to `.regular` there would flash a
    /// Dock icon with nothing behind it — the exact focus-stealing this delegate exists to avoid.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    /// …then drop back to a pure menu-bar app once the update session ends.
    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { () -> Void in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

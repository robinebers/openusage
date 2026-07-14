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
@MainActor
@Observable
final class UpdaterController {
    /// `UserDefaults` key for the beta-channel opt-in. Read in two places — the SwiftUI
    /// toggle here and the Sparkle channel delegate's `allowedChannels` — so the stored default is the
    /// single source of truth rather than a cached property.
    static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    // Two delegates on purpose: SPUUpdaterDelegate is main-actor isolated in Sparkle, while
    // SPUStandardUserDriverDelegate is nonisolated. Conforming to both from one class would infer a
    // single isolation and break one of the two conformances under Swift 6.
    private let channelDelegate = UpdaterChannelDelegate()
    private let userDriverDelegate = UpdaterUserDriverDelegate()
    private let presentationController: UpdaterPresentationController
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
    private(set) var availableUpdateVersion: String?

    /// Backs the "Beta Updates" toggle. Persisted to `UserDefaults`; flipping it resets Sparkle's update
    /// cycle so the new channel set takes effect on the next scheduled check instead of a day later.
    var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
            controller?.updater.resetUpdateCycle()
            AppLog.info(.updates, "channel set to \(self.betaChannelEnabled ? "early access" : "stable")")
        }
    }

    /// Backs the "Update Automatically" toggle. Sparkle persists this in `UserDefaults` itself,
    /// so this is a thin pass-through rather than a shadow preference.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    init(presentationController: UpdaterPresentationController = UpdaterPresentationController()) {
        self.presentationController = presentationController
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
    }

    /// Starts the updater if (and only if) this build ships an appcast feed. Safe to call once at launch.
    func start() {
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.info(.updates, "disabled: no SUFeedURL (unbundled or dev build)")
            return
        }
        // The driver delegate's callbacks run on the main thread but the delegate itself is
        // nonisolated (see below); these hops publish the banner state back onto this controller.
        userDriverDelegate.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
            AppLog.info(.updates, "scheduled check found \(version); showing in-app banner")
        }
        userDriverDelegate.onUpdateResolved = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        userDriverDelegate.onUpdateWillShow = { [weak self] in
            self?.presentationController.bringToFront(reason: "Sparkle will show update")
        }
        userDriverDelegate.onUpdateSessionFinished = { [weak self] in
            self?.presentationController.returnToMenuBar()
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
        AppLog.info(.updates, "started (feed present)")
    }

    /// User-initiated check. Shows Sparkle's standard UI (progress, release notes, install prompt).
    func checkForUpdates() {
        guard let controller else { return }
        // Sparkle 2.9.4 also activates dockless apps with `ignoringOtherApps`, but promote OpenUsage
        // before handing control over so the activation-policy transition cannot leave Sparkle's
        // checking window behind the currently active app. The next-runloop handoff mirrors the
        // workaround verified in sparkle-project/Sparkle#2889.
        presentationController.bringToFront(reason: "user initiated check")
        DispatchQueue.main.async {
            controller.checkForUpdates(nil)
        }
    }

    /// The banner's install action. A user-initiated check: if the banner's update is still current,
    /// Sparkle re-presents it in frontmost focus (its window, release notes, and install button).
    func installAvailableUpdate() {
        checkForUpdates()
    }

    /// The banner's dismiss action for this found update. Sparkle's next scheduled check re-surfaces
    /// it, so a dismissal is a snooze — not a permanent skip (that stays in Sparkle's own window).
    func dismissAvailableUpdate() {
        availableUpdateVersion = nil
    }
}

/// Owns the narrow AppKit boundary required to present Sparkle from a dockless menu-bar app.
///
/// `NSApplication.activate()` is unreliable when another app is active (sparkle-project/Sparkle#2889),
/// so user-initiated update UI deliberately uses the older API that ignores the current foreground app.
/// The injected closures keep that behavior unit-testable without trying to automate macOS focus.
@MainActor
final class UpdaterPresentationController {
    private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let isActive: @MainActor () -> Bool
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let activate: @MainActor (Bool) -> Void

    convenience init(application: NSApplication = .shared) {
        self.init(
            activationPolicy: { application.activationPolicy() },
            isActive: { application.isActive },
            setActivationPolicy: { application.setActivationPolicy($0) },
            activate: { application.activate(ignoringOtherApps: $0) }
        )
    }

    init(
        activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        isActive: @escaping @MainActor () -> Bool,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        activate: @escaping @MainActor (Bool) -> Void
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
    }

    func bringToFront(reason: String) {
        let beforePolicy = activationPolicy()
        let beforeActive = isActive()
        let policyChanged = setActivationPolicy(.regular)
        activate(true)
        AppLog.info(
            .updates,
            "foreground updater (reason=\(reason), policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(beforeActive)->\(isActive()), policyChanged=\(policyChanged))"
        )
    }

    func returnToMenuBar() {
        let beforePolicy = activationPolicy()
        let policyChanged = setActivationPolicy(.accessory)
        AppLog.info(
            .updates,
            "finish updater presentation (policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(isActive()), policyChanged=\(policyChanged))"
        )
    }
}

/// Channel selection. `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR` (main-actor) in Sparkle, so this
/// delegate is too — which lets `allowedChannels` read the main-actor-isolated defaults key directly.
@MainActor
private final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    /// Stable channel is the default (every user). Returning `["beta"]` additionally opts a user into
    /// pre-release items tagged `<sparkle:channel>beta</sparkle:channel>`; Sparkle always includes the
    /// default channel regardless, so stable users are never starved of stable releases.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? ["beta"] : []
    }

    /// Records the result of each update cycle (per the issue's "Sparkle check result + channel"
    /// item). `SUNoUpdateError`/`SUInstallationCanceledError` are normal outcomes, not failures, so
    /// they log at Info; a genuine error (network, download) logs at Warn. The error is
    /// framework-sourced (no secrets) but still routed through `AppLog` for one consistent format.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let channel = UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? "early access" : "stable"
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
}

/// The accessory-app activation dance. `SPUStandardUserDriverDelegate` is nonisolated in Sparkle, so
/// this delegate stays nonisolated; its callbacks run on the main thread, so they assume main-actor
/// isolation to touch `NSApp`.
final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Publishes "a scheduled check found version X" back to `UpdaterController` (main actor), which
    /// renders it as the dashboard's update banner.
    var onUpdateFound: (@MainActor @Sendable (String) -> Void)?
    /// Clears the banner — the user gave the update attention (Sparkle's window is up) or the update
    /// session ended (installed, skipped, or dismissed).
    var onUpdateResolved: (@MainActor @Sendable () -> Void)?
    /// Reasserts foreground activation immediately before Sparkle presents user-facing update UI.
    var onUpdateWillShow: (@MainActor @Sendable () -> Void)?
    /// Restores OpenUsage to its normal dockless activation policy after Sparkle finishes the session.
    var onUpdateSessionFinished: (@MainActor @Sendable () -> Void)?

    /// Opt into "gentle" reminders: as a menu-bar (accessory) app we don't want Sparkle stealing focus
    /// with an alert for scheduled checks.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Take over showing *scheduled* updates entirely: for a dockless app macOS would put Sparkle's
    /// window behind everything (even the "immediate focus" launch case is unreliable), so instead of
    /// a buried window the update surfaces as the in-popover banner via `onUpdateFound`. User-initiated
    /// checks never reach this method — Sparkle always shows those itself, in front.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// The app runs as an accessory (no Dock icon), so Sparkle's update window would open behind
    /// everything and without focus. Become a regular app while the update UI is on screen…
    ///
    /// Only when Sparkle will actually show that window (`handleShowingUpdate`). For a scheduled
    /// update we declined above, it passes `false` and shows no window — that's where the banner
    /// state gets published instead; flipping to `.regular` there would flash a Dock icon with
    /// nothing behind it — the exact focus-stealing this delegate exists to avoid.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        // Hoisted so the main-actor closure captures only the Sendable callback, not this
        // nonisolated `self` (which Swift 6 region isolation rejects).
        let onUpdateFound = onUpdateFound
        let onUpdateWillShow = onUpdateWillShow
        MainActor.assumeIsolated {
            guard handleShowingUpdate else {
                onUpdateFound?(version)
                return
            }
            onUpdateWillShow?()
        }
    }

    /// The user reached Sparkle's window for this update (e.g. via the banner's install button) — the
    /// banner has done its job, drop it.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        let onUpdateResolved = onUpdateResolved
        MainActor.assumeIsolated { () -> Void in
            onUpdateResolved?()
        }
    }

    /// …then drop back to a pure menu-bar app once the update session ends and clear any in-app
    /// indicator still left behind by a dismissal, skip, install, or failure.
    func standardUserDriverWillFinishUpdateSession() {
        let onUpdateResolved = onUpdateResolved
        let onUpdateSessionFinished = onUpdateSessionFinished
        MainActor.assumeIsolated { () -> Void in
            onUpdateSessionFinished?()
            onUpdateResolved?()
        }
    }
}

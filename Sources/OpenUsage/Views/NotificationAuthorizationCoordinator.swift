import Observation
import UserNotifications

/// The narrow notification-authorization surface Settings needs. `requestAuthorization()` returns
/// the service's memoized task, so every caller can await the same system prompt without starting a
/// second request.
@MainActor
protocol NotificationAuthorizationClient: AnyObject {
    @discardableResult
    func requestAuthorization() -> Task<Bool, Never>
    func authorizationStatus() async -> UNAuthorizationStatus
    func openSystemNotificationsSettings()
}

extension AppNotifications: NotificationAuthorizationClient {}

/// View-local Settings state for notification permission. It sequences the system request before the
/// status read, which keeps the warning/action row from racing ahead while the macOS prompt is open.
@MainActor
@Observable
final class NotificationAuthorizationCoordinator {
    enum State: Equatable {
        case authorized
        case denied
        case notDetermined
    }

    private(set) var state: State = .authorized

    @ObservationIgnored private let client: any NotificationAuthorizationClient
    /// Lets lifecycle-driven refreshes join the service's memoized prompt instead of publishing its
    /// interim `.notDetermined` status. Keeping the completed task also lets a status read that began
    /// before the request notice that a request crossed it and re-read the final decision.
    @ObservationIgnored private var authorizationRequest: Task<Bool, Never>?

    init(client: any NotificationAuthorizationClient = AppNotifications.shared) {
        self.client = client
    }

    /// Refresh the live system status only when an alert trigger is enabled. With every trigger off,
    /// permission is irrelevant and Settings intentionally shows no warning.
    func refresh(isEnabled: Bool) async {
        guard isEnabled else {
            state = .authorized
            return
        }

        let requestAtStart = authorizationRequest
        if let requestAtStart {
            _ = await requestAtStart.value
        }

        var status = await client.authorizationStatus()
        if requestAtStart == nil, let authorizationRequest {
            // A request began while the status read was suspended. Join it and replace the interim
            // value with the decision macOS reports after the prompt closes.
            _ = await authorizationRequest.value
            status = await client.authorizationStatus()
        }

        switch status {
        case .denied:
            state = .denied
        case .notDetermined:
            state = .notDetermined
        default:
            state = .authorized
        }
    }

    /// Ask macOS, wait for the memoized request to finish, and only then re-read the status that drives
    /// Settings. Reading first would observe `.notDetermined` while the prompt was still in flight.
    func requestThenRefresh(isEnabled: Bool) async {
        authorizationRequest = client.requestAuthorization()
        await refresh(isEnabled: isEnabled)
    }

    /// The action row either opens System Settings for a decision macOS has already denied, or performs
    /// the sequenced request-and-refresh flow while permission is still undecided.
    func performAction(isEnabled: Bool) async {
        if state == .denied {
            client.openSystemNotificationsSettings()
        } else {
            await requestThenRefresh(isEnabled: isEnabled)
        }
    }
}

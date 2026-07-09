import UserNotifications
import XCTest
@testable import OpenUsage

@MainActor
final class NotificationAuthorizationCoordinatorTests: XCTestCase {
    func testToggleFlowWaitsForPromptBeforeRefreshingGrantedStatus() async {
        let client = FakeAuthorizationClient(status: .notDetermined)
        let coordinator = NotificationAuthorizationCoordinator(client: client)

        let operation = Task {
            await coordinator.requestThenRefresh(isEnabled: true)
        }
        await waitUntil { client.promptInFlight }

        XCTAssertEqual(client.statusReads, 0, "status must not be read while the system prompt is open")
        XCTAssertEqual(coordinator.state, .authorized, "the warning stays suppressed until the prompt resolves")

        client.resolvePrompt(granted: true, status: .authorized)
        await operation.value

        XCTAssertEqual(client.statusReads, 1)
        XCTAssertEqual(coordinator.state, .authorized)
    }

    func testAllowActionWaitsForPromptBeforeRefreshingDeniedStatus() async {
        let client = FakeAuthorizationClient(status: .notDetermined)
        let coordinator = NotificationAuthorizationCoordinator(client: client)
        await coordinator.refresh(isEnabled: true)
        XCTAssertEqual(coordinator.state, .notDetermined)
        XCTAssertEqual(client.statusReads, 1)

        let operation = Task {
            await coordinator.performAction(isEnabled: true)
        }
        await waitUntil { client.promptInFlight }

        XCTAssertEqual(client.statusReads, 1, "Allow must await the prompt before its second status read")

        client.resolvePrompt(granted: false, status: .denied)
        await operation.value

        XCTAssertEqual(client.statusReads, 2)
        XCTAssertEqual(client.systemSettingsOpens, 0)
        XCTAssertEqual(coordinator.state, .denied)
    }

    func testAlreadyDeniedActionOpensSystemSettingsWithoutRequestingAgain() async {
        let client = FakeAuthorizationClient(status: .denied)
        let coordinator = NotificationAuthorizationCoordinator(client: client)
        await coordinator.refresh(isEnabled: true)

        await coordinator.performAction(isEnabled: true)

        XCTAssertEqual(coordinator.state, .denied)
        XCTAssertEqual(client.requestCalls, 0)
        XCTAssertEqual(client.systemSettingsOpens, 1)
    }

    func testLifecycleRefreshJoinsPromptInsteadOfPublishingInterimStatus() async {
        let client = FakeAuthorizationClient(status: .notDetermined)
        let coordinator = NotificationAuthorizationCoordinator(client: client)
        let request = Task { await coordinator.requestThenRefresh(isEnabled: true) }
        await waitUntil { client.promptInFlight }

        let lifecycleRefresh = Task { await coordinator.refresh(isEnabled: true) }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(client.statusReads, 0)
        XCTAssertEqual(coordinator.state, .authorized)

        client.resolvePrompt(granted: true, status: .authorized)
        await request.value
        await lifecycleRefresh.value

        XCTAssertEqual(coordinator.state, .authorized)
        XCTAssertEqual(client.statusReads, 2)
    }

    func testRefreshThatStartedBeforePromptRereadsAfterRequestCompletes() async {
        let client = FakeAuthorizationClient(status: .notDetermined)
        let coordinator = NotificationAuthorizationCoordinator(client: client)
        client.suspendNextStatusRead()

        let lifecycleRefresh = Task { await coordinator.refresh(isEnabled: true) }
        await waitUntil { client.statusReadInFlight }

        let request = Task { await coordinator.requestThenRefresh(isEnabled: true) }
        await waitUntil { client.promptInFlight }
        client.resolvePrompt(granted: true, status: .authorized)
        await request.value

        client.resolveStatusRead(with: .notDetermined)
        await lifecycleRefresh.value

        XCTAssertEqual(client.statusReads, 3, "the stale read must be replaced after a request crosses it")
        XCTAssertEqual(coordinator.state, .authorized)
    }

    func testRepeatedRequestsShareOneMemoizedPrompt() async {
        let client = FakeAuthorizationClient(status: .notDetermined)
        let coordinator = NotificationAuthorizationCoordinator(client: client)

        let first = Task { await coordinator.requestThenRefresh(isEnabled: true) }
        let second = Task { await coordinator.requestThenRefresh(isEnabled: true) }
        await waitUntil { client.requestCalls == 2 && client.promptInFlight }

        XCTAssertEqual(client.promptStarts, 1, "the client's memoized task must own one system prompt")
        XCTAssertEqual(client.statusReads, 0)

        client.resolvePrompt(granted: true, status: .authorized)
        await first.value
        await second.value

        XCTAssertEqual(client.promptStarts, 1)
        XCTAssertEqual(client.statusReads, 2, "each completed flow may refresh from the same prompt result")
        XCTAssertEqual(coordinator.state, .authorized)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
    }
}

@MainActor
private final class FakeAuthorizationClient: NotificationAuthorizationClient {
    var status: UNAuthorizationStatus
    private(set) var requestCalls = 0
    private(set) var promptStarts = 0
    private(set) var statusReads = 0
    private(set) var systemSettingsOpens = 0

    private var authorizationTask: Task<Bool, Never>?
    private var promptContinuation: CheckedContinuation<Bool, Never>?
    private var shouldSuspendStatusRead = false
    private var statusContinuation: CheckedContinuation<UNAuthorizationStatus, Never>?

    var promptInFlight: Bool { promptContinuation != nil }
    var statusReadInFlight: Bool { statusContinuation != nil }

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization() -> Task<Bool, Never> {
        requestCalls += 1
        if let authorizationTask { return authorizationTask }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            promptStarts += 1
            return await withCheckedContinuation { continuation in
                promptContinuation = continuation
            }
        }
        authorizationTask = task
        return task
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusReads += 1
        if shouldSuspendStatusRead {
            shouldSuspendStatusRead = false
            return await withCheckedContinuation { continuation in
                statusContinuation = continuation
            }
        }
        return status
    }

    func openSystemNotificationsSettings() {
        systemSettingsOpens += 1
    }

    func resolvePrompt(granted: Bool, status: UNAuthorizationStatus) {
        self.status = status
        let continuation = promptContinuation
        promptContinuation = nil
        continuation?.resume(returning: granted)
    }

    func suspendNextStatusRead() {
        shouldSuspendStatusRead = true
    }

    func resolveStatusRead(with status: UNAuthorizationStatus) {
        let continuation = statusContinuation
        statusContinuation = nil
        continuation?.resume(returning: status)
    }
}

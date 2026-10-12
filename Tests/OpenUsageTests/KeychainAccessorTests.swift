import Dispatch
import Security
import XCTest
@testable import OpenUsage

final class KeychainAccessorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainAccessGuard.forgetDenials()
    }

    func testItemNotFoundReturnsNil() throws {
        let accessor = SecurityKeychainAccessor(
            itemAccessor: StubItemAccessor(readStatus: errSecItemNotFound)
        )
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        let accessor = SecurityKeychainAccessor(
            itemAccessor: StubItemAccessor(readStatus: errSecInteractionNotAllowed)
        )
        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Test")) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testFoundValueIsReturnedTrimmed() throws {
        let accessor = SecurityKeychainAccessor(
            itemAccessor: StubItemAccessor(data: Data("secret-token\n".utf8))
        )
        XCTAssertEqual(try accessor.readGenericPassword(service: "Test"), "secret-token")
    }

    func testExplicitAccountReadAndWriteUseTheSameItem() throws {
        let itemAccessor = StubItemAccessor()
        let accessor: any KeychainAccessing = SecurityKeychainAccessor(itemAccessor: itemAccessor)
        let account = "cli|0123456789abcdef"

        _ = try accessor.readGenericPassword(service: "Codex Auth", account: account)
        try accessor.writeGenericPassword(service: "Codex Auth", account: account, value: "synthetic-token")

        XCTAssertEqual(itemAccessor.requests, [
            .init(operation: .read, service: "Codex Auth", account: account),
            .init(operation: .update, service: "Codex Auth", account: account),
        ])
    }

    func testExplicitAccountWriteFailurePropagates() {
        let accessor = SecurityKeychainAccessor(
            itemAccessor: StubItemAccessor(updateStatus: errSecInteractionNotAllowed)
        )
        XCTAssertThrowsError(try accessor.writeGenericPassword(
            service: "Codex Auth", account: "cli|0123456789abcdef", value: "synthetic-token"
        )) { error in
            guard case KeychainError.writeFailed = error else {
                return XCTFail("expected KeychainError.writeFailed, got \(error)")
            }
        }
    }

    func testUnsupportedAccountWriteDoesNotFallBackToServiceOnly() {
        let keychain = FakeKeychain("original")
        XCTAssertThrowsError(try keychain.writeGenericPassword(
            service: "Codex Auth", account: "cli|0123456789abcdef", value: "replacement"
        ))
        XCTAssertEqual(keychain.value, "original")
    }

    func testWriteAddsOnlyWhenNoExistingItemMatches() throws {
        let itemAccessor = StubItemAccessor(updateStatus: errSecItemNotFound)
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)

        try accessor.writeGenericPassword(
            service: "Codex Auth",
            account: "cli|0123456789abcdef",
            value: "synthetic-token"
        )

        XCTAssertEqual(itemAccessor.requests.map(\.operation), [.update, .add])
    }

    func testServiceOnlyWriteUpdatesTheFirstMatchingAccount() throws {
        let itemAccessor = StubItemAccessor(lookupAccount: "legacy")
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)

        try accessor.writeGenericPassword(service: "Cursor", value: "synthetic-token")

        XCTAssertEqual(itemAccessor.requests, [
            .init(operation: .lookup, service: "Cursor", account: nil),
            .init(operation: .update, service: "Cursor", account: "legacy"),
        ])
    }

    func testServiceOnlyWriteAddsWithoutAccountWhenNoItemMatches() throws {
        let itemAccessor = StubItemAccessor(lookupStatus: errSecItemNotFound)
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)

        try accessor.writeGenericPassword(service: "Cursor", value: "synthetic-token")

        XCTAssertEqual(itemAccessor.requests, [
            .init(operation: .lookup, service: "Cursor", account: nil),
            .init(operation: .add, service: "Cursor", account: nil),
        ])
    }

    func testServiceOnlyWriteLookupFailurePropagatesWithoutUpdatingOrAdding() {
        let itemAccessor = StubItemAccessor(lookupStatus: errSecInteractionNotAllowed)
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: "Cursor", value: "synthetic-token")) { error in
            guard case KeychainError.writeFailed = error else {
                return XCTFail("expected KeychainError.writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(itemAccessor.requests, [
            .init(operation: .lookup, service: "Cursor", account: nil),
        ])
    }

    func testDifferentServiceReadDoesNotWaitForBlockedRead() {
        let slowReadStarted = DispatchSemaphore(value: 0)
        let releaseSlowRead = DispatchSemaphore(value: 0)
        let itemAccessor = BlockingItemAccessor(
            slowReadStarted: slowReadStarted,
            releaseSlowRead: releaseSlowRead
        )
        let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)
        let readsFinished = DispatchGroup()
        let slowReadFinished = expectation(description: "Slow read finishes")
        let fastReadFinished = expectation(description: "Fast read finishes")

        readsFinished.enter()
        DispatchQueue.global().async {
            defer {
                readsFinished.leave()
                slowReadFinished.fulfill()
            }
            _ = try? accessor.readGenericPassword(service: "Slow")
        }

        guard slowReadStarted.wait(timeout: .now() + 1) == .success else {
            releaseSlowRead.signal()
            XCTFail("Slow read did not reach the blocking stub")
            wait(for: [slowReadFinished], timeout: 1)
            XCTAssertEqual(readsFinished.wait(timeout: .now() + 1), .success)
            return
        }

        readsFinished.enter()
        DispatchQueue.global().async {
            defer {
                readsFinished.leave()
                fastReadFinished.fulfill()
            }
            _ = try? accessor.readGenericPassword(service: "Fast")
        }

        let fastReadFinishedBeforeRelease = XCTWaiter.wait(for: [fastReadFinished], timeout: 0.5) == .completed
        releaseSlowRead.signal()
        wait(for: [slowReadFinished], timeout: 1)
        XCTAssertEqual(readsFinished.wait(timeout: .now() + 1), .success, "Both reads should finish")
        XCTAssertTrue(fastReadFinishedBeforeRelease, "Fast read should not wait for the Slow service lock")
    }

    func testExistenceCheckThroughTheProtocolDoesNotReadTheSecret() {
        let keychain: any KeychainAccessing = MetadataOnlyKeychain()

        XCTAssertEqual(keychain.genericPasswordExists(service: "Codex Auth"), true)
    }

    func testDeniedOrCancelledPopupIsNotShownAgain() {
        for (service, status) in [("Denied Login", errSecAuthFailed), ("Cancelled Login", errSecUserCanceled)] {
            let itemAccessor = StubItemAccessor(readStatus: status)
            let accessor = SecurityKeychainAccessor(itemAccessor: itemAccessor)

            XCTAssertThrowsError(try accessor.readGenericPassword(service: service))
            XCTAssertThrowsError(try accessor.readGenericPassword(service: service))

            XCTAssertEqual(itemAccessor.requests.count, 1, "\(service) must not ask again on its own")
        }
    }

    @MainActor
    func testOnlyTheUsersRefreshAsksAgainAfterDeny() async {
        let itemAccessor = StubItemAccessor(readStatus: errSecAuthFailed)
        let runtime = KeychainReadingRuntime(
            keychain: SecurityKeychainAccessor(itemAccessor: itemAccessor),
            service: "Denied Then Refreshed Login"
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: []),
            providers: [runtime]
        )

        await store.refresh(providerID: runtime.provider.id, force: true)
        await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(itemAccessor.requests.count, 1, "refreshes the app starts itself must not ask again after Deny")

        await store.refreshOnUserRequest()
        XCTAssertEqual(itemAccessor.requests.count, 2, "the user's Refresh asks again")
    }

    func testEachLoginIsReadTheWayItsOwnToolSavesIt() throws {
        let inProcess = StubItemAccessor(data: Data("in-process".utf8))
        let securityTool = StubItemAccessor(data: Data("security".utf8))
        let accessor = SecurityKeychainAccessor(itemAccessor: inProcess, securityTool: securityTool)

        for service in [
            "Claude Code-credentials", "gh:github.com", "cursor-access-token", "cursor-refresh-token", "gemini",
            "com.robinebers.openusage.icloud-sync-device-id.v1",
        ] {
            XCTAssertEqual(try accessor.readGenericPassword(service: service), "security", service)
        }
        for service in ["Codex Auth", "claude-swap"] {
            XCTAssertEqual(try accessor.readGenericPassword(service: service), "in-process", service)
        }
    }

    func testHeldPopupsOnlyStopReadsThatCouldAsk() throws {
        let inProcess = StubItemAccessor(data: Data("in-process".utf8))
        let securityTool = StubItemAccessor(data: Data("security".utf8))
        let accessor = SecurityKeychainAccessor(itemAccessor: inProcess, securityTool: securityTool)
        KeychainAccessGuard.holdPopups()
        defer { KeychainAccessGuard.allowPopups() }

        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Codex Auth"))
        XCTAssertEqual(inProcess.requests, [], "a held read must not reach the Keychain, which could show a popup")
        XCTAssertEqual(try accessor.readGenericPassword(service: "Claude Code-credentials"), "security")
        XCTAssertEqual(KeychainAccessGuard.denials(), [], "a held read is not a Deny")

        KeychainAccessGuard.allowPopups()
        XCTAssertEqual(try accessor.readGenericPassword(service: "Codex Auth"), "in-process")
    }

    func testSecurityToolLoginIsSavedThroughTheSecurityTool() throws {
        let inProcess = StubItemAccessor()
        let securityTool = StubItemAccessor(lookupAccount: "cursor-user")
        let accessor = SecurityKeychainAccessor(itemAccessor: inProcess, securityTool: securityTool)

        try accessor.writeGenericPassword(service: "cursor-access-token", value: "renewed")

        XCTAssertEqual(securityTool.requests, [
            .init(operation: .lookup, service: "cursor-access-token", account: nil),
            .init(operation: .update, service: "cursor-access-token", account: "cursor-user"),
        ])
        XCTAssertEqual(inProcess.requests, [])
    }

    private struct MetadataOnlyKeychain: KeychainAccessing {
        func readGenericPassword(service: String) throws -> String? {
            XCTFail("an existence check must not read the secret, which can show a Keychain popup")
            return nil
        }

        func writeGenericPassword(service: String, value: String) throws {}

        func genericPasswordExists(service: String) -> Bool? { true }
    }

    @MainActor
    private final class KeychainReadingRuntime: ProviderRuntime {
        let provider = Provider(id: "keychain-test", displayName: "Keychain Test", icon: .providerMark("codex"))
        let widgetDescriptors: [WidgetDescriptor] = []
        let keychain: SecurityKeychainAccessor
        let service: String

        init(keychain: SecurityKeychainAccessor, service: String) {
            self.keychain = keychain
            self.service = service
        }

        func refresh() async -> ProviderSnapshot {
            _ = try? keychain.readGenericPassword(service: service)
            return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        }
    }

    private final class StubItemAccessor: SecurityItemAccessing, @unchecked Sendable {
        enum Operation: Equatable {
            case read
            case lookup
            case update
            case add
        }

        struct Request: Equatable {
            let operation: Operation
            let service: String
            let account: String?
        }

        let readStatus: OSStatus
        let data: Data?
        let lookupStatus: OSStatus
        let lookupAccount: String?
        let updateStatus: OSStatus
        let addStatus: OSStatus
        var requests: [Request] = []

        init(
            readStatus: OSStatus = errSecSuccess,
            data: Data? = Data("synthetic-token".utf8),
            lookupStatus: OSStatus = errSecSuccess,
            lookupAccount: String? = "synthetic-account",
            updateStatus: OSStatus = errSecSuccess,
            addStatus: OSStatus = errSecSuccess
        ) {
            self.readStatus = readStatus
            self.data = data
            self.lookupStatus = lookupStatus
            self.lookupAccount = lookupAccount
            self.updateStatus = updateStatus
            self.addStatus = addStatus
        }

        func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
            requests.append(.init(operation: .read, service: service, account: account))
            return (readStatus, data)
        }

        func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
            requests.append(.init(operation: .lookup, service: service, account: nil))
            return (lookupStatus, lookupAccount)
        }

        func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            requests.append(.init(operation: .update, service: service, account: account))
            return updateStatus
        }

        func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            requests.append(.init(operation: .add, service: service, account: account))
            return addStatus
        }
    }

    private final class BlockingItemAccessor: SecurityItemAccessing, @unchecked Sendable {
        let slowReadStarted: DispatchSemaphore
        let releaseSlowRead: DispatchSemaphore

        init(slowReadStarted: DispatchSemaphore, releaseSlowRead: DispatchSemaphore) {
            self.slowReadStarted = slowReadStarted
            self.releaseSlowRead = releaseSlowRead
        }

        func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
            if service == "Slow" {
                slowReadStarted.signal()
                releaseSlowRead.wait()
            }
            return (errSecItemNotFound, nil)
        }

        func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
            (errSecItemNotFound, nil)
        }

        func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            errSecSuccess
        }

        func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            errSecSuccess
        }
    }
}

import Security
import LocalAuthentication
import XCTest
@testable import OpenUsage

final class KeychainInteractionTests: XCTestCase {
    func testQuietQueryForbidsEveryPromptButInteractiveQueryAllowsThem() {
        let query = KeychainSystemAccess.genericPasswordQuery(service: "synthetic", account: "account", interactive: false)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "account")
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        let interactive = KeychainSystemAccess.genericPasswordQuery(service: "synthetic", account: nil, interactive: true)
        XCTAssertEqual(interactive[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIAllow as String)
        XCTAssertNil(interactive[kSecAttrAccount as String])
        XCTAssertNil(interactive[kSecUseAuthenticationContext as String])
    }

    func testBackgroundKeychainDoesNotWaitBehindPermissionDialog() {
        let gate = KeychainOperationGate()
        XCTAssertTrue(gate.acquire(interactive: true))
        XCTAssertFalse(gate.acquire(interactive: false))
        gate.release()
        XCTAssertTrue(gate.acquire(interactive: false))
        gate.release()
    }

    func testNativeKeychainCallsAreSuppressedInTestRunner() {
        var called = false
        let status = KeychainSystemAccess.perform(interactive: true, unavailable: errSecInteractionNotAllowed) {
            called = true
            return errSecSuccess
        }
        XCTAssertFalse(called)
        XCTAssertEqual(status, errSecInteractionNotAllowed)
    }

    func testExistenceProbeUsesProtocolWitnessInsteadOfReadingSecret() {
        let items = Items()
        let keychain: any KeychainAccessing = SecurityKeychainAccessor(itemAccessor: items)
        XCTAssertEqual(keychain.genericPasswordExists(service: "synthetic"), true)
        XCTAssertEqual(items.probes, 1)
        XCTAssertEqual(items.reads, 0)
    }

    func testMissingItemIsNotDetectedAndUnknownStaysUnknown() {
        XCTAssertEqual(SecurityKeychainAccessor(itemAccessor: Items(probe: errSecItemNotFound))
            .genericPasswordExists(service: "missing"), false)
        XCTAssertNil(SecurityKeychainAccessor(itemAccessor: Items(probe: errSecInteractionNotAllowed))
            .genericPasswordExists(service: "locked"))
    }

    func testDeniedReadIsRecordedAsPermissionNeeded() throws {
        let context = KeychainAccessContext(allowsInteraction: false)
        let keychain = SecurityKeychainAccessor(itemAccessor: Items(read: errSecInteractionNotAllowed))
        try KeychainAccessContext.$current.withValue(context) {
            XCTAssertThrowsError(try keychain.readGenericPassword(service: "synthetic"))
        }
        XCTAssertEqual(context.refused, .permissionNeeded)
    }

    func testBusyGateIsNotReportedAsADenial() throws {
        let context = KeychainAccessContext(allowsInteraction: false)
        let keychain = SecurityKeychainAccessor(itemAccessor: Items(read: KeychainSystemAccess.busyStatus))
        try KeychainAccessContext.$current.withValue(context) {
            XCTAssertThrowsError(try keychain.readGenericPassword(service: "synthetic"))
        }
        XCTAssertEqual(context.refused, .busy)
        // A denial later in the same refresh is the more useful explanation and wins.
        context.record(.permissionNeeded)
        XCTAssertEqual(context.refused, .permissionNeeded)
        context.record(.busy)
        XCTAssertEqual(context.refused, .permissionNeeded)
    }

    func testInteractionContextSurvivesBothDetachedLoadHelpers() async throws {
        XCTAssertFalse(KeychainAccessContext.allowsInteraction)
        let context = KeychainAccessContext(allowsInteraction: true)
        let values = try await KeychainAccessContext.$current.withValue(context) {
            let plain = await loadOffMainActor { KeychainAccessContext.allowsInteraction }
            let throwing = try await loadOffMainActor { () throws -> Bool in
                KeychainAccessContext.allowsInteraction
            }
            return [plain, throwing]
        }
        XCTAssertEqual(values, [true, true])
        XCTAssertFalse(KeychainAccessContext.allowsInteraction)
    }

    private final class Items: SecurityItemAccessing, @unchecked Sendable {
        let probe: OSStatus
        let read: OSStatus
        var probes = 0
        var reads = 0
        init(probe: OSStatus = errSecSuccess, read: OSStatus = errSecSuccess) {
            self.probe = probe
            self.read = read
        }
        func probeGenericPassword(service: String) -> OSStatus {
            probes += 1
            return probe
        }
        func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
            reads += 1
            return (read, read == errSecSuccess ? Data("synthetic".utf8) : nil)
        }
        func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) { (errSecSuccess, nil) }
        func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus { errSecSuccess }
        func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus { errSecSuccess }
    }
}

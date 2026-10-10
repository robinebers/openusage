import Security
import LocalAuthentication
import XCTest
@testable import OpenUsage

final class KeychainInteractionTests: XCTestCase {
    func testSystemPasswordQueryDefaultsToNoUI() {
        let query = SystemSecurityItemAccessor.passwordReadQuery(
            service: "synthetic", account: "account", allowsInteraction: false
        )
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "account")
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        let interactive = SystemSecurityItemAccessor.passwordReadQuery(
            service: "synthetic", account: nil, allowsInteraction: true
        )
        XCTAssertEqual(interactive[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIAllow as String)
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

    func testDiscoveryReadsOnlyMetadataAndTracksPermissionRequirement() throws {
        let items = Items()
        let keychain = SecurityKeychainAccessor(itemAccessor: items)
        let context = KeychainAccessContext(mode: .discovery)
        try KeychainAccessContext.$current.withValue(context) {
            XCTAssertThrowsError(try keychain.readGenericPassword(service: "synthetic")) {
                XCTAssertTrue($0 is KeychainPermissionNeeded)
            }
        }
        XCTAssertEqual(items.probes, 1)
        XCTAssertEqual(items.reads, 0)
        XCTAssertTrue(context.needsPermission)
    }

    func testMissingItemIsNotReportedAsDetected() throws {
        let context = KeychainAccessContext(mode: .discovery)
        let keychain = SecurityKeychainAccessor(itemAccessor: Items(present: false))
        try KeychainAccessContext.$current.withValue(context) {
            XCTAssertNil(try keychain.readGenericPassword(service: "missing"))
        }
        XCTAssertFalse(context.needsPermission)
    }

    func testDiscoveryCannotWriteCredentials() throws {
        let items = Items()
        let context = KeychainAccessContext(mode: .discovery)
        try KeychainAccessContext.$current.withValue(context) {
            XCTAssertThrowsError(try SecurityKeychainAccessor(itemAccessor: items)
                .writeGenericPassword(service: "synthetic", value: "synthetic"))
        }
        XCTAssertEqual(items.writes, 0)
    }

    func testInteractionContextSurvivesBothDetachedLoadHelpers() async throws {
        XCTAssertFalse(KeychainAccessContext.allowsInteraction)
        let context = KeychainAccessContext(mode: .interactive)
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
        let present: Bool
        var probes = 0
        var reads = 0
        var writes = 0
        init(present: Bool = true) { self.present = present }
        func probeGenericPassword(service: String, account: String?) -> OSStatus {
            probes += 1
            return present ? errSecSuccess : errSecItemNotFound
        }
        func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
            reads += 1
            return (errSecSuccess, Data("synthetic".utf8))
        }
        func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) { (errSecSuccess, nil) }
        func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            writes += 1
            return errSecSuccess
        }
        func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
            writes += 1
            return errSecSuccess
        }
    }
}

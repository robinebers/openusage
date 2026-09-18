import Foundation
import Security
import XCTest
@testable import OpenUsage

/// #1213: the legacy keychain ignores "no UI" flags, so background reads must not reach it until a
/// manual refresh has read `Claude Safe Storage` once.
final class ClaudeDesktopSafeStorageKeyReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeDesktopSafeStorageKeyReaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBackgroundReadSkipsKeychainUntilAccessWasGranted() {
        let keychain = FakeSafeStorageKeychain(status: errSecSuccess, password: "secret")
        let reader = makeReader(keychain)

        XCTAssertThrowsError(try reader.readPassword(allowInteraction: false)) { error in
            guard case ClaudeDesktopCredentialError.permissionRequired = error else {
                return XCTFail("expected permissionRequired, got \(error)")
            }
        }
        XCTAssertEqual(keychain.calls, 0)
    }

    func testManualReadGrantsLaterBackgroundReads() throws {
        let keychain = FakeSafeStorageKeychain(status: errSecSuccess, password: "secret")
        let reader = makeReader(keychain)

        XCTAssertEqual(try reader.readPassword(allowInteraction: true), "secret")
        XCTAssertEqual(try reader.readPassword(allowInteraction: false), "secret")
        XCTAssertEqual(keychain.calls, 2)
    }

    func testDeniedReadStopsBackgroundReads() throws {
        let keychain = FakeSafeStorageKeychain(status: errSecSuccess, password: "secret")
        let reader = makeReader(keychain)
        _ = try reader.readPassword(allowInteraction: true)

        keychain.status = errSecUserCanceled
        XCTAssertThrowsError(try reader.readPassword(allowInteraction: true))
        XCTAssertThrowsError(try reader.readPassword(allowInteraction: false))
        XCTAssertEqual(keychain.calls, 2)
    }

    private func makeReader(_ keychain: FakeSafeStorageKeychain) -> ClaudeDesktopSafeStorageKeyReader {
        ClaudeDesktopSafeStorageKeyReader(defaults: defaults) { _, result in
            keychain.copyMatching(result)
        }
    }
}

private final class FakeSafeStorageKeychain: @unchecked Sendable {
    var status: OSStatus
    let password: String
    var calls = 0

    init(status: OSStatus, password: String) {
        self.status = status
        self.password = password
    }

    func copyMatching(_ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        calls += 1
        if status == errSecSuccess { result.pointee = Data(password.utf8) as CFData }
        return status
    }
}

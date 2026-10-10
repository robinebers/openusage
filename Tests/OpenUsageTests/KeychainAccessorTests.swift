import Security
import XCTest
@testable import OpenUsage

final class KeychainAccessorTests: XCTestCase {
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
}

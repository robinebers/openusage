import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class SignInAgainTests: XCTestCase {
    private nonisolated static func usage(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.settingsURL {
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        if request.headers["Authorization"] == "Bearer rejected" || request.url == GrokLogin.tokenURL {
            return .init(statusCode: 401, headers: [:], body: Data())
        }
        // Grok's documented response for a valid team account.
        return .init(statusCode: 412, headers: [:], body: Data(#"{"error":"principal has no personal team"}"#.utf8))
    }

    func testRejectsNewOAuthCredentialWhenOnlyOldTokenCanReadUsage() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let old = AccountCredential.oauth(.init(accessToken: "current", refreshToken: "current-r"))
        let account = accounts.add(kind: .grok, label: "Work", credential: old)
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: RoutingHTTPClient { Self.usage($0) })
        let refused = AccountCredential.oauth(.init(accessToken: "rejected", refreshToken: "bad-r"))
        do {
            try await container.replaceCredential(refused, for: account.cardID)
            XCTFail("Replacement reported success for the provider-rejected access and refresh tokens.")
        } catch { }
        XCTAssertTrue(try vault.load(account.id) == old, "A rejected candidate overwrote the working login.")
    }

    func testOnlyASuccessfulSignInAgainLeavesTheAccountPageForTheDefaultTab() async throws {
        let defaults = isolatedDefaults()
        defaults.set(DashboardTab.allUsage.rawValue, forKey: DashboardTab.defaultKey)
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let account = accounts.add(kind: .grok, label: "Work", credential: .oauth(.init(accessToken: "expired")))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: RoutingHTTPClient { Self.usage($0) })
        let popover = container.popover
        popover.openAccounts(account.cardID)
        popover.signingInAgainProviderID = account.cardID
        popover.isAddingAccount = true

        _ = try? await container.signInAgain(.oauth(.init(accessToken: "rejected", refreshToken: "bad-r")), for: account.cardID)
        let cancelled = Task { try await container.signInAgain(.oauth(.init(accessToken: "new")), for: account.cardID) }
        cancelled.cancel()
        _ = try? await cancelled.value
        XCTAssertEqual(popover.screen, .accounts, "A failed or cancelled sign-in left the account's page.")
        XCTAssertEqual(popover.customizeProviderID, account.cardID)
        XCTAssertTrue(popover.isAddingAccount, "A failed sign-in closed the sheet that shows its error.")

        try await container.signInAgain(.oauth(.init(accessToken: "new")), for: account.cardID)
        XCTAssertEqual(popover.screen, .dashboard, "A successful sign-in stayed on the account's page.")
        XCTAssertEqual(popover.dashboardTab, .allUsage, "A successful sign-in did not open the Default Tab.")
        XCTAssertFalse(popover.isAddingAccount)
        XCTAssertNil(popover.customizeProviderID)
    }

    func testOldOAuthRenewalCannotOverwriteTheNewSignIn() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let old = AccountCredential.oauth(.init(accessToken: "old", refreshToken: "old-r", expiresAt: .distantPast))
        let account = accounts.add(kind: .grok, label: "Work", credential: old)
        let grant = HeldResponse()
        let http = RoutingHTTPClient { request in
            if request.url == GrokLogin.tokenURL {
                await grant.hold()
                return .init(statusCode: 200, headers: [:],
                    body: Data(#"{"access_token":"rotated-old","refresh_token":"rotated-old-r","expires_in":7200}"#.utf8))
            }
            return Self.usage(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let oldRefresh = Task { await container.dataStore.refresh(providerID: account.cardID, force: true) }
        await grant.waitUntilHeld()
        let new = AccountCredential.oauth(.init(accessToken: "new", refreshToken: "new-r"))
        let replacement = Task { try await container.replaceCredential(new, for: account.cardID) }
        // Allow a replacement that serializes against the outstanding grant to wait for it.
        for _ in 0..<100 where try vault.load(account.id) != new {
            try await Task.sleep(for: .milliseconds(5))
        }
        await grant.release()
        try await replacement.value
        _ = await oldRefresh.value
        XCTAssertTrue(try vault.load(account.id) == new, "The previous runtime rewrote the same Keychain slot after Sign In Again committed.")
    }
}

@MainActor
final class PR1535ClaudeTests: XCTestCase {
    private func login(token: String, identity: String) -> AccountCredential {
        .oauth(.init(accessToken: token, extras: [OAuthTokens.identityKey: identity]))
    }

    private nonisolated static func successfulUsage() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
    }

    func testARejectedSignInCantPassOnTheSavedTokensRequest() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let saved = login(token: "saved", identity: "same-login/same-org")
        let account = accounts.add(kind: .claude, label: "Work", credential: saved)
        let savedRead = HeldResponse()
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer saved" else { return HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
            await savedRead.hold()
            return Self.successfulUsage()
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)

        let refresh = Task { await container.dataStore.refresh(providerID: account.cardID, force: true) }
        await savedRead.waitUntilHeld()

        let replacing = Task { try await container.replaceCredential(self.login(token: "rejected", identity: "same-login/same-org"), for: account.cardID) }
        try await waitUntil { http.requests.contains { $0.headers["Authorization"] != "Bearer saved" } }
        await savedRead.release()
        _ = await refresh.value

        let result = await replacing.result
        XCTAssertTrue(http.requests.contains { $0.headers["Authorization"] != "Bearer saved" }, "the new sign-in never asked for itself")
        if case .success = result { XCTFail("a rejected sign-in was accepted on the saved token's answer") }
        XCTAssertEqual(try vault.load(account.id), saved)
    }

    func testSignInAgainHonorsPersisted429ForTheSameClaudeIdentity() async throws {
        let defaults = isolatedDefaults()
        let identity = "a4ae1535-bfe9-4489-a97a-c94672cc313a/1e89475b-246e-4833-86e0-af0c11874681"
        let window = ClaudeRateLimitWindow(until: Date().addingTimeInterval(3600), strikes: 1)
        defaults.set(try JSONEncoder().encode([identity: window]), forKey: ClaudeSessions.storageKey)
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let account = accounts.add(kind: .claude, label: "Work", credential: login(token: "old", identity: identity))
        let http = RoutingHTTPClient { _ in Self.successfulUsage() }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        _ = await container.dataStore.refresh(providerID: account.cardID, force: true)
        XCTAssertTrue(http.requests.isEmpty, "Control: the original runtime must observe the saved hold.")
        _ = try? await container.replaceCredential(login(token: "new", identity: identity), for: account.cardID)
        XCTAssertTrue(http.requests.isEmpty, "Signing in again to the same login sent Claude a usage request inside its persisted 429 window.")
    }

    func testClaude429AfterSignInAgainSurvivesRelaunch() async throws {
        let defaults = isolatedDefaults()
        let identity = "claude-person/org"
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let account = accounts.add(kind: .claude, label: "Work", credential: login(token: "old", identity: identity))
        let limited = TestSwitch(false)
        let http = RoutingHTTPClient { _ in
            if limited.value { return HTTPResponse(statusCode: 429, headers: ["retry-after":"3600"], body: Data()) }
            return Self.successfulUsage()
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        try await container.replaceCredential(login(token: "new", identity: identity), for: account.cardID)
        limited.value = true
        _ = await container.dataStore.refresh(providerID: account.cardID, force: true)
        let requestsBeforeRelaunch = http.requests.count
        XCTAssertEqual(requestsBeforeRelaunch, 2)
        let relaunched = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        _ = await relaunched.dataStore.refresh(providerID: account.cardID, force: true)
        XCTAssertEqual(http.requests.count, requestsBeforeRelaunch, "The new runtime's 429 hold did not survive relaunch.")
    }

    func testSignInAgainCannotSilentlyReplaceTheSavedOAuthIdentity() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let old = login(token: "work-token", identity: "claude-work-user/work-org")
        let account = accounts.add(kind: .claude, label: "work@example.test", credential: old)
        let http = RoutingHTTPClient { _ in Self.successfulUsage() }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let personal = login(token: "personal-token", identity: "claude-personal-user/personal-org")
        _ = try? await container.replaceCredential(personal, for: account.cardID)
        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "work@example.test")
        XCTAssertEqual(try vault.load(account.id)?.identity, old.identity, "A different provider identity now backs the existing work account.")
    }
}

@MainActor
final class AlertLevelTests: XCTestCase {
    func testOnlyEnabledHalfAlertStillFiresWhenAReadCrossesBothThresholds() async {
        let provider = Provider(id: "test", kind: .cursor)
        let descriptor = WidgetDescriptor.percent(key: "weekly", provider: provider, title: "Weekly")
        var sent: [String] = []
        let evaluator = QuotaNotificationEvaluator { id, _, _, _ in
            sent.append(id)
            return true
        }
        for used in [40.0, 95.0, 95.0] {
            await evaluator.evaluate(
                [descriptor],
                data: { _ in WidgetData(title: "Weekly", kind: .percent, used: used, limit: 100) },
                isOn: { $0 == .warning },
                now: Date(),
                providerName: { _ in "Cursor" }
            )
        }
        XCTAssertEqual(sent, ["test.\(PaceMilestone.warning.rawValue)"])
    }
}

@MainActor
final class PR1535DetailsTests: XCTestCase {
    func testASecondRecordWithoutAttributionKeepsTheFirstRecordsNamedTurnShare() throws {
        let named = #"{"date":"2026-10-30","totals":{"turns":3,"text_total_tokens":9},"models":[{"model":"A","turns":3}]}"#
        let unnamed = #"{"date":"2026-10-30","totals":{"turns":1,"text_total_tokens":1}}"#
        let date = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-30T00:00:00Z"))
        for records in [[named, unnamed], [unnamed, named]] {
            let source = "{\"data\":[" + records.joined(separator: ",") + "]}"
            let report = try XCTUnwrap(CodexUsageReports.counts(Data(source.utf8)))
            let day = try XCTUnwrap(report.days["2026-10-30"])
            let history = UsageHistory(calendar: Calendar.utc, asOf: date, days: [date: day])
            let details = try XCTUnwrap(UsageBreakdown(.today, in: history))
            XCTAssertEqual(details.totals[.turns], 4)
            XCTAssertEqual(details.totals[.tokens], 10)
            XCTAssertEqual(details.models(by: .share).map(\.name), ["A"])
            XCTAssertEqual(details.models(by: .share).first?.share, 0.75)
        }
    }

}

final class CodexModelTotalsTests: XCTestCase {
    func testModelThatReportsTokensWithoutTurnsRetainsItsTokenRanking() throws {
        let source = #"{"data":[{"date":"2026-10-30","totals":{"turns":2,"text_total_tokens":50},"models":[{"model":"A","credits":0,"text_total_tokens":50}]}]}"#
        let report = try XCTUnwrap(CodexUsageReports.counts(Data(source.utf8)))
        let date = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-30T00:00:00Z"))
        let day = try XCTUnwrap(report.days["2026-10-30"])
        let history = UsageHistory(calendar: Calendar.utc, asOf: date, days: [date: day])
        let details = try XCTUnwrap(UsageBreakdown(.today, in: history))
        XCTAssertEqual(details.models(by: .tokens).first?.tokens, 50)
    }
}

private final class RejectCandidateVault: CredentialVault, @unchecked Sendable {
    let inner = InMemoryCredentialVault()
    let rejectCandidate: Bool
    init(rejectCandidate: Bool) { self.rejectCandidate = rejectCandidate }
    func load(_ id: UUID) throws -> AccountCredential? { try inner.load(id) }
    func save(_ credential: AccountCredential, for id: UUID) throws {
        if rejectCandidate, case .oauth(let value) = credential, value.accessToken == "candidate" {
            throw ProviderError.unavailable("Simulated write failure")
        }
        try inner.save(credential, for: id)
    }
    func update(_ credential: AccountCredential, for id: UUID) throws { try inner.update(credential, for: id) }
    func delete(_ id: UUID) throws { try inner.delete(id) }
}

@MainActor
final class PR1535CancelTests: XCTestCase {
    func testCancelledSignInAgainDoesNotCommitWhileRetiringOldRuntime() async throws {
        try await exercise(rejectCandidate: false)
    }

    func testFailedReplacementKeepsAlreadyRotatedOriginalCredential() async throws {
        try await exercise(rejectCandidate: true)
    }

    private func exercise(rejectCandidate: Bool) async throws {
        let defaults = isolatedDefaults()
        let vault = RejectCandidateVault(rejectCandidate: rejectCandidate)
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let original = AccountCredential.oauth(.init(accessToken: "original", refreshToken: "original-r", expiresAt: .distantPast))
        let account = accounts.add(kind: .grok, label: "Work", credential: original)
        let grant = HeldResponse()
        let stopping = TestSwitch(false)
        let alreadyRotated = TestSwitch(false)
        let http = RoutingHTTPClient { request in
            if request.url == GrokLogin.tokenURL {
                if alreadyRotated.value {
                    return .init(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                await withTaskCancellationHandler {
                    await grant.hold()
                } onCancel: {
                    // The candidate validated and the retiring runtime cancelled its renewal.
                    stopping.value = true
                }
                alreadyRotated.value = true
                return .init(statusCode: 200, headers: [:], body: Data(#"{"access_token":"rotated","refresh_token":"rotated-r","expires_in":7200}"#.utf8))
            }
            if request.url == GrokUsageClient.settingsURL { return .init(statusCode: 200, headers: [:], body: Data("{}".utf8)) }
            return .init(statusCode: 412, headers: [:], body: Data(#"{"error":"principal has no personal team"}"#.utf8))
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let oldRefresh = Task { await container.dataStore.refresh(providerID: account.cardID, force: true) }
        await grant.waitUntilHeld()
        let candidate = AccountCredential.oauth(.init(accessToken: "candidate", refreshToken: "candidate-r"))
        let replacement = Task { try await container.replaceCredential(candidate, for: account.cardID) }
        for _ in 0..<200 where !stopping.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(stopping.value, "Probe did not reach stopRenewals.")
        if !rejectCandidate { replacement.cancel() }
        await grant.release()
        _ = await replacement.result
        _ = await oldRefresh.value
        if !rejectCandidate {
            XCTAssertTrue(try vault.load(account.id) != candidate, "Cancelled sign-in still committed the candidate.")
            return
        }
        let recheck = await container.dataStore.refresh(providerID: account.cardID, force: true)
        XCTAssertEqual(recheck, .refreshed, "The original refresh token had been rotated and the candidate's save failed; the next poll must use the valid retained grant.")
        XCTAssertEqual(http.requests.filter { $0.url == GrokLogin.tokenURL }.count, 1, "The old runtime retried a spent refresh token.")
        guard case .oauth(let kept)? = try vault.load(account.id) else { return XCTFail("The retained grant was lost.") }
        XCTAssertEqual(kept.refreshToken, "rotated-r", "The grant kept while renewals were stopped was not saved once they resumed.")
    }
}

private final class SlowCursorWriteVault: CredentialVault, @unchecked Sendable {
    let inner = InMemoryCredentialVault()
    let waiting = TestSwitch(false)
    let release = DispatchSemaphore(value: 0)
    func load(_ id: UUID) throws -> AccountCredential? { try inner.load(id) }
    func save(_ credential: AccountCredential, for id: UUID) throws { try inner.save(credential, for: id) }
    func update(_ credential: AccountCredential, for id: UUID) throws {
        if case .oauth(let old) = credential, old.accessToken == "legacy-rotation" {
            waiting.value = true
            _ = release.wait(timeout: .now() + 5)
        }
        try inner.update(credential, for: id)
    }
    func delete(_ id: UUID) throws { try inner.delete(id) }
}

extension PR1535CancelTests {
    func testAlreadyStartedCursorKeychainWriteCannotReplaceNewSignIn() async throws {
        let defaults = isolatedDefaults()
        let vault = SlowCursorWriteVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let original = AccountCredential.oauth(.init(accessToken: "original", refreshToken: "r", expiresAt: .distantPast))
        let account = accounts.add(kind: .cursor, label: "Work", credential: original)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.refreshURL:
                return .init(statusCode: 200, headers: [:], body: Data(#"{"access_token":"legacy-rotation"}"#.utf8))
            case CursorUsageClient.usageURL:
                return .init(statusCode: 200, headers: [:], body: Data(#"{"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,"planUsage":{"limit":2000,"remaining":1500,"totalPercentUsed":25}}"#.utf8))
            case CursorUsageClient.planURL:
                return .init(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            default: return .init(statusCode: 404, headers: [:], body: Data("{}".utf8))
            }
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let oldRefresh = Task { await container.dataStore.refresh(providerID: account.cardID, force: true) }
        for _ in 0..<200 where !vault.waiting.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(vault.waiting.value)
        let candidate = AccountCredential.oauth(.init(accessToken: "candidate", refreshToken: "candidate-r", expiresAt: .distantFuture))
        let replacement = Task { try await container.replaceCredential(candidate, for: account.cardID) }
        for _ in 0..<200 where try vault.load(account.id) != candidate { try await Task.sleep(for: .milliseconds(5)) }
        vault.release.signal()
        try await replacement.value
        _ = await oldRefresh.value
        XCTAssertTrue(try vault.load(account.id) == candidate, "Cursor's old detached Keychain update finished after the new sign-in and overwrote it.")
    }
}


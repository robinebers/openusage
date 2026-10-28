import XCTest
@testable import OpenUsage

/// The resets popover's claim seam: which accounts get one, which outcomes refresh the account, and how
/// the post-claim refresh waits out an in-flight refresh or a transient failure.
@MainActor
final class ResetClaimServiceTests: XCTestCase {
    @MainActor
    private final class Recorder {
        var refreshes = 0
        var pauses: [Duration] = []
    }

    private func makeService(
        outcome: ResetClaimOutcome,
        refreshOutcomes: [WidgetDataStore.RefreshOutcome] = [.refreshed],
        recorder: Recorder
    ) -> ResetClaimService {
        ResetClaimService(
            accountID: "codex@test",
            isClaimable: true,
            confirmDetail: nil,
            claimReset: { _, _ in outcome },
            refreshAccount: {
                defer { recorder.refreshes += 1 }
                return refreshOutcomes[min(recorder.refreshes, refreshOutcomes.count - 1)]
            },
            pause: { recorder.pauses.append($0) }
        )
    }

    func testClaimRefreshesTheAccountUnlessItFailed() async {
        let outcomes: [ResetClaimOutcome] = [
            .success, .nothingToReset, .noCredit, .unconfirmed, .unavailableNow(until: nil), .failed(.connection)
        ]
        for outcome in outcomes {
            let recorder = Recorder()
            let service = makeService(outcome: outcome, recorder: recorder)

            let result = await service.claim(creditExpiringAt: Date(), redeemRequestID: "redeem-1")

            XCTAssertEqual(result, outcome)
            XCTAssertEqual(recorder.refreshes, outcome == .failed(.connection) ? 0 : 1, "\(outcome)")
        }
    }

    func testPostClaimRefreshWaitsOutAnInFlightRefresh() async {
        let recorder = Recorder()
        let service = makeService(outcome: .success, refreshOutcomes: [.skipped, .skipped, .refreshed], recorder: recorder)

        _ = await service.claim(creditExpiringAt: Date(), redeemRequestID: "redeem-1")

        XCTAssertEqual(recorder.refreshes, 3)
        XCTAssertEqual(recorder.pauses, [.seconds(1), .seconds(1)])
    }

    func testPostClaimRefreshRetriesAFailedRefreshThenGivesUp() async {
        let recorder = Recorder()
        let service = makeService(outcome: .success, refreshOutcomes: [.failed], recorder: recorder)

        _ = await service.claim(creditExpiringAt: Date(), redeemRequestID: "redeem-1")

        XCTAssertEqual(recorder.refreshes, 3)
        XCTAssertEqual(recorder.pauses, [.seconds(2), .seconds(2)])
    }

    func testOnlyClaudeAndCodexAccountsGetAClaimService() {
        for kind in ProviderKind.allCases {
            let runtime = AccountProviderRuntime(account: Account(kind: kind, label: "Work"), vault: InMemoryCredentialVault())
            let service = runtime.resetClaimService { .refreshed }
            switch kind {
            case .claude:
                XCTAssertEqual(service?.accountID, runtime.account.cardID)
                XCTAssertEqual(service?.isClaimable, false, "nothing to claim before the first reset-grants check")
            case .codex:
                XCTAssertEqual(service?.accountID, runtime.account.cardID)
                XCTAssertEqual(service?.isClaimable, true)
            case .cursor, .antigravity, .copilot, .grok, .ollama, .opencodeGo, .openrouter, .zai:
                XCTAssertNil(service, kind.rawValue)
            }
        }
    }

    func testContainerServesTheCardsClaimAndForcesItsRefreshPastTheBackoff() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        // An API-key credential fails a Codex refresh before any request, so nothing reaches the network.
        let codex = accounts.add(kind: .codex, label: "Work", credential: .apiKey("key"))
        var backedOff = false
        for _ in 0..<200 where !backedOff {
            backedOff = await container.dataStore.refresh(providerID: codex.cardID) == .backedOff
            if !backedOff { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertTrue(backedOff, "the account's failed refresh puts it in the failure backoff")
        XCTAssertNil(container.resetClaim(for: "codex@missing"))

        let service = try XCTUnwrap(container.resetClaim(for: codex.cardID))
        XCTAssertEqual(service.accountID, codex.cardID)
        let refresh = await service.refreshAccount()
        XCTAssertEqual(refresh, .failed, "the post-claim refresh runs despite the backoff")
    }

    func testErrorsMapToTheAdviceTheMessageGives() {
        XCTAssertEqual(ResetClaimFailure(ProviderError.signInExpired(.claude)), .signInExpired)
        XCTAssertEqual(ResetClaimFailure(ProviderError.signInExpired(.codex)), .signInExpired)
        XCTAssertEqual(ResetClaimFailure(LoginError.cancelled), .signInExpired)
        XCTAssertEqual(ResetClaimFailure(URLError(.timedOut)), .connection)
        XCTAssertEqual(ResetClaimFailure(ProviderError.connectionFailed), .connection)
        XCTAssertEqual(ResetClaimFailure(ProviderError.connectionFailed), .connection)
        XCTAssertEqual(ResetClaimFailure(ProviderError.requestFailed(500)), .refused)
    }

    func testEveryOutcomeGetsAPlainMessage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let messages: [(ResetClaimOutcome, String)] = [
            (.success, "Reset claimed. Enjoy!"),
            (.nothingToReset, "Your usage doesn't need a reset yet"),
            (.noCredit, "That reset is no longer available"),
            (.unconfirmed, "Your reset may still be going through. Check again in a minute."),
            (.unavailableNow(until: nil), "Resets can't be used right now."),
            (.unavailableNow(until: now.addingTimeInterval(90 * 60)), "Resets can't be used right now. Try again in 1h 30m."),
            (.failed(.signInExpired), "Your sign-in expired. Add the account again."),
            (.failed(.notPermitted), "This sign-in can't use resets. Use the reset in Claude Code instead."),
            (.failed(.connection), "Couldn't connect. Check your internet connection and try again."),
            (.failed(.refused), "Couldn't reset usage. Please try again.")
        ]
        for (outcome, text) in messages {
            XCTAssertEqual(outcome.message(now: now), text, "\(outcome)")
        }
    }

    func testCodexClaimRefreshesTheDashboardPastItsCache() async throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let claimed = TestSwitch(false)
        let http = RoutingHTTPClient { request in
            let available = claimed.value ? 0 : 1
            switch request.url {
            case CodexUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"rate_limit_reset_credits":{"available_count":\#(available)}}"#.utf8))
            case CodexUsageClient.resetCreditsURL:
                let credit = #"{"id":"RateLimitResetCredit_1","status":"available","expires_at":"\#(OpenUsageISO8601.string(from: expiry))"}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"available_count":\#(available),"credits":[\#(available == 1 ? credit : "")]}"#.utf8))
            case CodexUsageClient.consumeResetCreditURL:
                claimed.value = true
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let account = Account(kind: .codex, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token")), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        let descriptor = try XCTUnwrap(runtime.widgetDescriptors.first { $0.sample.showsResetExpiries })
        await store.refreshAll()
        XCTAssertEqual(store.data(for: descriptor).unboundedDetail, "1 available")
        XCTAssertEqual(store.data(for: descriptor).expiriesAt, [expiry])

        let service = try XCTUnwrap(runtime.resetClaimService {
            await store.refresh(providerID: runtime.provider.id, force: true)
        })
        let outcome = await service.claim(creditExpiringAt: expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(store.data(for: descriptor).unboundedDetail, "0 available")
        XCTAssertEqual(store.data(for: descriptor).expiriesAt, [])
    }
}

import Foundation
import SwiftUI

/// The outcome of a reset-credit claim, as the resets popover renders it — the consume endpoint's four
/// `code` values collapsed to what the user needs to know (`reset` and `already_redeemed` are both
/// "claimed": the latter is the idempotency key doing its job on a retry), plus a transport/HTTP
/// `.failed`.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case failed
}

/// Claims a Codex rate-limit reset credit — the app's only provider-API write, so it is deliberately
/// narrow: one credit per call, always by explicit credit id, guarded by the caller's idempotency key.
/// The protocol was reverse-engineered from the open-source Codex CLI and verified live once; see
/// docs/research/codex-reset-credit-claim.md.
///
/// The claim re-fetches the credit list at claim time and matches the target credit by its expiry
/// instant (the identity the popover timeline carries), rather than trusting a cached id: the list is a
/// safe GET, the id is guaranteed fresh, and a credit that raced away (claimed from the CLI or web in
/// the meantime) simply fails to match → `.noCredit`, exactly the truth. A successful claim awaits a
/// forced Codex refresh before returning, so by the time the popover shows its result banner the
/// Session/Weekly meters and the credit count already tell the post-reset story.
@MainActor
final class CodexResetClaimService {
    typealias Credentials = (accessToken: String, accountID: String?)

    private let usageClient: CodexUsageClient
    private let credentialCandidates: () async -> [Credentials]
    private let refreshAfterClaim: () async -> Void
    /// The credit id each idempotency key was matched to, kept for the key's retries: if a consume
    /// succeeded but its response was lost, the credit is gone from a re-fetched list — a fresh match
    /// would misread the retry as "no longer available" instead of replaying the POST and letting the
    /// server answer `already_redeemed`. Session-lived, keyed by the popover's per-credit UUIDs.
    private var matchedCreditIDs: [String: String] = [:]

    /// Test seam: injected credential candidates and refresh hook, the same `usageClient` the requests
    /// go through. Candidates are tried in order until one authenticates (see `claim`).
    init(
        usageClient: CodexUsageClient,
        credentialCandidates: @escaping () async -> [Credentials],
        refreshAfterClaim: @escaping () async -> Void = {}
    ) {
        self.usageClient = usageClient
        self.credentialCandidates = credentialCandidates
        self.refreshAfterClaim = refreshAfterClaim
    }

    /// Production wiring: shares the Codex provider's auth store and usage client, so credential
    /// selection can't drift from `refresh()` — every usable candidate in the provider's order (files
    /// first, then keychain), and `claim` falls back across them on an auth rejection the same way the
    /// provider's probe does. No token refresh here: the claim runs seconds after a successful usage
    /// fetch (which rotates tokens back to disk), so a candidate that still fails auth is genuinely
    /// dead and the next one is the right move. The auth store is resolved per claim (not captured
    /// once) so a claim always runs against the ACCOUNT the card currently shows — the resets the
    /// user is looking at.
    convenience init(
        authStore: @escaping @MainActor () -> CodexAuthStore,
        usageClient: CodexUsageClient,
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.init(
            usageClient: usageClient,
            credentialCandidates: {
                let authStore = await authStore()
                var candidates = authStore.loadAuthCandidates()
                if let keychain = await loadOffMainActor({ authStore.loadKeychainAuth() }) {
                    candidates.append(keychain)
                }
                return candidates.compactMap { candidate in
                    guard candidate.hasUsableAccessToken, let token = candidate.auth.tokens?.accessToken else {
                        return nil
                    }
                    return (token, candidate.auth.tokens?.accountID)
                }
            },
            refreshAfterClaim: refreshAfterClaim
        )
    }

    /// Claims the credit expiring at `expiry`. Never throws — every failure mode is logged loudly and
    /// collapsed to an outcome the popover can render.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let candidates = await credentialCandidates()
        guard !candidates.isEmpty else {
            AppLog.error(LogTag.plugin("codex"), "reset claim: no usable Codex credentials")
            return .failed
        }

        // A retry of an idempotency key that already matched replays the exact same (key, credit) pair
        // instead of re-matching: after a consume whose response was lost, the credit is no longer in
        // the list, and only the replay lets the server's `already_redeemed` prove the claim landed.
        let creditID: String
        var preferredCandidates = candidates
        if let replayID = matchedCreditIDs[redeemRequestID] {
            creditID = replayID
        } else {
            switch await matchCredit(expiringAt: expiry, candidates: candidates) {
            case .matched(let id, let authenticated):
                creditID = id
                matchedCreditIDs[redeemRequestID] = id
                // Lead with the credential that just authenticated the list fetch. Deduplicate by the
                // full (token, account) pair — ChatGPT-Account-Id changes what a token is authorized
                // for, so a same-token candidate with a different account is a distinct fallback.
                preferredCandidates = [authenticated] + candidates.filter {
                    $0.accessToken != authenticated.accessToken || $0.accountID != authenticated.accountID
                }
            case .noCredit:
                // Not an error: the credit was claimed elsewhere (CLI/web) or expired since the popover
                // rendered. The refresh reconciles the timeline with reality.
                AppLog.warn(LogTag.plugin("codex"), "reset claim: no available credit matches the picked expiry")
                await refreshAfterClaim()
                return .noCredit
            case .failed:
                return .failed
            }
        }

        let outcome = await consume(
            creditID: creditID, redeemRequestID: redeemRequestID, candidates: preferredCandidates
        )
        if outcome != .failed {
            // The world changed (or turned out different from the snapshot): refresh before returning,
            // so the result banner appears over already-reconciled meters and credit count.
            await refreshAfterClaim()
        }
        return outcome
    }

    /// POSTs the consume, falling back across credential candidates on an auth rejection (401/403).
    /// Safe to repeat: every attempt carries the same idempotency key, so at most one credit is ever
    /// spent no matter how many candidates are tried.
    private func consume(
        creditID: String, redeemRequestID: String, candidates: [Credentials]
    ) async -> ResetClaimOutcome {
        var lastRejection: Int?
        for credentials in candidates {
            let response: HTTPResponse
            do {
                response = try await usageClient.consumeResetCredit(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    creditID: creditID,
                    redeemRequestID: redeemRequestID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: consume request failed: \(error.localizedDescription)")
                return .failed
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                lastRejection = response.statusCode
                continue
            }
            let outcome = Self.outcome(fromConsume: response)
            if outcome == .failed {
                AppLog.error(
                    LogTag.plugin("codex"),
                    "reset claim: consume failed (\(response.statusCode)): "
                        + LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 300)
                )
            }
            return outcome
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: consume rejected for every credential (last: \(lastRejection.map(String.init) ?? "none"))")
        return .failed
    }

    private enum MatchResult {
        case matched(creditID: String, credentials: Credentials)
        case noCredit
        case failed
    }

    /// Fresh credit list (safe GET) → the id of the credit the user picked, matched by expiry. Tries
    /// each credential candidate in order, moving on when one is rejected as unauthenticated (401/403)
    /// — the same fallback the provider's probe applies — so a stale first auth file can't strand the
    /// claim while the dashboard works off a later one.
    private func matchCredit(expiringAt expiry: Date, candidates: [Credentials]) async -> MatchResult {
        var lastFailure = "no credential candidate authenticated"
        for credentials in candidates {
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: credentials.accessToken, accountID: credentials.accountID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed: \(error.localizedDescription)")
                return .failed
            }
            if list.statusCode == 401 || list.statusCode == 403 {
                lastFailure = "credit list fetch rejected (\(list.statusCode))"
                continue
            }
            guard (200..<300).contains(list.statusCode), let body = ProviderParse.jsonObject(list.body) else {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed (\(list.statusCode))")
                return .failed
            }
            guard let matched = Self.creditID(in: body, expiringAt: expiry) else { return .noCredit }
            return .matched(creditID: matched, credentials: credentials)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: \(lastFailure)")
        return .failed
    }

    /// The id of the still-available credit whose `expires_at` matches `expiry` (±1s — the popover's
    /// dates round-trip through the same ISO-8601 parsing as this list, so a real match is exact; the
    /// tolerance only absorbs sub-second truncation). Mirrors the mapper's status filter: a credit with
    /// no `status` counts as available, only an explicit non-"available" state is skipped.
    static func creditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        guard let credits = body["credits"] as? [[String: Any]] else { return nil }
        return credits.first { credit in
            if let status = credit["status"] as? String, status != "available" { return false }
            guard let date = parseExpiry(credit["expires_at"]) else { return false }
            return abs(date.timeIntervalSince(expiry)) < 1
        }?["id"] as? String
    }

    /// Collapses a consume response to the popover's outcome. All four protocol codes arrive as HTTP
    /// 200 — the outcome is in the body — so a non-2xx or an unrecognized code is `.failed`.
    static func outcome(fromConsume response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let code = body["code"] as? String
        else {
            return .failed
        }
        switch code {
        case "reset", "already_redeemed":
            return .success
        case "nothing_to_reset":
            return .nothingToReset
        case "no_credit":
            return .noCredit
        default:
            return .failed
        }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// Hands the claim service to the resets popover through the environment: `nil` (the default — previews,
/// share-card renders, reorder previews) renders the timeline read-only with no "Use" affordance.
private struct CodexResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: CodexResetClaimService? = nil
}

extension EnvironmentValues {
    var codexResetClaim: CodexResetClaimService? {
        get { self[CodexResetClaimServiceKey.self] }
        set { self[CodexResetClaimServiceKey.self] = newValue }
    }
}

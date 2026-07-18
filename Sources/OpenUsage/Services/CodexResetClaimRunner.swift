import Foundation

/// The claim result the CLI prints: `data` is the compact JSON document for stdout, `status` drives
/// the exit code, and `warnings` are non-fatal post-claim refresh problems for stderr.
public struct CodexResetClaimResult: Sendable {
    public enum Status: String, Sendable {
        case claimed
        case nothingToReset = "nothing_to_reset"
        case noCredit = "no_credit"
        case failed
    }

    public let status: Status
    public let data: Data
    public let warnings: [String]
}

/// The CLI's path into the Codex reset-credit claim (`openusage codex --claim-reset`) — the same
/// `CodexResetClaimService` the app's resets popover uses, so credential fallback, credit matching,
/// and the idempotency guard can't drift from the app's. Only the pick differs: the popover claims
/// the credit the user clicked; the CLI claims whatever claimable credit is next to expire. The
/// service's refresh hook forces a Codex read through `UsageReader`, so the shared snapshot cache
/// (the app and subsequent CLI reads) reconciles before the process exits.
@MainActor
public final class CodexResetClaimRunner {
    /// Collects failures raised inside the service's post-claim refresh hook — non-fatal for the
    /// claim itself, surfaced as CLI warnings.
    @MainActor
    final class WarningSink {
        var messages: [String] = []
    }

    private let service: CodexResetClaimService
    private let warnings: WarningSink
    private let makeRedeemRequestID: () -> String

    public convenience init(userDefaults: UserDefaults) {
        let warnings = WarningSink()
        let provider = CodexProvider()
        self.init(
            service: CodexResetClaimService(
                authStore: provider.authStore,
                usageClient: provider.usageClient,
                refreshAfterClaim: { @MainActor in
                    do {
                        let read = try await UsageReader(userDefaults: userDefaults)
                            .read(providerID: "codex", force: true)
                        warnings.messages.append(contentsOf: read.warnings)
                    } catch {
                        warnings.messages.append("post-claim refresh failed: \(error.localizedDescription)")
                    }
                }
            ),
            warnings: warnings
        )
    }

    /// Test seam: an injected service (whose refresh hook may feed `warnings`) and a deterministic
    /// idempotency-key generator so the printed JSON is assertable.
    init(
        service: CodexResetClaimService,
        warnings: WarningSink = WarningSink(),
        makeRedeemRequestID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.service = service
        self.warnings = warnings
        self.makeRedeemRequestID = makeRedeemRequestID
    }

    public func claimNextAvailableCredit() async -> CodexResetClaimResult {
        let redeemRequestID = makeRedeemRequestID()
        let claim = await service.claimNextAvailableCredit(redeemRequestID: redeemRequestID)
        let status: CodexResetClaimResult.Status
        switch claim.outcome {
        case .success: status = .claimed
        case .nothingToReset: status = .nothingToReset
        case .noCredit: status = .noCredit
        case .failed: status = .failed
        }
        return CodexResetClaimResult(
            status: status,
            data: Self.encode(
                status: status, creditExpiresAt: claim.creditExpiresAt, redeemRequestID: redeemRequestID
            ),
            warnings: warnings.messages
        )
    }

    /// The printed claim document — compact with sorted keys, like the limits JSON. `creditExpiresAt`
    /// appears only when a credit was actually targeted (on `nothing_to_reset` the targeted credit is
    /// kept, so "targeted" is deliberately not "spent").
    private struct WireClaim: Encodable {
        let schema = "openusage.claim.v1"
        let provider = "codex"
        let status: String
        let creditExpiresAt: String?
        let redeemRequestID: String
    }

    static func encode(status: CodexResetClaimResult.Status, creditExpiresAt: Date?, redeemRequestID: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = WireClaim(
            status: status.rawValue,
            creditExpiresAt: creditExpiresAt.map(OpenUsageISO8601.string(from:)),
            redeemRequestID: redeemRequestID
        )
        if let data = try? encoder.encode(wire) { return data }
        // Mirrors LocalLimitsAPI's envelope fallback: a hand-rolled minimal document rather than a crash.
        return Data(#"{"provider":"codex","schema":"openusage.claim.v1","status":"failed"}"#.utf8)
    }
}

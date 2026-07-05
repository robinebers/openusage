import Foundation

/// The slice of Grok's credits config OpenUsage renders: the shared-pool usage percent and the
/// period it applies to. Decoded from the gRPC-web `GetGrokCreditsConfig` response.
struct GrokCreditsConfig: Equatable, Sendable {
    /// `USAGE_PERIOD_TYPE_*` enum raw value; see `GrokCreditsConfigDecoder.weeklyPeriodType`.
    var periodType: UInt64
    /// Pool usage in 0...100 (validated finite; clamping to range happens at the mapper).
    var usedPercent: Double
    var periodStart: Date
    var periodEnd: Date

    var periodDurationMs: Int {
        Int((periodEnd.timeIntervalSince(periodStart) * 1000).rounded())
    }
}

/// Field numbers observed live on `grok.com`'s `GetGrokCreditsConfig` (verified 2026-07-05, matching
/// the Grok CLI's own log output byte-for-byte):
///
///     1 config {
///       1  float creditUsagePercent
///       8  currentPeriod { 1 periodType enum, 2 start Timestamp, 3 end Timestamp }
///       11 bool isUnifiedBillingUser
///     }
///     Timestamp { 1 seconds, 2 nanos }
///
/// The schema drifts fast (a new field appeared within two days of the first capture), so everything
/// not listed above is skipped by the wire reader and must stay that way.
enum GrokCreditsConfigDecoder {
    /// `USAGE_PERIOD_TYPE_WEEKLY` — the shared weekly pool Grok migrated unified-billing users to.
    static let weeklyPeriodType: UInt64 = 2

    /// Decode the unary gRPC-web response body. A non-zero grpc-status, a missing config, or a
    /// value that fails validation (non-finite percent, malformed timestamps, a period that doesn't
    /// move forward) is `invalidResponse` — the server answered, but not in the shape we know.
    static func decode(responseBody: Data) throws -> GrokCreditsConfig {
        let response = try GRPCWebCodec.parseUnary(responseBody)
        guard response.status == 0, let body = response.message else {
            AppLog.warn(LogTag.plugin("grok"), "credits config returned grpc-status \(response.status) \(response.statusMessage ?? "")")
            throw GrokUsageError.invalidResponse
        }

        guard let config = try ProtobufMessage(body).message(1),
              let percent = config.float(1).map(Double.init), percent.isFinite,
              let period = try config.message(8),
              let periodType = period.varint(1),
              let start = try timestamp(period.message(2)),
              let end = try timestamp(period.message(3)),
              end > start
        else {
            throw GrokUsageError.invalidResponse
        }

        return GrokCreditsConfig(periodType: periodType, usedPercent: percent, periodStart: start, periodEnd: end)
    }

    /// `google.protobuf.Timestamp`: field 1 seconds, field 2 nanos (must be a valid sub-second part).
    private static func timestamp(_ message: ProtobufMessage?) -> Date? {
        guard let message, let seconds = message.varint(1) else { return nil }
        let nanos = message.varint(2) ?? 0
        guard seconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
}

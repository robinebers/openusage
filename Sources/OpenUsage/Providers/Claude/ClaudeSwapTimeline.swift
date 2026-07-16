import Foundation

/// The account-activity timeline of a claude-swap (cswap) machine, reconstructed from the tool's own
/// log (`claude-swap.log` lines like `2026-07-16 11:50:55,324 - INFO - Switched from account 1 to 2`).
///
/// On a swap machine every account writes into the SAME `~/.claude/projects` logs, so per-account
/// spend attribution is only possible by time: an entry belongs to whichever slot was active when it
/// was written. The first switch event's `from` slot extends backward (it names the account that was
/// active before logging began); time before any knowledge stays `nil` (attributed to the default
/// card, matching the pre-timeline behavior). Attribution is an estimate: a session already running
/// when a switch lands keeps billing the old account for up to a keychain-cache interval (~minutes) —
/// the same order of error the spend tiles already carry as token-price estimates.
struct ClaudeSwapTimeline: Sendable, Equatable {
    struct Period: Sendable, Equatable {
        /// Period start; `.distantPast` for the backfilled first period.
        var start: Date
        /// The identity key (see `ProviderInstanceID`) of the slot active from `start` on.
        var identityKey: String
    }

    /// Sorted ascending by `start`.
    var periods: [Period]

    /// The identity active at `date`, or `nil` when the timeline has no knowledge of that time.
    func identityKey(at date: Date) -> String? {
        var active: String?
        for period in periods {
            if period.start <= date { active = period.identityKey } else { break }
        }
        return active
    }

    /// Parse the cswap log. `slotIdentities` maps slot numbers ("1") to identity keys — slots without
    /// a known identity are recorded as gaps (their periods attribute to nobody → default card).
    /// Returns `nil` when no switch events parse (no timeline = keep today's behavior).
    static func parse(logText: String, slotIdentities: [String: String], now: Date = Date()) -> ClaudeSwapTimeline? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // cswap logs wall-clock local time with no zone; the log was written on this machine, so the
        // current zone is the best available reading (a DST boundary blurs one hour once a year —
        // within the estimate's error bar).
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var events: [(date: Date, from: String, to: String)] = []
        for line in logText.split(separator: "\n").suffix(5000) {
            guard let range = line.range(of: " - INFO - Switched from account ") else { continue }
            let timestampPart = line[..<range.lowerBound].prefix(19)
            guard let date = formatter.date(from: String(timestampPart)) else { continue }
            let tail = line[range.upperBound...]
            let parts = tail.split(separator: " ")
            // "… from account <N> to <M>"
            guard parts.count >= 3, parts[1] == "to" else { continue }
            events.append((date, String(parts[0]), String(parts[2])))
        }
        guard !events.isEmpty else { return nil }
        events.sort { $0.date < $1.date }

        var periods: [Period] = []
        // Backfill: the first event's `from` slot was active for all earlier time we know of.
        if let first = events.first, let identity = slotIdentities[first.from] {
            periods.append(Period(start: .distantPast, identityKey: identity))
        }
        for event in events {
            guard let identity = slotIdentities[event.to] else {
                // Unknown slot: close the previous period by starting an unattributable gap.
                periods.append(Period(start: event.date, identityKey: ""))
                continue
            }
            periods.append(Period(start: event.date, identityKey: identity))
        }
        // Normalize gaps: empty identity keys mean "unknown" — drop them into real gaps by filtering
        // at lookup time instead of storing sentinel matches.
        let normalized = ClaudeSwapTimeline(periods: periods)
        return normalized
    }
}

extension ClaudeSwapTimeline {
    /// The scanner filter for one account's card: entries during MY periods. `includeUnknown` adds
    /// time the timeline knows nothing about (the default card takes those, so no spend is dropped).
    func entryFilter(identityKey: String, includeUnknown: Bool) -> @Sendable (Date) -> Bool {
        let timeline = self
        return { date in
            guard let active = timeline.identityKey(at: date), !active.isEmpty else { return includeUnknown }
            return active == identityKey
        }
    }
}

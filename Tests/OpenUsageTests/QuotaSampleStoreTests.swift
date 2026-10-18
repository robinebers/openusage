import XCTest
@testable import OpenUsage

final class QuotaSampleStoreTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testAppendReloadIdentityIsolationAndLimitWipe() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-quota-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = QuotaSampleStore(fileURL: url)
        let sample = QuotaSample(
            recordedAt: date(2026, 8, 3, 15),
            used: 40, limit: 100,
            resetsAt: date(2026, 8, 10),
            periodDuration: 7 * 24 * 3600
        )
        store.record(identityKey: "acct-a", metricID: "claude.weekly", sample: sample)
        store.record(identityKey: "acct-b", metricID: "claude.weekly", sample: QuotaSample(
            recordedAt: date(2026, 8, 3, 16),
            used: 90, limit: 100,
            resetsAt: date(2026, 8, 10),
            periodDuration: 7 * 24 * 3600
        ))
        store.flush()

        XCTAssertEqual(store.samples(identityKey: "acct-a", metricID: "claude.weekly").map(\.used), [40])
        XCTAssertEqual(store.samples(identityKey: "acct-b", metricID: "claude.weekly").map(\.used), [90])

        let reloaded = QuotaSampleStore(fileURL: url)
        XCTAssertEqual(reloaded.samples(identityKey: "acct-a", metricID: "claude.weekly").map(\.used), [40])

        store.record(identityKey: "acct-a", metricID: "claude.weekly", sample: QuotaSample(
            recordedAt: date(2026, 8, 3, 17),
            used: 10, limit: 130, // 30% jump
            resetsAt: date(2026, 8, 10),
            periodDuration: 7 * 24 * 3600
        ))
        store.flush()
        XCTAssertEqual(store.samples(identityKey: "acct-a", metricID: "claude.weekly").map(\.used), [10])
        XCTAssertEqual(store.samples(identityKey: "acct-b", metricID: "claude.weekly").map(\.used), [90])
    }

    func testWeeklySameSlotRemaindersMatchHandCheckableFixture() {
        let week: TimeInterval = 7 * 24 * 3600
        // Three completed ISO-style weeks. Monday 15:00 used 50/40/60, week-end used 70/70/100
        // → remainders 20/30/40, median 30.
        var samples: [QuotaSample] = []
        let weeks: [(start: Date, slotUsed: Double, endUsed: Double, reset: Date)] = [
            (date(2026, 7, 13), 50, 70, date(2026, 7, 20)),
            (date(2026, 7, 20), 40, 70, date(2026, 7, 27)),
            (date(2026, 7, 27), 60, 100, date(2026, 8, 3)),
        ]
        for weekWindow in weeks {
            samples.append(QuotaSample(
                recordedAt: weekWindow.start.addingTimeInterval(15 * 3600),
                used: weekWindow.slotUsed, limit: 100,
                resetsAt: weekWindow.reset, periodDuration: week
            ))
            samples.append(QuotaSample(
                recordedAt: weekWindow.reset.addingTimeInterval(-3600),
                used: weekWindow.endUsed, limit: 100,
                resetsAt: weekWindow.reset, periodDuration: week
            ))
        }
        let now = date(2026, 8, 3, 15)
        let remainders = QuotaSampleStore.remainders(
            from: samples, now: now,
            currentResetsAt: date(2026, 8, 10),
            currentPeriod: week,
            calendar: calendar
        )
        XCTAssertEqual(remainders, [20, 30, 40])
        // Adaptive power blend: seasonal = 40, linear = 112, weight = (15/168)^0.75 ≈ 0.16335 → ~51.76
        XCTAssertEqual(Pace.projectUsage(used: 10, elapsed: 15 * 3600, periodDuration: week,
                                         remainders: remainders), 51.76, accuracy: 0.05)
    }

    func testResetJitterStillYieldsSameSlotRemainders() {
        // Provider reset timestamps wander by milliseconds (see resetWindowJitterTolerance).
        // Slot and end samples in one week must stay one cycle, not six remainder-0 fragments.
        let week: TimeInterval = 7 * 24 * 3600
        let jitter: TimeInterval = 0.09
        var samples: [QuotaSample] = []
        let weeks: [(start: Date, slotUsed: Double, endUsed: Double, reset: Date)] = [
            (date(2026, 7, 13), 50, 70, date(2026, 7, 20)),
            (date(2026, 7, 20), 40, 70, date(2026, 7, 27)),
            (date(2026, 7, 27), 60, 100, date(2026, 8, 3)),
        ]
        for (index, weekWindow) in weeks.enumerated() {
            samples.append(QuotaSample(
                recordedAt: weekWindow.start.addingTimeInterval(15 * 3600),
                used: weekWindow.slotUsed, limit: 100,
                resetsAt: weekWindow.reset.addingTimeInterval(jitter * Double(index % 2 == 0 ? 1 : -1)),
                periodDuration: week
            ))
            samples.append(QuotaSample(
                recordedAt: weekWindow.reset.addingTimeInterval(-3600),
                used: weekWindow.endUsed, limit: 100,
                resetsAt: weekWindow.reset.addingTimeInterval(jitter * Double(index % 2 == 0 ? -1 : 1)),
                periodDuration: week
            ))
        }
        let now = date(2026, 8, 3, 15)
        let remainders = QuotaSampleStore.remainders(
            from: samples, now: now,
            currentResetsAt: date(2026, 8, 10),
            currentPeriod: week,
            calendar: calendar
        )
        XCTAssertEqual(remainders, [20, 30, 40])
        // Mid-window 60% used (linear 120, seasonal 90, adaptive blend ~107.84)
        XCTAssertEqual(
            Pace.projectUsage(used: 60, elapsed: week * 0.5, periodDuration: week, remainders: remainders),
            107.84, accuracy: 0.05
        )
    }

    func testICloudHistoryDocumentDoesNotCarryQuotaSamples() throws {
        let doc = UsageHistoryDocument(
            deviceID: "dev-1",
            deviceName: "Test Mac",
            updatedAt: Date(),
            providers: [
                "claude": ProviderUsageHistory(series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-08-01", totalTokens: 1, costUSD: 0.01)
                ]))
            ]
        )
        let data = try JSONEncoder().encode(doc)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("quota"), json)
        XCTAssertFalse(json.contains("remainders"))
        XCTAssertEqual(QuotaSampleStore.folderName, "quota-samples")
        XCTAssertTrue(QuotaSampleStore.defaultDirectory.path.contains("Application Support"))
        XCTAssertFalse(QuotaSampleStore.defaultDirectory.path.contains("Mobile Documents"))
        XCTAssertFalse(QuotaSampleStore.defaultFileURL.path.contains("quota-samples") == false)
    }

    func testSameHourWeeklySamplesCoalesceAndUnchangedIsSkipped() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let reset = date(2026, 8, 10)
        let start = date(2026, 8, 3, 15)
        func sample(minutes: Int, used: Double) -> QuotaSample {
            QuotaSample(
                recordedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                used: used, limit: 100, resetsAt: reset, periodDuration: week
            )
        }
        store.record(identityKey: "a", metricID: "weekly", sample: sample(minutes: 0, used: 40))
        store.record(identityKey: "a", metricID: "weekly", sample: sample(minutes: 5, used: 40))
        store.record(identityKey: "a", metricID: "weekly", sample: sample(minutes: 10, used: 41))
        XCTAssertEqual(store.samples(identityKey: "a", metricID: "weekly").map(\.used), [41])
        store.record(identityKey: "a", metricID: "weekly", sample: sample(minutes: 70, used: 50))
        XCTAssertEqual(store.samples(identityKey: "a", metricID: "weekly").map(\.used), [41, 50])
    }

    func testDiskWriteHappensOnFlushNotEachRecord() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-quota-flush-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QuotaSampleStore(fileURL: url)
        store.record(identityKey: "a", metricID: "weekly", sample: QuotaSample(
            recordedAt: date(2026, 8, 3, 15), used: 40, limit: 100,
            resetsAt: date(2026, 8, 10), periodDuration: 7 * 24 * 3600
        ))
        XCTAssertTrue(store.samples(identityKey: "a", metricID: "weekly").map(\.used) == [40])
        XCTAssertEqual(QuotaSampleStore(fileURL: url).samples(identityKey: "a", metricID: "weekly").count, 0)
        store.flush()
        XCTAssertEqual(QuotaSampleStore(fileURL: url).samples(identityKey: "a", metricID: "weekly").map(\.used), [40])
    }

    func testWeeklyResetClosesCycleWithTokensAndPlan() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let daily = [
            DailyUsageEntry(date: "2026-08-03", totalTokens: 100, costUSD: 1),
            DailyUsageEntry(date: "2026-08-04", totalTokens: 50, costUSD: 0.5),
            DailyUsageEntry(date: "2026-08-10", totalTokens: 999, costUSD: 9), // next week, excluded
        ]
        store.record(
            identityKey: "acct-a", metricID: "claude.weekly",
            sample: QuotaSample(
                recordedAt: date(2026, 8, 9, 12), used: 41, limit: 100,
                resetsAt: date(2026, 8, 10), periodDuration: week
            ),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        store.record(
            identityKey: "acct-a", metricID: "claude.weekly",
            sample: QuotaSample(
                recordedAt: date(2026, 8, 10, 8), used: 3, limit: 100,
                resetsAt: date(2026, 8, 17), periodDuration: week
            ),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        let cycles = store.cycles(identityKey: "acct-a", metricID: "claude.weekly")
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].endUsed, 41)
        XCTAssertEqual(cycles[0].plan, "Max 20x")
        XCTAssertEqual(cycles[0].tokens, 150)
        XCTAssertEqual(cycles[0].costUSD ?? 0, 1.5, accuracy: 0.01)
        XCTAssertEqual(cycles[0].impliedCapTokens ?? 0, 150 / 0.41, accuracy: 1)
        // Session-scale windows do not roll up.
        store.record(
            identityKey: "acct-a", metricID: "claude.session",
            sample: QuotaSample(
                recordedAt: date(2026, 8, 10, 8), used: 90, limit: 100,
                resetsAt: date(2026, 8, 10, 13), periodDuration: 5 * 3600
            ),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        store.record(
            identityKey: "acct-a", metricID: "claude.session",
            sample: QuotaSample(
                recordedAt: date(2026, 8, 10, 14), used: 5, limit: 100,
                resetsAt: date(2026, 8, 10, 19), periodDuration: 5 * 3600
            ),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        XCTAssertTrue(store.cycles(identityKey: "acct-a", metricID: "claude.session").isEmpty)
        XCTAssertTrue(store.cycles(identityKey: "acct-b", metricID: "claude.weekly").isEmpty)
    }

    func testTwoSecondResetsAtJitterDoesNotCloseCycleOrSplitWindow() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let reset = date(2026, 8, 10)
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 12), used: 40, limit: 100,
                                resetsAt: reset, periodDuration: week),
            plan: "Max 20x", calendar: calendar
        )
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 12).addingTimeInterval(300),
                                used: 40, limit: 100,
                                resetsAt: reset.addingTimeInterval(1.96), periodDuration: week),
            plan: "Max 20x", calendar: calendar
        )
        XCTAssertTrue(store.cycles(identityKey: "a", metricID: "weekly").isEmpty)
        XCTAssertEqual(store.samples(identityKey: "a", metricID: "weekly").count, 1)
    }

    func testSameWindowUsageWipeClosesCycleAndDoesNotBlockLaterReset() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let reset = date(2026, 8, 10)
        let daily = [
            DailyUsageEntry(date: "2026-08-03", totalTokens: 200, costUSD: 2),
            DailyUsageEntry(date: "2026-08-04", totalTokens: 100, costUSD: 1),
        ]
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 5, 2), used: 31, limit: 100,
                                resetsAt: reset, periodDuration: week),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        // Anthropic new-model wipe: used collapses, resetsAt stays.
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 5, 3), used: 2, limit: 100,
                                resetsAt: reset.addingTimeInterval(1.4), periodDuration: week),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        var cycles = store.cycles(identityKey: "a", metricID: "weekly")
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].endUsed, 31)
        XCTAssertEqual(cycles[0].tokens, 300)

        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 18), used: 71, limit: 100,
                                resetsAt: reset, periodDuration: week),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 10, 8), used: 3, limit: 100,
                                resetsAt: date(2026, 8, 17), periodDuration: week),
            plan: "Max 20x", daily: daily, calendar: calendar
        )
        cycles = store.cycles(identityKey: "a", metricID: "weekly")
        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles.map(\.endUsed), [31, 71])
    }

    func testOnePointUsedDropIsNotAWipe() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let reset = date(2026, 8, 10)
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 12), used: 71, limit: 100,
                                resetsAt: reset, periodDuration: week),
            calendar: calendar
        )
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 13), used: 70, limit: 100,
                                resetsAt: reset, periodDuration: week),
            calendar: calendar
        )
        XCTAssertTrue(store.cycles(identityKey: "a", metricID: "weekly").isEmpty)
        XCTAssertEqual(store.samples(identityKey: "a", metricID: "weekly").map(\.used), [71, 70])
    }

    func testTwoMinuteResetDriftDoesNotCloseCycle() {
        let week: TimeInterval = 7 * 24 * 3600
        let store = QuotaSampleStore(fileURL: nil)
        let reset = date(2026, 8, 10)
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 12), used: 0, limit: 100,
                                resetsAt: reset, periodDuration: week),
            calendar: calendar
        )
        store.record(
            identityKey: "a", metricID: "weekly",
            sample: QuotaSample(recordedAt: date(2026, 8, 9, 12).addingTimeInterval(300),
                                used: 0, limit: 100,
                                resetsAt: reset.addingTimeInterval(120), periodDuration: week),
            calendar: calendar
        )
        XCTAssertTrue(store.cycles(identityKey: "a", metricID: "weekly").isEmpty)
    }
}

import XCTest
@testable import OpenUsage

extension WidgetDataStoreTests {
    func testResolvesProgressSnapshotIntoWidgetData() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(
                    label: "Session",
                    used: 42,
                    limit: 100,
                    format: .percent,
                    resetsAt: Date(timeIntervalSinceNow: 60 * 60),
                    periodDurationMs: 5 * 60 * 60 * 1000
                )]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        // Hermetic: pin the meter style via an isolated suite so a persisted `.used` in `.standard`
        // can't flip the expected "remaining" output.
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("resolve-progress"))

        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.displayedValue, 58)
        XCTAssertEqual(data.valueText, "58%")
        XCTAssertEqual(data.boundedHeadline, "58% left")
        XCTAssertEqual(data.boundedSubtitle?.hasPrefix("Resets in "), true)
    }

    func testCreditsRenderDollarAndCountCombinedInvariantToMeterStyle() async {
        // Codex flex credits show the dollar value and the raw count combined ("$40.00 · 1,000
        // credits"), invariant to the Used/Left meter style, while the dollar value drives the menu
        // bar's compact reading — all from one `.values` row, no string re-parse.
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.combined(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: CodexUsageMapper.creditValues(remaining: 1000))]
            )
        )
        let defaults = makeUserDefaults("codex-credits")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$40.00 · 1K credits")
        XCTAssertEqual(remaining.menuBarValue, "$40")   // dollar value → compact tray reading
        XCTAssertNil(remaining.unboundedSubtitle)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.headline, remaining.headline)
    }

    func testRateLimitResetsTileShowsCountInTrayAndPopover() async {
        // Regression (#641): the menu-bar tile and the popover row resolve from one raw number, so a
        // pinned tile can't read "0" while the popover reads "1". The popover keeps Codex's "available"
        // wording, while the tighter tray reads "resets".
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 1, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "1 available")
        XCTAssertEqual(data.menuBarValue, "1 resets")
    }

    func testZeroRateLimitResetsStillFlagsResetPopoverForEmptyState() async {
        // The descriptor opt-in must survive resolve even at "0 available" (no expiries): that's exactly
        // when the value column needs to stay a hover target so the popover can show the empty state.
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 0, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets-empty")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.showsResetExpiries)
        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.expiriesAt.isEmpty)
        XCTAssertNil(data.expirySeverity())          // no dot at zero
        XCTAssertEqual(data.unboundedDetail, "0 available")
    }

    func testBoundedDollarAndCountTrayValuesHonorMeterStyleWithoutPercentConversion() async {
        let provider = Provider(id: "example", displayName: "Example", icon: .providerMark("cursor"))
        let budget = WidgetDescriptor.boundedDollars(id: "example.budget", provider: provider, title: "Budget", limit: 100)
        let requests = WidgetDescriptor.boundedCount(
            id: "example.requests",
            provider: provider,
            title: "Requests",
            limit: 500,
            suffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [budget, requests],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .progress(label: "Budget", used: 12.48, limit: 20, format: .dollars),
                    .progress(label: "Requests", used: 412, limit: 500, format: .count(suffix: "requests"))
                ]
            )
        )
        let defaults = makeUserDefaults("cursor-tray-units")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [budget, requests]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$12")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "412")

        store.meterStyle = .remaining
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$8")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "88")
    }

    func testCursorCreditsRenderAsUnboundedBalance() async {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let descriptor = WidgetDescriptor.dollarBalance(
            id: "cursor.credits",
            provider: provider,
            title: "Credits",
            valueWord: "left"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: [MetricValue(number: 7_909.64, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("cursor-credits-balance")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$7.9K left")
        XCTAssertEqual(remaining.menuBarValue, "$7.9K")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.menuBarValue, remaining.menuBarValue)
    }

    func testUncappedExtraUsageRendersCompactAndUnbounded() async {
        // Regression (#658): Claude's `claude.extra` is a `boundedDollars` descriptor (a meter when the
        // provider reports a monthly cap), but an uncapped spend arrives as a `.values` line. It must
        // resolve to an unbounded tile — the sample's placeholder limit dropped — and read in the same
        // compact shorthand as the spend tiles ("$1.2K spent"), not full currency, in both row and tray.
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Extra usage spent",
                                values: [MetricValue(number: 1234.56, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("claude-extra")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)                          // sample's limit: 100 dropped for a .values row
        XCTAssertEqual(data.unboundedDetail, "$1.2K spent")     // popover row — compact, not "$1,234.56"
        XCTAssertEqual(data.menuBarValue, "$1.2K")              // tray — same shorthand
        XCTAssertEqual(data.unboundedTooltip, "$1,234.56")      // hover still reveals the exact figure
    }

    func testCcusageSpendSplitsIntoCostTokensAndCombined() async {
        // One `.values` spend row backs three tiles: cost-only (dollars + ⓘ), tokens-only (the
        // measured count, no ⓘ), and combined (both, ⓘ because a shown value is estimated).
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let cost = WidgetDescriptor.values(id: "test.last30", provider: provider, title: "Last 30 Days",
                                           selection: .kind(.dollars), valueWord: "spent")
        let tokens = WidgetDescriptor.values(id: "test.last30.tokens", provider: provider,
                                             title: "Tokens", metricLabel: "Last 30 Days", selection: .kind(.count))
        let combined = WidgetDescriptor.combined(id: "test.last30.combined", provider: provider,
                                                 title: "Combined", metricLabel: "Last 30 Days")
        let todayCost = WidgetDescriptor.values(id: "test.today", provider: provider, title: "Today",
                                                selection: .kind(.dollars), valueWord: "spent")
        let descriptors = [cost, tokens, combined, todayCost]
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 478.0, kind: .dollars, estimated: true),
                        MetricValue(number: 891_000, kind: .count, label: "tokens")
                    ]),
                    // An unpriced day: real tokens, no dollar (cost unknown, not zero).
                    .values(label: "Today", values: [MetricValue(number: 123_000, kind: .count, label: "tokens")])
                ]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("local-estimate"),
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache)
        await store.refreshAll()

        // Cost-only: the dollars, locally estimated.
        let costData = store.data(for: cost)
        XCTAssertEqual(costData.valueText, "$478.00")
        XCTAssertEqual(costData.unboundedDetail, "$478.00 spent")
        XCTAssertEqual(costData.infoNote, WidgetData.localEstimateNote)

        // Tokens-only: the measured count with its "tokens" unit; the tooltip has every digit.
        let tokenData = store.data(for: tokens)
        XCTAssertEqual(tokenData.unboundedDetail, "891K tokens")
        XCTAssertEqual(tokenData.menuBarValue, "891K tokens")
        XCTAssertEqual(tokenData.unboundedTooltip, "891,000 tokens")
        XCTAssertNil(tokenData.infoNote)

        // Combined: both values joined; the tray glances at the leading dollar value, the tooltip is full.
        let combinedData = store.data(for: combined)
        XCTAssertEqual(combinedData.unboundedDetail, "$478.00 · 891K tokens")
        XCTAssertEqual(combinedData.menuBarValue, "$478")
        XCTAssertEqual(combinedData.unboundedTooltip, "$478.00 · 891,000 tokens")
        XCTAssertEqual(combinedData.infoNote, WidgetData.localEstimateNote)

        // The value hover carries exact figures plus the source note.
        XCTAssertEqual(combinedData.unboundedValueTooltip, "$478.00 · 891,000 tokens\n\(WidgetData.localEstimateNote)")
        XCTAssertEqual(costData.unboundedValueTooltip, "$478.00\n\(WidgetData.localEstimateNote)")
        // The measured tokens tile has no source note, so it has only the exact-number value hover.
        XCTAssertNil(tokenData.infoNote)
        XCTAssertEqual(tokenData.unboundedValueTooltip, "891,000 tokens")

        // An unpriced day (real tokens, no dollar): the cost-only tile finds no dollar value, so it reads
        // "No data" rather than a fabricated $0.00.
        let todayData = store.data(for: todayCost)
        XCTAssertFalse(todayData.hasData)
        XCTAssertEqual(todayData.valueText, WidgetData.noDataHeadline)
    }

    func testCursorSpendValueTooltipUsesUsageHistorySourceNote() async {
        let cursor = CursorProvider()
        let provider = cursor.provider
        let combined = cursor.widgetDescriptors.first { $0.id == "cursor.last30" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [combined],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 15.80, kind: .dollars),
                        MetricValue(number: 8_100_000_000, kind: .count, label: "tokens")
                    ])
                ]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [combined]), providers: [runtime])
        await store.refreshAll()

        let data = store.data(for: combined)
        XCTAssertEqual(data.unboundedDetail, "$15.80 · 8.1B tokens")
        XCTAssertNil(data.infoNote)
        XCTAssertEqual(data.unboundedValueTooltip, "$15.80 · 8,100,000,000 tokens\n\(WidgetData.cursorUsageHistoryNote)")
    }

    /// `resolveText` builds the resolved row from the descriptor's sample but must reset the fields a
    /// fresh text row never inherits (here `preservesRawText`, `limitNoun`, `resetsAt`,
    /// `periodDurationMs`) to their `WidgetData` defaults — otherwise a verbatim-dollars sample would
    /// leak its raw-text flag and a stray limit noun into the resolved value.
    func testResolveTextResetsNonInheritedSampleFields() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var sample = WidgetData(title: "Extra Usage", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        sample.preservesRawText = true
        sample.limitNoun = "cap"
        sample.resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        sample.periodDurationMs = 123_456
        let descriptor = WidgetDescriptor(id: "codex.credits", providerID: provider.id,
                                          metricLabel: "Credits", sample: sample)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Credits", value: "$40.00 · 1,000 credits")]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("resolve-text-reset")
        )
        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 40.0)
        // preservesRawText still drives the verbatim override above, but the resolved row's own flag
        // resets to its default.
        XCTAssertFalse(data.preservesRawText)
        XCTAssertEqual(data.valueTextOverride, "$40.00 · 1,000 credits")
        XCTAssertNil(data.limitNoun)
        XCTAssertNil(data.resetsAt)
        XCTAssertNil(data.periodDurationMs)
    }

    /// A `.percent` text row defaults a missing sample limit to a 100 scale and never carries an
    /// `unboundedValueWord`, even when the sample (incorrectly) had one.
    func testResolveTextPercentDefaultsLimitAndDropsUnboundedWord() async {
        let provider = Provider(id: "p", displayName: "P", icon: .providerMark("p"))
        var sample = WidgetData(title: "Usage", icon: provider.icon, kind: .percent, used: 0, limit: nil)
        sample.unboundedValueWord = "left"
        let descriptor = WidgetDescriptor(id: "p.usage", providerID: provider.id,
                                          metricLabel: "Usage", sample: sample)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Usage", value: "42")]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("resolve-text-percent")
        )
        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.limit, 100)
        XCTAssertNil(data.unboundedValueWord)
    }
}

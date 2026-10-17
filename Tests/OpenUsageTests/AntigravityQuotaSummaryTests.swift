import XCTest
@testable import OpenUsage

/// Covers the `RetrieveUserQuotaSummary` support added by the merged-pools + weekly-limits fix:
/// the lenient summary parser and the "a parsed summary is authoritative — even empty — and never
/// falls through to the legacy per-model endpoints" control flow on both transports.
final class AntigravityQuotaSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private func resetsAt(_ line: MetricLine?) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = line else { return nil }
        return resetsAt
    }

    private func periodMs(_ line: MetricLine?) -> Int? {
        guard case .progress(_, _, _, _, _, let periodMs, _)? = line else { return nil }
        return periodMs
    }

    /// Four shared quota windows and a separate Argon weekly quota.
    private let fullGroupsJSON = """
    "groups":[
      {"displayName":"Gemini 4 Argon","buckets":[
        {"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":0.6,"resetTime":"2026-10-20T08:00:00Z"}
      ]},
      {"displayName":"Claude and other models","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-07-06T07:00:00Z"},
        {"bucketId":"3p-5h","displayName":"5-hour","window":"5h","remainingFraction":0.4,"resetTime":"2026-07-02T15:30:00Z"}
      ]},
      {"displayName":"Gemini models","buckets":[
        {"bucketId":"gemini-5h","displayName":"5-hour","window":"5h","remainingFraction":0.75,"resetTime":"2026-07-02T16:00:00Z"},
        {"bucketId":"gemini-weekly","displayName":"Weekly","window":"weekly","remainingFraction":0.9,"resetTime":"2026-07-06T07:00:00Z"}
      ]}
    ]
    """

    private let claudeOnlyGroupsJSON = """
    "groups":[{"displayName":"Claude and GPT models","buckets":[
      {"bucketId":"3p-5h","window":"5h","remainingFraction":0.4},
      {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1}
    ]}]
    """

    // MARK: - Parser

    func testWrappedAndBarePayloadsProduceIdenticalFiveLines() {
        let bare = AntigravityUsageMapper.parseQuotaSummary(Data("{\(fullGroupsJSON)}".utf8))
        let wrapped = AntigravityUsageMapper.parseQuotaSummary(Data("{\"response\":{\(fullGroupsJSON)}}".utf8))
        XCTAssertEqual(bare, wrapped)

        guard let lines = bare else { return XCTFail("full summary did not parse") }
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(lines.map { used($0) }, [25, 10, 40, 60, 0])
        XCTAssertEqual(resetsAt(lines[0]), OpenUsageISO8601.date(from: "2026-07-02T16:00:00Z"))
        XCTAssertEqual(resetsAt(lines[2]), OpenUsageISO8601.date(from: "2026-10-20T08:00:00Z"))
        XCTAssertEqual(resetsAt(lines[3]), OpenUsageISO8601.date(from: "2026-07-02T15:30:00Z"))
        XCTAssertEqual(lines.map { periodMs($0) }, [
            MetricPeriod.sessionMs, MetricPeriod.weekMs, MetricPeriod.weekMs, MetricPeriod.sessionMs, MetricPeriod.weekMs
        ])
    }

    func testBucketWithoutRemainingFractionDropsItsLineOnly() {
        // Never fabricate 0% or 100% from an absent fraction (a real-world third-party parser
        // regression came from defaulting to "full") — the bucket's line just drops.
        let json = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","resetTime":"2026-07-02T16:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-07-06T07:00:00Z"}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Weekly"])
        XCTAssertEqual(used(lines?.first), 50)
    }

    func testMalformedBucketDoesNotVoidTheEnvelope() {
        // One garbage element (not an object) and one wrong-typed fraction must not fail the whole
        // summary into the legacy fallback — the valid bucket survives.
        let json = """
        {"groups":[{"buckets":[
          "junk",
          {"bucketId":"3p-5h","remainingFraction":"lots"},
          {"bucketId":"gemini-5h","remainingFraction":0.25,"resetTime":"2026-07-02T16:00:00Z"}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Session"])
        XCTAssertEqual(used(lines?.first), 75)
    }

    func testMissingResetTimeYieldsNilResetsAt() {
        let json = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]}]}"#
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(used(lines?.first), 50)
        XCTAssertNil(resetsAt(lines?.first))
    }

    func testUnknownOrAbsentBucketIDIsSkippedNeverPooledByDisplayName() {
        // A future bucket (gemini-image-5h) and an id-less bucket must never join a pool via their
        // displayName — only the exact known bucketIds bind.
        let json = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-image-5h","displayName":"Session","window":"5h","remainingFraction":0.1},
          {"displayName":"Session","window":"5h","remainingFraction":0.2},
          {"bucketId":"gemini-5h","remainingFraction":0.75}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Session"])
        XCTAssertEqual(used(lines?.first), 25)
    }

    func testWeeklyOnlyAndSessionOnlyShapes() {
        // A summary may expose only one window. Both shapes remain valid summaries.
        let weeklyOnly = """
        {"response":{"groups":[{"buckets":[
          {"bucketId":"gemini-weekly","remainingFraction":0.8},
          {"bucketId":"3p-weekly","remainingFraction":0.6}
        ]}]}}
        """
        let weeklyLines = AntigravityUsageMapper.parseQuotaSummary(Data(weeklyOnly.utf8))
        XCTAssertEqual(weeklyLines?.map(\.label), ["Weekly", "Claude Weekly"])
        XCTAssertEqual(weeklyLines?.compactMap { periodMs($0) }, [MetricPeriod.weekMs, MetricPeriod.weekMs])

        let sessionOnly = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.8},
          {"bucketId":"3p-5h","remainingFraction":0.6}
        ]}]}
        """
        let sessionLines = AntigravityUsageMapper.parseQuotaSummary(Data(sessionOnly.utf8))
        XCTAssertEqual(sessionLines?.map(\.label), ["Session", "Claude"])
        XCTAssertEqual(sessionLines?.compactMap { periodMs($0) }, [MetricPeriod.sessionMs, MetricPeriod.sessionMs])
    }

    func testUndecodableOrGrouplessBodyIsNotASummary() {
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data("not json".utf8)))
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data("{}".utf8)))
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"response":{}}"#.utf8)))
    }

    func testEmptyGroupsParseAsAuthoritativeEmptySummary() {
        // Non-nil-but-empty means "the summary answered and there are no usable buckets" — the caller
        // must stop there, never fall into the legacy chain that fabricates 100%-used.
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"groups":[]}"#.utf8)), [])
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"response":{"groups":[]}}"#.utf8)), [])
    }

    // MARK: - Label binding (metricLabel == MetricLine.label, exact string)

    @MainActor
    func testDescriptorLabelsMatchMapperEmittedLabels() {
        let descriptorLabels = Set(
            AntigravityProvider().widgetDescriptors
                .filter { !$0.limitResources.isEmpty }
                .map(\.metricLabel)
        )
        XCTAssertEqual(
            Set(AntigravityUsageMapper.summaryBuckets.map(\.label)).union([AntigravityMetric.argonWeeklyLabel]),
            descriptorLabels
        )

        let summaryLines = AntigravityUsageMapper.parseQuotaSummary(Data("{\(fullGroupsJSON)}".utf8)) ?? []
        XCTAssertEqual(Set(summaryLines.map(\.label)), descriptorLabels)

        // The legacy path emits the two 5h pool labels — a strict subset of the descriptors.
        let legacyLabels = Set(AntigravityUsageMapper.buildLines([
            AntigravityModelConfig(label: "Gemini 3 Pro", modelID: "a", remainingFraction: 1, resetTime: nil),
            AntigravityModelConfig(label: "Claude Opus", modelID: "b", remainingFraction: 1, resetTime: nil)
        ]).map(\.label))
        XCTAssertEqual(legacyLabels, ["Session", "Claude"])
        XCTAssertTrue(legacyLabels.isSubset(of: descriptorLabels))
    }

    // MARK: - Provider integration: Cloud Code transport

    @MainActor
    private func makeCloudCodeProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { ["/nonexistent-antigravity-tests"] })
        )
    }

    @MainActor
    func testCloudCodeSummaryProducesFiveMetersAndPlan() async {
        let groupsJSON = fullGroupsJSON
        let partialGroupsJSON = claudeOnlyGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path == AntigravityUsageClient.quotaSummaryPath {
                // The remote endpoint returns the payload bare (no "response" wrapper).
                switch request.url.host {
                case "cloudcode-pa.googleapis.com":
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
                case "daily-cloudcode-pa.googleapis.com":
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(partialGroupsJSON)}".utf8))
                default:
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 60, 0])
        assertSummaryRequests(routing, hosts: ["cloudcode-pa.googleapis.com"])
        XCTAssertFalse(routing.requests.contains { $0.url.host == "daily-cloudcode-pa.googleapis.com" },
                       "a complete production response must not be replaced by the partial daily response")

        // Without Antigravity's client metadata loadCodeAssist omits currentTier/paidTier.
        let planRequest = routing.requests.first { $0.url.path.contains("loadCodeAssist") }
        let planBody = planRequest?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(planBody?["metadata"] as? [String: String], [
            "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"
        ])
    }

    @MainActor
    func testCloudCodeProduction503FallsBackToPartialDailySummary() async {
        let groupsJSON = claudeOnlyGroupsJSON
        let routing = RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                switch request.url.host {
                case "cloudcode-pa.googleapis.com":
                    return HTTPResponse(statusCode: 503, headers: [:], body: Data())
                case "daily-cloudcode-pa.googleapis.com":
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
                default:
                    break
                }
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await makeCloudCodeProvider(routing: routing).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Claude", "Claude Weekly"],
                       "Gemini and Argon rows must stay absent when the fallback has no data for them")
        XCTAssertEqual(snapshot.lines.map { used($0) }, [60, 0])
        assertSummaryRequests(routing, hosts: ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"])
    }

    @MainActor
    func testCloudCodeProductionTimeoutFallsBackToDailySummary() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                switch request.url.host {
                case "cloudcode-pa.googleapis.com":
                    throw URLError(.timedOut)
                case "daily-cloudcode-pa.googleapis.com":
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
                default:
                    break
                }
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await makeCloudCodeProvider(routing: routing).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 60, 0])
        assertSummaryRequests(routing, hosts: ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"])
    }

    private func assertSummaryRequests(
        _ routing: RoutingHTTPClient, hosts: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            routing.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.compactMap { $0.url.host },
            hosts, file: file, line: line
        )
        XCTAssertFalse(routing.requests.contains {
            $0.url.path == AntigravityUsageClient.fetchModelsPath || $0.url.path == AntigravityUsageClient.retrieveQuotaPath
        }, "a parsed summary must not touch the legacy endpoints", file: file, line: line)
    }

    @MainActor
    func testCloudCodeAuthoritativeEmptySummarySkipsLegacyChain() async {
        // A 200 summary with zero usable buckets is still the answer: the provider must return a
        // non-error snapshot with empty lines ("No data" rows) — even when the plan lookup fails —
        // and must never call fetchAvailableModels / retrieveUserQuota, which would fabricate
        // 100%-used meters from missing quota info.
        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertFalse(routing.requests.contains { $0.url.path.contains("fetchAvailableModels") })
        XCTAssertFalse(routing.requests.contains { $0.url.path == AntigravityUsageClient.retrieveQuotaPath })
    }

    /// Regression: on 2026-10-17 one Cloud Code host answered with only the Claude group while the
    /// other returned both, and taking the first 2xx host left Session/Weekly at "No data".
    @MainActor
    func testCloudCodeSummaryMergesBucketsAcrossHostsWhenOneOmitsAPool() async {
        let claudeOnly = """
        {"groups":[{"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","remainingFraction":0.8,"resetTime":"2026-07-06T07:00:00Z"},
          {"bucketId":"3p-5h","remainingFraction":1,"resetTime":"2026-07-02T15:30:00Z"}
        ]}]}
        """
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            guard request.url.path.contains("retrieveUserQuotaSummary") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            let body = request.url.host == "cloudcode-pa.googleapis.com" ? claudeOnly : "{\(groupsJSON)}"
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        // Claude buckets come from the production host (first wins); Gemini and Argon from the daily host.
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 0, 20])
        assertSummaryRequests(routing, hosts: ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"])
    }

    @MainActor
    func testCompletePreferredHostSummaryDoesNotWaitForAStalledHost() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            guard request.url.path.contains("retrieveUserQuotaSummary") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if request.url.host == "daily-cloudcode-pa.googleapis.com" {
                try await Task.sleep(for: .seconds(30))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let start = Date()
        let snapshot = await provider.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        assertSummaryRequests(routing, hosts: ["cloudcode-pa.googleapis.com"])
    }

    @MainActor
    func testCloudCodeSummaryFromOneHostSurvivesAuthFailureOnTheOther() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            guard request.url.path.contains("retrieveUserQuotaSummary") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if request.url.host == "cloudcode-pa.googleapis.com" {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
    }

    // MARK: - Provider integration: language-server transport

    @MainActor
    private func makeLSProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: FakeLSProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { ["/nonexistent-antigravity-tests"] })
        )
    }

    @MainActor
    func testLSWrappedSummaryWinsOverLegacyEndpointsAndTakesPlanFromUserStatus() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                // The LS wraps the payload in {"response": ...}.
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"response\":{\(groupsJSON)}}".utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                let body = """
                {"userStatus":{"userTier":{"name":"Google AI Pro"},
                "cascadeModelConfigData":{"clientModelConfigs":[
                  {"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.99}}
                ]}}}
                """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        // Summary values win — not the single 1%-used line the legacy GetUserStatus configs would pool to.
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 60, 0])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertFalse(routing.requests.contains { $0.url.path.hasSuffix("/GetCommandModelConfigs") })
    }

    @MainActor
    func testLSAuthoritativeEmptySummaryStopsProbeEvenWhenPlanCallFails() async {
        let routing = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"response":{"groups":[]}}"#.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertFalse(routing.requests.contains { $0.url.path.hasSuffix("/GetCommandModelConfigs") })
        // The authoritative answer stops the probe on the first endpoint: no other LS port, and
        // never the Cloud Code fallback.
        XCTAssertTrue(routing.requests.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 52168 })
    }

    @MainActor
    func testLSSummary404FallsBackToLegacyMergedPools() async {
        // Builds without the RPC 404 it; the legacy GetUserStatus flow stays the source (5h-only).
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if path.hasSuffix("/GetUserStatus") {
                let body = """
                {"userStatus":{"userTier":{"name":"Google AI Pro"},
                "cascadeModelConfigData":{"clientModelConfigs":[
                  {"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.5}},
                  {"label":"Gemini 4 Argon","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M421"},"quotaInfo":{}},
                  {"label":"Claude Sonnet 4.6","quotaInfo":{"remainingFraction":0.8}}
                ]}}}
                """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [50, 20])
        XCTAssertEqual(snapshot.plan, "Pro")
    }
}

/// Returns empty output for every subprocess, so language-server discovery finds nothing and the
/// provider deterministically exercises the Cloud Code path.
private struct NoProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// Fakes a running Antigravity `language_server` (pid 4276, one listening port 52168) so provider
/// tests exercise the LS probe without real subprocesses.
private struct FakeLSProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        if executable.hasSuffix("/ps") {
            let ps = "4276 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token tok --app_data_dir antigravity\n"
            return ProcessResult(exitCode: 0, stdout: ps, stderr: "")
        }
        let lsof = "language_ 4276 user 6u IPv4 0x0 0t0 TCP 127.0.0.1:52168 (LISTEN)\n"
        return ProcessResult(exitCode: 0, stdout: lsof, stderr: "")
    }
}

import XCTest
@testable import OpenUsage

final class AntigravityUsageClientTests: XCTestCase {
    private static let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private static let productionHost = "cloudcode-pa.googleapis.com"

    private static func bucket(_ id: String, fraction: Double? = nil, reset: String? = nil) -> String {
        var fields = [#""bucketId":"\#(id)""#]
        if let fraction { fields.append(#""remainingFraction":\#(fraction)"#) }
        if let reset { fields.append(#""resetTime":"\#(reset)""#) }
        return "{\(fields.joined(separator: ","))}"
    }

    private static func summary(_ buckets: [String]) -> String {
        #"{"groups":[{"displayName":"fake","buckets":[\#(buckets.joined(separator: ","))]}]}"#
    }

    private static let dailySummary = summary([
        bucket("gemini-5h", fraction: 0.99965, reset: "2027-03-02T14:00:00Z"),
        bucket("gemini-weekly", fraction: 0.9742, reset: "2027-03-08T09:00:00Z"),
        bucket("3p-5h", fraction: 0.5, reset: "2027-03-02T15:00:00Z"),
        bucket("3p-weekly", fraction: 0.4, reset: "2027-03-08T09:00:00Z")
    ])

    private static let productionSummary = summary([
        bucket("gemini-5h", fraction: 1, reset: "2027-03-02T19:00:00Z"),
        bucket("gemini-weekly", fraction: 1, reset: "2027-03-09T00:00:00Z"),
        bucket("3p-5h", fraction: 0.9, reset: "2027-03-02T19:00:00Z"),
        bucket("3p-weekly", fraction: 0.8, reset: "2027-03-09T00:00:00Z")
    ])

    private static func progress(_ line: MetricLine?) -> (used: Double, reset: Date?)? {
        guard case .progress(_, let used, _, _, let resetsAt, _)? = line else { return nil }
        return (used, resetsAt)
    }

    private func client(daily: HTTPResponse?, production: HTTPResponse?) -> (AntigravityUsageClient, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url.host {
            case Self.dailyHost:
                guard let daily else { throw URLError(.cannotFindHost) }
                return daily
            case Self.productionHost:
                guard let production else { throw URLError(.cannotFindHost) }
                return production
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        return (AntigravityUsageClient(http: http), http)
    }

    private func quotaHosts(_ http: RoutingHTTPClient) -> [String] {
        http.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.map(\.url.host!)
    }

    func testACompleteDailySummaryAnswersWithoutAskingProduction() async throws {
        let (client, http) = client(
            daily: .json(Self.dailySummary),
            production: .json(Self.productionSummary)
        )

        let bodies = try await client.quotaSummary(token: "access", project: "fake-project")

        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(quotaHosts(http), [Self.dailyHost])
        XCTAssertTrue(try XCTUnwrap(http.requests.first?.headers["User-Agent"]).hasPrefix("antigravity/hub/"))
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries(bodies))
        let session = try XCTUnwrap(Self.progress(lines.first { $0.label == AntigravityMetric.sessionLabel }))
        XCTAssertEqual(session.used, 0.035, accuracy: 0.001)
        XCTAssertEqual(session.reset, OpenUsageISO8601.date(from: "2027-03-02T14:00:00Z"))
        let weekly = try XCTUnwrap(Self.progress(lines.first { $0.label == AntigravityMetric.weeklyLabel }))
        XCTAssertEqual(weekly.used, 2.58, accuracy: 0.0001)
        XCTAssertEqual(weekly.reset, OpenUsageISO8601.date(from: "2027-03-08T09:00:00Z"))
    }

    func testDailyWinsPerBucketAndProductionFillsOmissions() async throws {
        let daily = Self.summary([
            Self.bucket("3p-5h", fraction: 0.6, reset: "2027-03-02T10:00:00Z")
        ])
        let (client, http) = client(daily: .json(daily), production: .json(Self.productionSummary))

        let bodies = try await client.quotaSummary(token: "access", project: "fake-project")
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries(bodies))

        XCTAssertEqual(quotaHosts(http), [Self.dailyHost, Self.productionHost])
        for label in [AntigravityMetric.sessionLabel, AntigravityMetric.weeklyLabel] {
            let line = try XCTUnwrap(Self.progress(lines.first { $0.label == label }))
            XCTAssertEqual(line.used, 0, accuracy: 0.0001, "\(label) comes from production")
        }
        let claude = try XCTUnwrap(Self.progress(lines.first { $0.label == AntigravityMetric.claudeLabel }))
        XCTAssertEqual(claude.used, 40, accuracy: 0.001)
        XCTAssertEqual(claude.reset, OpenUsageISO8601.date(from: "2027-03-02T10:00:00Z"))
        let claudeWeekly = try XCTUnwrap(Self.progress(lines.first { $0.label == AntigravityMetric.claudeWeeklyLabel }))
        XCTAssertEqual(claudeWeekly.used, 20, accuracy: 0.001)
    }

    func testAnUnusableDailyFractionFillsFromProduction() async throws {
        let daily = Self.summary([
            Self.bucket("gemini-5h"),
            Self.bucket("3p-5h", fraction: 0.5, reset: "2027-03-02T10:00:00Z")
        ])
        let (client, _) = client(daily: .json(daily), production: .json(Self.productionSummary))

        let bodies = try await client.quotaSummary(token: "access", project: nil)
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries(bodies))

        let session = try XCTUnwrap(Self.progress(lines.first { $0.label == AntigravityMetric.sessionLabel }))
        XCTAssertEqual(session.used, 0, accuracy: 0.0001)
        XCTAssertEqual(session.reset, OpenUsageISO8601.date(from: "2027-03-02T19:00:00Z"))
    }

    func testDailyServerErrorAndTransportErrorFallBackToProduction() async throws {
        for daily in [HTTPResponse?.some(.json("{}", status: 503)), nil] {
            let (client, http) = client(daily: daily, production: .json(Self.productionSummary))

            let bodies = try await client.quotaSummary(token: "access", project: nil)

            XCTAssertEqual(quotaHosts(http), [Self.dailyHost, Self.productionHost])
            XCTAssertEqual(bodies, [Data(Self.productionSummary.utf8)])
        }
    }

    func testDailyUnauthorizedStillSucceedsOnProduction() async throws {
        let (client, _) = client(
            daily: .json(#"{"error":{"code":401}}"#, status: 401),
            production: .json(Self.productionSummary)
        )

        let bodies = try await client.quotaSummary(token: "access", project: nil)

        XCTAssertEqual(bodies, [Data(Self.productionSummary.utf8)])
    }

    func testBothBasesUnauthorizedIsTokenRefused() async throws {
        let (client, _) = client(
            daily: .json(#"{"error":{"code":401}}"#, status: 401),
            production: .json(#"{"error":{"code":401}}"#, status: 401)
        )

        do {
            _ = try await client.quotaSummary(token: "access", project: nil)
            XCTFail("expected TokenRefused")
        } catch is AntigravityUsageClient.TokenRefused {
        } catch {
            XCTFail("expected TokenRefused, got \(error)")
        }
    }

    func testQuotaRequestsCarryTheProjectAndBearerToken() async throws {
        let (client, http) = client(daily: .json(Self.dailySummary), production: nil)

        _ = try await client.quotaSummary(token: "access", project: "fake-project-123")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer access")
        XCTAssertEqual(request.body.flatMap(ProviderParse.jsonObject)?["project"] as? String, "fake-project-123")
    }

    func testLoadCodeAssistStillAsksProductionFirst() async throws {
        let (client, http) = client(
            daily: .json(#"{"cloudaicompanionProject":"fake-project"}"#),
            production: .json("{}", status: 503)
        )

        _ = try await client.loadCodeAssist(token: "access")

        XCTAssertEqual(http.requests.map(\.url.host!), [Self.productionHost, Self.dailyHost])
    }
}

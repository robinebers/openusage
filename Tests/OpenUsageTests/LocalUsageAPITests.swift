import XCTest
@testable import OpenUsage

/// Covers the local HTTP API's routing and wire format (ported from the original's
/// docs/local-http-api.md): collection ordering + enablement filtering, single-provider status
/// codes, method/route errors, and the documented JSON keys (`providerId`, `fetchedAt`, tagged
/// `lines` with `format.kind`).
final class LocalUsageAPITests: XCTestCase {
    private func makeState() -> LocalUsageAPI.State {
        let refreshedAt = OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        let claude = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Pro",
            lines: [
                .progress(label: "Session", used: 42, limit: 100, format: .percent,
                          resetsAt: OpenUsageISO8601.date(from: "2026-03-26T13:00:00.161Z"),
                          periodDurationMs: 18_000_000),
                .values(label: "Today", values: [
                    MetricValue(number: 5.17, kind: .dollars),
                    MetricValue(number: 9_200_000, kind: .count, label: "tokens")
                ])
            ],
            refreshedAt: refreshedAt
        )
        let cursor = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Requests", used: 12, limit: 500, format: .count(suffix: "requests"))],
            refreshedAt: refreshedAt
        )
        return LocalUsageAPI.State(
            enabledOrderedIDs: ["cursor", "claude"],          // user order, devin disabled
            knownIDs: ["claude", "cursor", "devin"],
            snapshots: ["claude": claude, "cursor": cursor]
        )
    }

    private func json(_ data: Data?) throws -> Any {
        try JSONSerialization.jsonObject(with: XCTUnwrap(data))
    }

    func testCollectionReturnsEnabledProvidersInUserOrder() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: makeState())

        XCTAssertEqual(response.status, 200)
        let array = try XCTUnwrap(try json(response.body) as? [[String: Any]])
        XCTAssertEqual(array.map { $0["providerId"] as? String }, ["cursor", "claude"])
        XCTAssertEqual(array[1]["plan"] as? String, "Pro")
        XCTAssertEqual(array[1]["fetchedAt"] as? String, "2026-03-26T11:16:29.000Z")
    }

    func testWireShapeMatchesDocumentedFormat() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude", state: makeState())

        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(try json(response.body) as? [String: Any])
        let lines = try XCTUnwrap(object["lines"] as? [[String: Any]])

        let progress = try XCTUnwrap(lines.first { $0["type"] as? String == "progress" })
        XCTAssertEqual(progress["used"] as? Double, 42)
        XCTAssertEqual((progress["format"] as? [String: Any])?["kind"] as? String, "percent")
        XCTAssertEqual(progress["resetsAt"] as? String, "2026-03-26T13:00:00.161Z")
        XCTAssertEqual(progress["periodDurationMs"] as? Int, 18_000_000)
        XCTAssertTrue(progress.keys.contains("color"))        // explicit null, like the original

        let text = try XCTUnwrap(lines.first { $0["type"] as? String == "text" })
        XCTAssertEqual(text["value"] as? String, "$5.17 · 9.2M tokens")
        XCTAssertTrue(text.keys.contains("subtitle"))
    }

    func testCountFormatCarriesSuffix() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/cursor", state: makeState())
        let object = try XCTUnwrap(try json(response.body) as? [String: Any])
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)

        XCTAssertEqual((line["format"] as? [String: Any])?["kind"] as? String, "count")
        XCTAssertEqual((line["format"] as? [String: Any])?["suffix"] as? String, "requests")
    }

    func testSingleProviderStatusCodes() throws {
        let state = makeState()

        // Known but never fetched → 204 without a body.
        let pending = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/devin", state: state)
        XCTAssertEqual(pending.status, 204)
        XCTAssertNil(pending.body)

        // Unknown provider → 404 provider_not_found.
        let unknown = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/nope", state: state)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual((try json(unknown.body) as? [String: Any])?["error"] as? String, "provider_not_found")
    }

    func testMethodAndRouteErrors() throws {
        let state = makeState()

        let post = LocalUsageAPI.respond(method: "POST", path: "/v1/usage", state: state)
        XCTAssertEqual(post.status, 405)
        XCTAssertEqual((try json(post.body) as? [String: Any])?["error"] as? String, "method_not_allowed")

        let preflight = LocalUsageAPI.respond(method: "OPTIONS", path: "/v1/usage", state: state)
        XCTAssertEqual(preflight.status, 204)

        let unknownRoute = LocalUsageAPI.respond(method: "GET", path: "/v2/everything", state: state)
        XCTAssertEqual(unknownRoute.status, 404)
        XCTAssertEqual((try json(unknownRoute.body) as? [String: Any])?["error"] as? String, "not_found")
    }
}

final class LocalUsageServerRequestLineTests: XCTestCase {
    func testParsesWellFormedRequestLine() {
        let (method, path) = LocalUsageServer.parseRequestLine("GET /v1/usage HTTP/1.1\r\nHost: localhost\r\n")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/v1/usage")
    }

    func testEmptyHeadDegradesToDefaultsInsteadOfCrashing() {
        // A request that begins with the CRLFCRLF terminator (or carries invalid UTF-8, decoded to "")
        // yields an empty head. The previous `head.split(...)[0]` force-index trapped here, crashing
        // the whole menu-bar process; it must now degrade to ("", "/") so the router returns a 404.
        let (method, path) = LocalUsageServer.parseRequestLine("")
        XCTAssertEqual(method, "")
        XCTAssertEqual(path, "/")
    }

    func testRequestLineWithoutPathDefaultsPath() {
        let (method, path) = LocalUsageServer.parseRequestLine("GET\r\n")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/")
    }
}

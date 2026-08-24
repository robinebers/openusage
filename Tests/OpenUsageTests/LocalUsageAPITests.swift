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
        let array = try XCTUnwrap(try json(response.body) as? [[String: Any]])
        let object = try XCTUnwrap(array.first)
        XCTAssertEqual(array.count, 1)
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
        let object = try XCTUnwrap((try json(response.body) as? [[String: Any]])?.first)
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)

        XCTAssertEqual((line["format"] as? [String: Any])?["kind"] as? String, "count")
        XCTAssertEqual((line["format"] as? [String: Any])?["suffix"] as? String, "requests")
    }

    func testSingleTokenStatusCodes() throws {
        let state = makeState()

        // Known but never fetched → 200 with an empty array (the shape never changes; "no data yet"
        // is just zero elements).
        let pending = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/devin", state: state)
        XCTAssertEqual(pending.status, 200)
        XCTAssertEqual(try XCTUnwrap(try json(pending.body) as? [Any]).count, 0)

        // A token naming no known card and no family → 404 provider_not_found.
        let unknown = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/nope", state: state)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual((try json(unknown.body) as? [String: Any])?["error"] as? String, "provider_not_found")

        let unknownLimits = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/nope", state: state)
        XCTAssertEqual(unknownLimits.status, 404)
    }

    func testFamilyTokenMatchesEveryCardOfTheFamily() throws {
        // Matching is plain string comparison — a token names an exact card id or, as a family id,
        // every card of that family. Nothing about the answer depends on runtime state.
        var state = makeState()
        let refreshedAt = OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        state.knownIDs.insert("claude@ab12cd34")
        state.snapshots["claude@ab12cd34"] = ProviderSnapshot(
            providerID: "claude@ab12cd34",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 7, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )

        let family = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude", state: state)
        XCTAssertEqual(family.status, 200)
        let matched = try XCTUnwrap(try json(family.body) as? [[String: Any]])
        XCTAssertEqual(matched.compactMap { $0["providerId"] as? String }, ["claude", "claude@ab12cd34"])

        // The exact card id names just that card.
        let exact = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude@ab12cd34", state: state)
        let single = try XCTUnwrap(try json(exact.body) as? [[String: Any]])
        XCTAssertEqual(single.compactMap { $0["providerId"] as? String }, ["claude@ab12cd34"])

        // The limits envelope is keyed by card id, so a family token carries every matched card too.
        let limits = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/claude", state: state)
        XCTAssertEqual(limits.status, 200)
        let envelope = try XCTUnwrap(try json(limits.body) as? [String: Any])
        let providers = try XCTUnwrap(envelope["providers"] as? [String: Any])
        XCTAssertEqual(Set(providers.keys), ["claude", "claude@ab12cd34"])
    }

    func testResolvedTitlesOverrideSnapshotDisplayNamesAtTheBoundary() throws {
        // Snapshots always store the derived name; the boundary re-resolves against the account
        // registry so API/CLI output carries renames without ever persisting them.
        let state = makeState().resolvingDisplayNames(["claude": "Claude Team"])

        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state)
        let array = try XCTUnwrap(try json(response.body) as? [[String: Any]])
        XCTAssertEqual(array.first { $0["providerId"] as? String == "claude" }?["displayName"] as? String, "Claude Team")
        XCTAssertEqual(
            array.first { $0["providerId"] as? String == "cursor" }?["displayName"] as? String,
            "Cursor",
            "cards without a record keep their baked name"
        )
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

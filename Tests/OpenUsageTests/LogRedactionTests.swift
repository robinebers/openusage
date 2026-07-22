import XCTest
@testable import OpenUsage

/// The never-log-secrets regression guard. Each case mirrors a Rust test from
/// `src-tauri/src/plugin_engine/host_api.rs` / `src-tauri/src/config.rs`, ported verbatim where a
/// vector exists, so a subtle regex divergence (leak or over-redaction) trips here.
final class LogRedactionTests: XCTestCase {
    // MARK: - redactValue

    func testRedactValueShortIsFullyRedacted() {
        XCTAssertEqual(LogRedaction.redactValue("short"), "[REDACTED]")
        // Exactly 12 characters is still fully redacted (boundary: <= 12).
        XCTAssertEqual(LogRedaction.redactValue("abcdefghijkl"), "[REDACTED]")
    }

    func testRedactValueLongMasksEnds() {
        // 13 characters: first4...last4. Mirrors the Rust `sk-1...cdef` vector.
        XCTAssertEqual(LogRedaction.redactValue("sk-1234567890abcdef"), "sk-1...cdef")
        XCTAssertEqual(LogRedaction.redactValue("abcdefghijklm"), "abcd...jklm")
    }

    // MARK: - redactURL

    func testRedactURLSensitiveParamsOnly() {
        let url = "https://api.example.com/v1?api_key=sk-1234567890abcdef&other=value"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertTrue(redacted.contains("api_key=sk-1...cdef"), redacted)
        XCTAssertTrue(redacted.contains("other=value"), redacted)
    }

    func testRedactURLUserParam() {
        let url = "https://cursor.com/api/usage?user=user_abcdefghijklmnopqrstuvwxyz&limit=10"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertTrue(redacted.contains("user=user...wxyz"), redacted)
        XCTAssertTrue(redacted.contains("limit=10"), redacted)
    }

    func testRedactURLOrganizationIDs() {
        let camelCase = LogRedaction.redactURL(
            "https://api.commandcode.ai/alpha/billing/credits?orgId=org-abcdefghijklmnopqrstuvwxyz"
        )
        let snakeCase = LogRedaction.redactURL(
            "https://api.example.com/v1?org_id=org-abcdefghijklmnopqrstuvwxyz&limit=10"
        )

        XCTAssertFalse(camelCase.contains("org-abcdefghijklmnopqrstuvwxyz"), camelCase)
        XCTAssertTrue(camelCase.contains("orgId=org-...wxyz"), camelCase)
        XCTAssertFalse(snakeCase.contains("org-abcdefghijklmnopqrstuvwxyz"), snakeCase)
        XCTAssertTrue(snakeCase.contains("limit=10"), snakeCase)
    }

    func testRedactURLPreservesNonSensitiveParams() {
        let url = "https://api.example.com/v1?limit=10&offset=20"
        XCTAssertEqual(LogRedaction.redactURL(url), url)
    }

    func testRedactURLProfileArn() {
        let url = "https://q.us-east-1.amazonaws.com/getUsageLimits?profileArn=arn:aws:codewhisperer:us-east-1:699475941385:profile/EHGA3GRVQMUK&origin=AI_EDITOR"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertFalse(redacted.contains("699475941385"), redacted)
        XCTAssertTrue(redacted.contains("origin=AI_EDITOR"), redacted)
    }

    func testRedactURLPreservesNameCaseAndSkipsEmptyValue() {
        let redacted = LogRedaction.redactURL("https://x.com/a?Api_Key=&Token=secretsecretsecret")
        XCTAssertTrue(redacted.contains("Api_Key="), redacted) // empty value left untouched
        XCTAssertTrue(redacted.contains("Token=secr...cret"), redacted) // name casing preserved
    }

    func testRedactURLNoQueryUnchanged() {
        XCTAssertEqual(LogRedaction.redactURL("https://api.example.com/v1"), "https://api.example.com/v1")
    }

    // MARK: - redactBody

    func testRedactBodyJWT() {
        let body = #"{"token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), redacted)
    }

    func testRedactBodyApiKeys() {
        let body = #"{"key": "sk-1234567890abcdefghij"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertTrue(redacted.contains("sk-1...ghij"), redacted)
    }

    func testRedactBodyDevinSession() {
        let body = #"metadata apiKey=devin-session-token$abcdefghijklmnopqrstuvwxyz123456"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("devin-session-token$abcdefghijklmnopqrstuvwxyz123456"), redacted)
        XCTAssertTrue(redacted.contains("devi...3456"), redacted)
    }

    func testRedactBodyJSONPassword() {
        let body = #"{"password": "supersecretpassword123"}"#
        XCTAssertFalse(LogRedaction.redactBody(body).contains("supersecretpassword123"))
    }

    func testRedactBodyUserIdAndEmail() {
        let body = #"{"user_id": "user-iupzZ7KFykMLrnzpkHSq7wjo", "email": "rob@sunstory.com"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("user-iupzZ7KFykMLrnzpkHSq7wjo"), redacted)
        XCTAssertFalse(redacted.contains("rob@sunstory.com"), redacted)
        XCTAssertTrue(redacted.contains("user...7wjo"), redacted)
        XCTAssertTrue(redacted.contains("rob@....com"), redacted)
    }

    func testRedactBodyCamelCaseIds() {
        let body = #"{"userId": "user_abcdefghijklmnopqrstuvwxyz", "accountId": "acct_1234567890abcdef"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertTrue(redacted.contains("user...wxyz"), redacted)
        XCTAssertTrue(redacted.contains("acct...cdef"), redacted)
    }

    func testRedactBodyDevinOrgAndDisplayName() {
        let body = #"{"orgId":"org-6b6e9de248db472bb25b296599ea3dc0","accountDisplayName":"rob@sunstory.com","devinInfo":{"org_id":"org-abcdef1234567890","account_display_name":"team@example.com"}}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("org-6b6e9de248db472bb25b296599ea3dc0"), redacted)
        XCTAssertFalse(redacted.contains("team@example.com"), redacted)
        XCTAssertTrue(redacted.contains("org-...3dc0"), redacted)
    }

    func testRedactBodyTeamIdPaymentIdAndPaths() {
        let body = #"{"teamId":"cc1ac023-9ff5-4c1f-a5a4-ae2a82df4243","paymentId":"cus_S5m1PGxjLWoc1c","binaryPath":"/opt/homebrew/bin/bunx","homePath":"/Users/rebers/.claude"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("cc1ac023-9ff5-4c1f-a5a4-ae2a82df4243"), redacted)
        XCTAssertFalse(redacted.contains("cus_S5m1PGxjLWoc1c"), redacted)
        XCTAssertFalse(redacted.contains("/opt/homebrew/bin/bunx"), redacted)
        XCTAssertFalse(redacted.contains("/Users/rebers/.claude"), redacted)
        XCTAssertTrue(redacted.contains("[PATH]"), redacted)
    }

    func testRedactBodyProfileArn() {
        let body = #"{"profileArn":"arn:aws:codewhisperer:us-east-1:699475941385:profile/EHGA3GRVQMUK","profile_arn":"arn:aws:codewhisperer:us-east-1:699475941385:profile/EHGA3GRVQMUK"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("699475941385"), redacted)
        XCTAssertTrue(redacted.contains("arn:...QMUK"), redacted)
    }

    func testRedactBodyLoginAndAnalyticsTrackingId() {
        let body = #"{"login":"robinebers","analytics_tracking_id":"c9df3f012bb8c2eb7aae6868ee8da6cf"}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("robinebers"), redacted)
        XCTAssertFalse(redacted.contains("c9df3f012bb8c2eb7aae6868ee8da6cf"), redacted)
        XCTAssertTrue(redacted.contains("[REDACTED]"), redacted)
        XCTAssertTrue(redacted.contains("c9df...a6cf"), redacted)
    }

    func testRedactBodyNameField() {
        let body = #"{"userStatus":{"name":"Robin Ebers","email":"rob@sunstory.com","planStatus":{}}}"#
        let redacted = LogRedaction.redactBody(body)
        XCTAssertFalse(redacted.contains("Robin Ebers"), redacted)
        XCTAssertFalse(redacted.contains("rob@sunstory.com"), redacted)
    }

    // MARK: - bodyPreview truncation

    func testBodyPreviewTruncatesWithByteCount() {
        let body = String(repeating: "a", count: 700)
        let preview = LogRedaction.bodyPreview(body)
        XCTAssertTrue(preview.hasSuffix("... (700 bytes total)"), preview)
        // Truncated content is at most the limit (500) characters before the marker.
        let beforeMarker = preview.replacingOccurrences(of: "... (700 bytes total)", with: "")
        XCTAssertLessThanOrEqual(beforeMarker.count, 500)
    }

    func testBodyPreviewShortReturnsRedactedWhole() {
        let body = #"{"plan":"pro"}"#
        XCTAssertEqual(LogRedaction.bodyPreview(body), body)
    }

    func testBodyPreviewRedactsBeforeTruncating() {
        // A secret straddling the cut must still be caught: redaction runs before truncation.
        let secret = "sk-1234567890abcdefghij"
        let body = String(repeating: "x", count: 490) + secret + String(repeating: "y", count: 200)
        let preview = LogRedaction.bodyPreview(body)
        XCTAssertFalse(preview.contains(secret), preview)
    }

    // MARK: - redactLogMessage

    func testRedactLogMessageJWTAndBareApiKey() {
        let msg = "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U key=sk-1234567890abcdef"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), redacted)
        XCTAssertFalse(redacted.contains("sk-1234567890abcdef"), redacted)
    }

    func testRedactLogMessageDevinSession() {
        let msg = "auth=devin-session-token$abcdefghijklmnopqrstuvwxyz123456"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("devin-session-token$abcdefghijklmnopqrstuvwxyz123456"), redacted)
        XCTAssertTrue(redacted.contains("devi...3456"), redacted)
    }

    func testRedactLogMessageAccountEqAndPaths() {
        let msg = "keychain read: service=Claude Code-credentials, account=rebers path=/opt/homebrew/bin/bunx home=/Users/rebers/.claude"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("account=rebers"), redacted)
        XCTAssertFalse(redacted.contains("/opt/homebrew/bin/bunx"), redacted)
        XCTAssertFalse(redacted.contains("/Users/rebers/.claude"), redacted)
        XCTAssertTrue(redacted.contains("account=[REDACTED]"), redacted)
        XCTAssertTrue(redacted.contains("[PATH]"), redacted)
    }
}

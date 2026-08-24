import XCTest
@testable import OpenUsage

final class CodexHomeDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func authJSON(
        accountID: String? = "acct-1",
        email: String? = nil,
        accessToken: String? = "at-1"
    ) -> String {
        var tokens: [String: String] = [:]
        if let accountID { tokens["account_id"] = accountID }
        if let accessToken { tokens["access_token"] = accessToken }
        if let email { tokens["id_token"] = fakeJWT(payload: ["email": email]) }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
        return String(decoding: data, as: UTF8.self)
    }

    private func fakeJWT(payload: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(payload)).sig"
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> CodexHomeDiscovery {
        CodexHomeDiscovery(
            files: FakeFiles(files),
            homeDirectory: { [home] in home },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testAcceptsFileBackedSiblingHomeWithStrictIdentityAndLabel() throws {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.codex-work/auth.json": authJSON(
                    accountID: "WORK-ACCOUNT",
                    email: "dev@company.example"
                ),
            ],
            subdirectories: ["/Users/dev/.codex-work"]
        )

        let result = discovery.run()

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(finding.identityKey, "work-account")
        XCTAssertEqual(finding.label, "dev@company.example")
        XCTAssertEqual(finding.anchorPath, "/Users/dev/.codex-work")
        XCTAssertFalse(result.notes.joined().contains("dev@company.example"), "support trail is email-free")
    }

    func testScansConfigSiblingsAndRejectsCredentialsThatCannotNameAnAccount() {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.config/codex-personal/auth.json": authJSON(accountID: "PERSONAL"),
                "/Users/dev/.codex-anonymous/auth.json": authJSON(accountID: nil),
                "/Users/dev/.codex-api/auth.json": #"{"OPENAI_API_KEY":"sk-test"}"#,
            ],
            subdirectories: [
                "/Users/dev/.config/codex-personal",
                "/Users/dev/.codex-anonymous",
                "/Users/dev/.codex-api",
                "/Users/dev/projects",
            ]
        )

        let result = discovery.run()

        XCTAssertEqual(result.findings.map(\.identityKey), ["personal"])
        XCTAssertEqual(result.notes.filter { $0.contains("skipped") }.count, 2)
    }

    func testExcludesOnlyTheHomeFeedingTheBareCard() {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.config/codex/auth.json": authJSON(accountID: "WORK"),
                "/Users/dev/.codex/auth.json": authJSON(accountID: "PERSONAL"),
            ],
            subdirectories: [
                "/Users/dev/.config/codex",
                "/Users/dev/.codex",
            ]
        )

        let result = discovery.run(excluding: ["/Users/dev/.config/codex"])

        XCTAssertEqual(result.findings.map(\.identityKey), ["personal"])
        XCTAssertEqual(result.findings.map(\.anchorPath), ["/Users/dev/.codex"])
    }
}

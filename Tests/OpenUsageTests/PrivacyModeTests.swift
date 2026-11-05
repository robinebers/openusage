import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PrivacyModeTests: QuietWindowTestCase {
    func testLiveToggleMasksAccountNamesAndErrorDetailsAndRestoresThem() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let provider = Provider(id: "claude@private", kind: .claude, accountLabel: "private@example.com")
        let message = "The account private@example.com at private-hub.example.com needs attention."
        let account = makeAccount(provider)
        let board = PriorityBoard.make(accounts: [account], pinned: [account.lines[0].id], now: Date())
        let view = VStack {
            AccountListRow(provider: provider) { EmptyView() }
            DashboardAccountRows(account: account, plan: "Max 20x")
            PriorityBoardList(board: board, now: Date())
            ProblemCard(message: message)
            ErrorText(message)
            AccountStatus(notice: message).glyph
        }
        .defaultAppStorage(defaults)
        let host = show(view, size: CGSize(width: 420, height: 700)).host

        try await waitUntil { self.accessibilityText(in: host).contains(message) }
        XCTAssertTrue(accessibilityText(in: host).contains(provider.accountName))

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Session") && !text.contains("private@example.com") && !text.contains("private-hub.example.com")
        }
        let concealed = accessibilityText(in: host)
        XCTAssertTrue(concealed.contains("Claude"), "the provider remains identifiable")
        XCTAssertTrue(concealed.contains("Max 20x"), "Privacy Mode keeps the real plan visible")
        XCTAssertFalse(concealed.contains(message), "error details must not remain in accessibility labels or values")

        defaults.set(false, forKey: PrivacyModeSetting.key)
        try await waitUntil { self.accessibilityText(in: host).contains(message) }
        XCTAssertTrue(accessibilityText(in: host).contains(provider.accountName))
    }

    func testPrivacyModeMasksCustomNamesInCopiedCardContent() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let provider = Provider(id: "claude@private", kind: .claude, accountLabel: "Private Customer Project")
        let account = makeAccount(provider)
        let family = DashboardFamily(id: "claude", provider: provider, accounts: [account])
        let view = ShareCardView(family: family, appearance: .light).defaultAppStorage(defaults)
        let host = show(view, size: CGSize(width: ShareCardView.width, height: 300)).host
        try await waitUntil { self.accessibilityText(in: host).contains("Private Customer Project") }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Session") && !text.contains("Private Customer Project")
        }
        XCTAssertTrue(accessibilityText(in: host).contains("Claude"))
        XCTAssertEqual(provider.accountLabel, "Private Customer Project", "sharing changes presentation, not the provider")
    }

    func testHubHostIsMaskedInItsRowAndOpenButton() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        let hub = CLIProxyHub(url: try XCTUnwrap(URL(string: "https://private-hub.example.com:8443")))
        let view = CLIProxyHubRow(hub: hub, onOpen: {})
            .defaultAppStorage(defaults)
            .environment(container)
        let host = show(view, size: CGSize(width: 420, height: 100)).host
        try await waitUntil { self.accessibilityText(in: host).contains(hub.host) }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Open") && !text.contains("private-hub.example.com")
        }
        XCTAssertEqual(hub.url.absoluteString, "https://private-hub.example.com:8443")
    }

    func testAnOpenRenameDraftCannotExposeTheAccountWhilePrivacyModeIsOn() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: defaults, vault: vault)
        let credential = AccountCredential.apiKey("stored-secret")
        let saved = store.add(kind: .claude, label: "saved-private@example.com", credential: credential)
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        container.popover.customizeProviderID = saved.cardID
        let renaming = container.renaming
        renaming.begin(saved.cardID)
        renaming.draft = "draft-private@example.com"
        let provider = Provider(id: saved.cardID, kind: .claude, accountLabel: saved.label)
        let view = VStack {
            AccountName(account: DashboardAccount(provider: provider, lines: []), font: .body)
            PopoverTopBar(screen: .accounts)
        }
        .defaultAppStorage(defaults)
        .environment(container)
        .environment(container.layout)
        .environment(container.popover)
        .environment(renaming)
        let host = show(view, size: CGSize(width: 420, height: 160)).host
        try await waitUntil { self.textFields(in: host).contains { $0.stringValue == renaming.draft } }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            !self.textFields(in: host).contains { $0.stringValue.contains("private@example.com") }
                && !self.accessibilityText(in: host).contains("private@example.com")
        }
        XCTAssertEqual(store.account(cardID: saved.cardID)?.label, saved.label)
        XCTAssertEqual(try vault.load(saved.id), credential, "masking must leave the saved sign-in intact")
    }

    func testPastedOAuthCodesUseASecureFieldOnlyWhilePrivacyModeIsOn() async throws {
        for enabled in [false, true] {
            let defaults = isolatedDefaults()
            defaults.set(enabled, forKey: PrivacyModeSetting.key)
            let flow = AddAccountFlow(
                store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { _ in }
            ) { _, _, _, _ in
                PrivacyPromptLogin(prompt: .browser(URL(string: "https://example.com/authorize")!, acceptsPastedCode: true))
            }
            addTeardownBlock { flow.cancel() }
            flow.choose(.claude)
            try await waitUntil { flow.prompt != nil }
            flow.pastedCode = "private-oauth-code"
            let host = show(AddAccountSheet(flow: flow).defaultAppStorage(defaults), in: .titled).host
            try await waitUntil { self.textFields(in: host).contains { $0.stringValue == "private-oauth-code" } }
            let field = try XCTUnwrap(textFields(in: host).first { $0.stringValue == "private-oauth-code" })
            XCTAssertEqual(field is NSSecureTextField, enabled)
            XCTAssertEqual(flow.pastedCode, "private-oauth-code", "masking must preserve the submitted code")
        }
    }

    func testDeviceCodeIsHiddenWithoutARevealControl() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let flow = AddAccountFlow(
            store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { _ in }
        ) { _, _, _, _ in
            PrivacyPromptLogin(prompt: .deviceCode(userCode: "ABCD-1234", verificationURL: URL(string: "https://example.com/device")!))
        }
        addTeardownBlock { flow.cancel() }
        flow.choose(.codex)
        try await waitUntil { flow.prompt != nil }
        let host = show(AddAccountSheet(flow: flow).defaultAppStorage(defaults), in: .titled).host
        try await waitUntil { self.accessibilityText(in: host).contains("ABCD-1234") }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Copy Code") && !text.contains("ABCD-1234")
        }
        XCTAssertFalse(accessibilityText(in: host).localizedCaseInsensitiveContains("reveal"))
        guard case .deviceCode(let code, _) = flow.prompt else { return XCTFail("the sign-in prompt changed") }
        XCTAssertEqual(code, "ABCD-1234", "masking must preserve the sign-in code")
    }

    func testPersonalSignInInputsUseSecureFieldsInPrivacyMode() async throws {
        for input in ["name", "organization", "hub", "domain"] {
            let defaults = isolatedDefaults()
            defaults.set(true, forKey: PrivacyModeSetting.key)
            let flow = AddAccountFlow(store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()))
            let secret: String
            switch input {
            case "name":
                flow.choose(.ollama)
                secret = "Private Project Name"
                flow.accountName = secret
            case "organization":
                flow.choose(.copilot)
                flow.choose(.organizationToken)
                secret = "private-organization"
                flow.organization = secret
            case "domain":
                flow.choose(.copilot)
                flow.choose(.oauth)
                secret = "private-company.ghe.com"
                flow.domain = secret
            default:
                flow.chooseHub()
                secret = "https://private-hub.example.com"
                flow.hubURL = secret
            }
            addTeardownBlock { flow.cancel() }
            let host = show(AddAccountSheet(flow: flow).defaultAppStorage(defaults), in: .titled).host
            try await waitUntil { self.textFields(in: host).contains { $0.stringValue == secret } }
            let field = try XCTUnwrap(textFields(in: host).first { $0.stringValue == secret })
            XCTAssertTrue(field is NSSecureTextField, "\(input) must not be drawn as plain text")
        }
    }

    func testEnterpriseDomainIsHiddenInAccountDetailsAndRestoredWhenPrivacyModeIsOff() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let domain = "private-company.ghe.com"
        let saved = store.add(kind: .copilot, label: "Private Account", domain: domain, credential: .oauth(OAuthTokens(accessToken: "token")))
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let view = AccountDetailView(providerID: saved.cardID, reorderSpaceName: "reorder", reorderLift: .constant(nil), frameStore: ReorderFrameStore())
            .defaultAppStorage(defaults)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
        let host = show(view, size: CGSize(width: 420, height: 500)).host
        try await waitUntil { self.accessibilityText(in: host).contains(domain) }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Details are hidden") && !text.contains(domain)
        }
        XCTAssertEqual(store.account(cardID: saved.cardID)?.domain, domain)

        defaults.set(false, forKey: PrivacyModeSetting.key)
        try await waitUntil { self.accessibilityText(in: host).contains(domain) }
    }

    func testEnterpriseDevicePromptHidesTheDomainWhileKeepingTheSignIn() async throws {
        enableAccessibility()
        let defaults = isolatedDefaults()
        let flow = AddAccountFlow(
            store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { _ in }
        ) { _, _, _, _ in
            PrivacyPromptLogin(prompt: .deviceCode(userCode: "ABCD-1234", verificationURL: URL(string: "https://private-company.ghe.com/login/device")!))
        }
        addTeardownBlock { flow.cancel() }
        flow.choose(.copilot)
        flow.choose(.oauth)
        flow.domain = "private-company.ghe.com"
        flow.continueToSignIn()
        try await waitUntil { flow.prompt != nil }
        let host = show(AddAccountSheet(flow: flow).defaultAppStorage(defaults), in: .titled).host
        try await waitUntil { self.accessibilityText(in: host).contains("private-company.ghe.com") }

        defaults.set(true, forKey: PrivacyModeSetting.key)
        try await waitUntil {
            let text = self.accessibilityText(in: host)
            return text.contains("Copy Code") && !text.contains("private-company.ghe.com") && !text.contains("ABCD-1234")
        }
        XCTAssertEqual(flow.gitHubDomain?.saved, "private-company.ghe.com")
    }

    private func makeAccount(_ provider: Provider) -> DashboardAccount {
        let data = WidgetData(title: "Session", kind: .percent, used: 30, limit: 100)
        let descriptor = WidgetDescriptor(provider: provider, key: "session", metricLabel: "Session", sample: data)
        return DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: data)])
    }

    private func enableAccessibility() {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        addTeardownBlock { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
    }

    /// Read the actual SwiftUI accessibility tree, including labels on controls and status glyphs.
    private func accessibilityText(in element: Any) -> String {
        var visited: Set<ObjectIdentifier> = []
        func strings(in element: Any) -> [String] {
            guard let node = element as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let attributes = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"]
            let values = attributes.compactMap { key -> String? in
                guard node.responds(to: NSSelectorFromString(key)) else { return nil }
                return node.value(forKey: key) as? String
            }
            guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return values }
            return values + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(strings)
        }
        return strings(in: element).joined(separator: " ")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        [view as? NSTextField].compactMap { $0 } + view.subviews.flatMap(textFields)
    }
}

private struct PrivacyPromptLogin: ProviderLogin {
    let prompt: LoginPrompt

    func login(prompt show: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        await show(prompt)
        try await Task.sleep(for: .seconds(30))
        return ("late", .oauth(OAuthTokens(accessToken: "access")))
    }
}

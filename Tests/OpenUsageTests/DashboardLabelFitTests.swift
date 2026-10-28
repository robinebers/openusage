import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Every metric title and plan a provider can produce renders at full size in the panel: every title
/// fits the 86 pt label column and no plan truncates. Plans are the providers' official names, never
/// shortened to fit. Robin's own accounts are measured on their captions in `DashboardHeaderFitTests`.
@MainActor
final class DashboardLabelFitTests: XCTestCase {
    /// A provider's card: the panel minus its margin on each side.
    private let cardWidth = PanelMetrics.width - 2 * PanelMetrics.margin

    /// Every provider's titles fit the fixed label column at the row's type size, so no label truncates.
    func testEveryProvidersMetricTitlesFitTheLabelColumn() {
        for kind in ProviderKind.allCases {
            let runtime = AccountProviderRuntime(account: Account(kind: kind, label: kind.displayName), vault: InMemoryCredentialVault())
            for title in runtime.widgetDescriptors.map(\.sample.title) {
                XCTAssertLessThanOrEqual(idealWidth(Text(title).font(DashboardMetricRow.font)), DashboardGrid.labelWidth, "\(kind.displayName): \(title)")
            }
        }
    }

    /// Two metrics of one account never share a title, so no two rows read the same.
    func testEveryProvidersMetricTitlesAreDistinct() {
        for kind in ProviderKind.allCases {
            let runtime = AccountProviderRuntime(account: Account(kind: kind, label: kind.displayName), vault: InMemoryCredentialVault())
            let titles = runtime.widgetDescriptors.map(\.sample.title)
            XCTAssertEqual(Set(titles).count, titles.count, "\(kind.displayName): \(titles)")
        }
        let antigravity = AccountProviderRuntime(account: Account(kind: .antigravity, label: "Antigravity"), vault: InMemoryCredentialVault())
        XCTAssertEqual(antigravity.widgetDescriptors.map(\.sample.title), ["Gemini 5h", "Gemini", "Argon", "Claude 5h", "Claude"])
    }

    /// Each plan a mapper can name fits on its caption inside the card beside the provider's own name,
    /// which is what an account nobody renamed is called, with room for the warning glyph.
    func testEveryPlanFitsOnItsCaption() throws {
        for (kind, plans) in try plansByProvider() {
            XCTAssertFalse(plans.isEmpty, kind.displayName)
            let account = account(kind, kind.displayName)
            for plan in plans {
                let caption = DashboardAccountCaption(account: account, plan: plan, status: AccountStatus(notice: "Refresh failed"))
                XCTAssertLessThanOrEqual(idealWidth(caption), cardWidth - 2 * DashboardGrid.cardPadding, "\(kind.displayName): \(plan)")
            }
        }
    }

    /// The hover text keeps cents, but a whole-dollar value drops them.
    func testWholeDollarValuesDropTheirCents() {
        XCTAssertEqual(meter(left: 500, limit: 500).valueText, "$500")
        XCTAssertEqual(meter(left: 37.42, limit: 100).valueText, "$37.42")
        XCTAssertEqual(meter(left: 2.5, limit: 2.5).valueText, "$2.50")
        XCTAssertEqual(meter(left: 0.004, limit: 100).valueText, "$0")
        XCTAssertEqual(meter(left: 1_234, limit: 2_000).valueText, "$1.2K")
    }

    // MARK: - Helpers

    private func plansByProvider() throws -> [(ProviderKind, [String])] {
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let claude = ["pro", "max", "team", "enterprise"].flatMap { type in
            [nil, "default_claude_max_5x", "default_claude_max_20x"].compactMap {
                ClaudeUsageMapper.formatPlan(subscriptionType: type, rateLimitTier: $0)
            }
        }
        let codex = ["free", "plus", "pro", "prolite", "promax", "team", "business", "enterprise", "edu",
                     "self_serve_business_prolite"].compactMap(CodexUsageMapper.formatCodexPlan)
        let cursor = ["Free", "Pro", "Pro Plus", "Ultra", "Team", "Enterprise"].compactMap {
            CursorUsageMapper.resolvedPlanLabel(planInfoName: $0, membershipType: nil)
        }
        let antigravity = ["Antigravity Starter Quota", "Google AI Pro", "Google AI Ultra",
                           "Gemini Code Assist in Google One AI Pro"].compactMap(AntigravityUsageMapper.formatPlan)
            + AntigravityUsageMapper.paidTierPlans.values
        let copilot = try ["individual", "business", "enterprise", "free", "individual_pro"].compactMap {
            try CopilotUsageMapper.map(body: ["copilot_plan": $0, "token_based_billing": true]).plan
        }
        let grok = try ["SuperGrok", "SuperGrok Heavy", "X Premium+", "Free"].compactMap {
            GrokUsageMapper.planName(from: HTTPResponse(statusCode: 200, headers: [:], body: try json(["subscription_tier_display": $0])))
        }
        let ollama = try ["free", "pro", "max"].compactMap { OllamaUsageMapper.plan(from: try json(["plan": $0])) }
        let openRouter = [true, false].compactMap { OpenRouterUsageMapper.keyMetrics(from: ["is_free_tier": $0]).plan }
        let zai = try ["GLM Coding Lite", "GLM Coding Pro", "GLM Coding Max"].compactMap {
            ZAIUsageMapper.planName(from: try json(["data": [["productName": $0]]]))
        }
        XCTAssertEqual(antigravity.first, "Antigravity Starter Quota")
        XCTAssertEqual(openRouter, ["Free", "Pay-as-you-go"])
        XCTAssertEqual(zai, ["GLM Coding Lite", "GLM Coding Pro", "GLM Coding Max"])
        return [(.claude, claude), (.codex, codex), (.cursor, cursor), (.antigravity, antigravity), (.copilot, copilot),
                (.grok, grok), (.ollama, ollama), (.opencodeGo, [OpenCodeUsageMapper.plan]), (.openrouter, openRouter),
                (.zai, zai)]
    }

    private func account(_ kind: ProviderKind, _ name: String) -> DashboardAccount {
        DashboardAccount(provider: Provider(id: "\(kind.rawValue)@1", displayName: kind.displayName,
                                            icon: kind.rawValue, accountLabel: name), lines: [])
    }

    private func meter(left: Double, limit: Double) -> WidgetData {
        var data = WidgetData(title: "On-demand", kind: .dollars, used: limit - left, limit: limit)
        data.displayMode = .remaining
        return data
    }

    /// The width a view asks for when nothing constrains it.
    private func idealWidth(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.fixedSize().environment(AccountRenameStore?.none)).fittingSize.width
    }
}

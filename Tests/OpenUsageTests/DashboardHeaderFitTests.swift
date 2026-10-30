import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardHeaderFitTests: QuietWindowTestCase {
    private let width = DashboardGrid.cardWidth - 2 * DashboardGrid.cardPadding

    func testRobinsCaptionsFitWhole() async throws {
        let captions: [(ProviderKind, String, String)] = [
            (.grok, "rob@sunstory.com", "SuperGrok Heavy"), (.cursor, "rob@sunstory.com", "Ultra"),
            (.codex, "sam@hey.com", "Plus"), (.codex, "Sunstory", "Pro 200"), (.opencodeGo, "OpenCode", "Go"),
            (.claude, "Personal", "Max 20x"), (.ollama, "Ollama", "Free"), (.openrouter, "OpenRouter", "Pay-as-you-go"),
            (.claude, "Attention Machine 1", "Team 5x"), (.claude, "Attention Machine 2", "Team 5x"),
        ]
        let inset = DashboardGrid.inset
        let planEnd = width - inset
        for (kind, name, plan) in captions {
            let label = "\(name) · \(plan)"
            let account = account(kind, name)

            let warned = DashboardAccountCaption(account: account, plan: plan, status: AccountStatus(notice: "Refresh failed"))
            let asked = NSHostingView(rootView: warned.fixedSize().environment(AccountRenameStore?.none)).fittingSize.width
            XCTAssertLessThanOrEqual(asked, width, "\(label) asks \(asked) of \(width) pt")

            let nameAlone = try await ink(Text(name).font(DashboardGrid.captionFont).foregroundStyle(.secondary).fixedSize().padding(20))
            let planAlone = try await ink(Text(plan).font(DashboardGrid.planFont).foregroundStyle(.secondary).fixedSize().padding(20))
            let nameWidth = try XCTUnwrap(nameAlone.span()).width
            let planWidth = try XCTUnwrap(planAlone.span()).width
            let caption = try await ink(DashboardAccountCaption(account: account, plan: plan), width: width)
            XCTAssertEqual(CGFloat(caption.height) / caption.scale, DashboardGrid.captionHeight, accuracy: 1, label)

            let title = try XCTUnwrap(caption.span(from: 0, to: inset + nameWidth + 4), "\(label): no name drawn")
            XCTAssertEqual(title.first, inset, accuracy: 1.5, "\(label): the name doesn't start at the caption's inset")
            XCTAssertEqual(title.last, inset + nameWidth, accuracy: 1.5, "\(label): the name is cut")
            let drawnPlan = try XCTUnwrap(caption.span(from: planEnd - planWidth - 2, to: planEnd + 2), "\(label): no plan drawn")
            XCTAssertEqual(drawnPlan.last, planEnd, accuracy: 1.5, "\(label): the plan doesn't end at the inset before the edge")
            XCTAssertEqual(drawnPlan.width, planWidth, accuracy: 1.5, "\(label): the plan is cut")
            XCTAssertLessThanOrEqual(title.last + DashboardGrid.columnGap, drawnPlan.first + 1, "\(label): the name runs into the plan")
            XCTAssertNil(caption.span(from: title.last + 1, to: drawnPlan.first - 1), "\(label): something sits between the name and the plan")
        }
    }

    func testAHubCaptionEndsWithTheHubMarkAtCapHeight() async throws {
        let planEnd = width - DashboardGrid.inset
        let capHeight = DashboardGrid.planNSFont.capHeight
        let space = (" " as NSString).size(withAttributes: [.font: DashboardGrid.planNSFont]).width
        let hub = DashboardAccount(provider: Provider(id: "claude@hub", kind: .claude, accountLabel: "Work", hubHost: "mini.example"), lines: [])
        let planAlone = try await ink(Text("Team 5x").font(DashboardGrid.planFont).foregroundStyle(.secondary).fixedSize().padding(20))
        let planWidth = try XCTUnwrap(planAlone.span()).width

        let markOnly = try await ink(DashboardAccountCaption(account: hub), width: width)
        let lone = try XCTUnwrap(markOnly.span(from: planEnd - 3 * capHeight, to: planEnd + 2), "no hub mark drawn without a plan")
        XCTAssertEqual(lone.last, planEnd, accuracy: 1.5, "the hub mark doesn't end at the inset before the edge")
        XCTAssertEqual(lone.width, capHeight, accuracy: 1.5, "the hub mark isn't the plan's cap height wide")

        let caption = try await ink(DashboardAccountCaption(account: hub, plan: "Team 5x"), width: width)
        let tail = try XCTUnwrap(caption.span(from: planEnd - planWidth - space - capHeight - 6, to: planEnd + 2), "no plan drawn")
        XCTAssertEqual(tail.last, planEnd, accuracy: 1.5, "the hub mark doesn't end at the inset before the edge")
        let mark = try XCTUnwrap(caption.span(from: planEnd - capHeight - 1, to: planEnd + 2))
        let plan = try XCTUnwrap(caption.span(from: tail.first, to: mark.first - 1), "no plan before the hub mark")
        XCTAssertEqual(plan.width, planWidth, accuracy: 1.5, "the plan is cut")
        XCTAssertEqual(mark.first - plan.last, space, accuracy: 1.5, "the plan and the hub mark aren't one space apart")
        let planRows = try XCTUnwrap(caption.rows(from: plan.first, to: plan.last))
        let markRows = try XCTUnwrap(caption.rows(from: mark.first, to: mark.last))
        XCTAssertEqual(markRows.width, capHeight, accuracy: 1, "the hub mark isn't the plan's cap height tall")
        XCTAssertEqual(markRows.last, planRows.last, accuracy: 1, "the hub mark doesn't sit on the plan's baseline")
    }

    private func account(_ kind: ProviderKind, _ name: String) -> DashboardAccount {
        DashboardAccount(provider: Provider(id: "\(kind.rawValue)@1", kind: kind, accountLabel: name), lines: [])
    }

    private func ink(_ content: some View, width: CGFloat? = nil) async throws -> InkMap {
        let view = content
            .frame(width: width)
            .background(Color.white)
            .environment(AccountRenameStore?.none)
            .environment(\.colorScheme, .light)
        let hosted = show(view, in: .borderless).host
        try await Task.sleep(for: .milliseconds(150))
        return InkMap(of: hosted, threshold: 40, background: .white)
    }
}

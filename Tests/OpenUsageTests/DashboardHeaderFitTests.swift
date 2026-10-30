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

    func testAHubCaptionMarksTheNameWithTheHubMarkAtCapHeight() async throws {
        let inset = DashboardGrid.inset
        let planEnd = width - inset
        let capHeight = DashboardGrid.planNSFont.capHeight
        let nameFont = NSFont.systemFont(ofSize: DashboardGrid.planNSFont.pointSize, weight: .semibold)
        let space = (" " as NSString).size(withAttributes: [.font: nameFont]).width
        func hub(_ name: String) -> DashboardAccount {
            DashboardAccount(provider: Provider(id: "claude@hub", kind: .claude, accountLabel: name, hubHost: "mini.example"), lines: [])
        }
        func inkWidth(_ text: String, _ font: Font) async throws -> CGFloat {
            let alone = try await ink(Text(text).font(font).foregroundStyle(.secondary).fixedSize().padding(20))
            return try XCTUnwrap(alone.span()).width
        }
        let nameWidth = try await inkWidth("Work", DashboardGrid.captionFont)
        let planWidth = try await inkWidth("Team 5x", DashboardGrid.planFont)

        let caption = try await ink(DashboardAccountCaption(account: hub("Work"), plan: "Team 5x"), width: width)
        let name = try XCTUnwrap(caption.span(from: 0, to: inset + nameWidth + 1), "no name drawn")
        XCTAssertEqual(name.width, nameWidth, accuracy: 1.5, "the name is cut")
        let mark = try XCTUnwrap(caption.span(from: name.last + 1, to: name.last + space + capHeight + 2), "no hub mark after the name")
        XCTAssertEqual(mark.first - name.last, space, accuracy: 1.5, "the name and the hub mark aren't one space apart")
        XCTAssertEqual(mark.width, capHeight, accuracy: 1.5, "the hub mark isn't the name's cap height wide")
        let nameRows = try XCTUnwrap(caption.rows(from: name.first, to: name.last))
        let markRows = try XCTUnwrap(caption.rows(from: mark.first, to: mark.last))
        XCTAssertEqual(markRows.width, capHeight, accuracy: 1, "the hub mark isn't the name's cap height tall")
        XCTAssertEqual(markRows.last, nameRows.last, accuracy: 1, "the hub mark doesn't sit on the name's baseline")
        let plan = try XCTUnwrap(caption.span(from: planEnd - planWidth - 2, to: planEnd + 2), "no plan drawn")
        XCTAssertEqual(plan.last, planEnd, accuracy: 1.5, "the plan doesn't end at the inset before the edge")
        XCTAssertEqual(plan.width, planWidth, accuracy: 1.5, "the plan is cut")
        XCTAssertNil(caption.span(from: mark.last + 1, to: plan.first - 1), "something sits between the hub mark and the plan")

        let bare = try await ink(DashboardAccountCaption(account: hub("Work")), width: width)
        XCTAssertNotNil(bare.span(from: name.last + 1, to: mark.last + 1), "no hub mark without a plan")
        XCTAssertNil(bare.span(from: mark.last + 1), "something sits in the plan's spot without a plan")

        let longName = "a-very-long-hub-login-address@example.com"
        let longPlanWidth = try await inkWidth("SuperGrok Heavy", DashboardGrid.planFont)
        let long = try await ink(DashboardAccountCaption(account: hub(longName), plan: "SuperGrok Heavy"), width: width)
        let longPlan = try XCTUnwrap(long.span(from: planEnd - longPlanWidth - 2, to: planEnd + 2), "no plan drawn beside a long name")
        XCTAssertEqual(longPlan.width, longPlanWidth, accuracy: 1.5, "the plan is cut beside a long name")
        let beforePlan = try XCTUnwrap(long.span(from: 0, to: longPlan.first - 1))
        let longMark = try XCTUnwrap(long.span(from: beforePlan.last - capHeight - 1, to: beforePlan.last + 0.5))
        let longMarkRows = try XCTUnwrap(long.rows(from: longMark.first, to: longMark.last))
        XCTAssertEqual(longMark.width, capHeight, accuracy: 1.5, "the hub mark is pushed off a truncated name")
        XCTAssertEqual(longMarkRows.width, capHeight, accuracy: 1, "the hub mark is pushed off a truncated name")
        XCTAssertNil(long.span(from: longMark.first - space + 1.5, to: longMark.first - 0.5), "the hub mark isn't one space after the truncated name")
        let fullNameWidth = (longName as NSString).size(withAttributes: [.font: nameFont]).width
        XCTAssertLessThan(longMark.first, inset + fullNameWidth, "the long name wasn't truncated")
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

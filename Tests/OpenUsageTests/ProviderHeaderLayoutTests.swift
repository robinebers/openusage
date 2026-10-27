import SwiftUI
import XCTest
@testable import OpenUsage

/// The provider's header and card, as drawn: the header is the logo and the provider's name, and every
/// account, one or several, is captioned in the card; the header's logo, every caption and every label
/// start 12 pt in, and every caption's plan ends where the reset column does; the heights are literal points; a row's columns sit at their fixed x.
@MainActor
final class ProviderHeaderLayoutTests: XCTestCase {
    /// The card: the panel minus its margin on each side.
    private let boxWidth = PanelMetrics.width - 2 * PanelMetrics.margin
    private let inset = DashboardGrid.cardPadding + DashboardGrid.inset

    private func claude(_ label: String?, _ id: String = "claude@1") -> Provider {
        Provider(id: id, displayName: "Claude", icon: "claude", accountLabel: label)
    }

    private func family(_ accounts: [Provider], lines: [DashboardLine] = []) -> DashboardFamily {
        DashboardFamily(id: "claude", provider: accounts[0], accounts: accounts.map { DashboardAccount(provider: $0, lines: lines) })
    }

    private func section(_ family: DashboardFamily, plans: [String: String] = [:]) -> DashboardProviderSection<DashboardAccountRows> {
        DashboardProviderSection(family: family) { account in
            DashboardAccountRows(account: account, plan: plans[account.id])
        }
    }

    private func line(_ data: WidgetData) -> DashboardLine {
        DashboardLine(descriptor: WidgetDescriptor(id: data.title, providerID: "p", metricLabel: data.title, sample: data), data: data)
    }

    private func percent(_ title: String, used: Double, resetsIn: TimeInterval? = nil) -> WidgetData {
        var data = WidgetData(title: title, icon: "claude", kind: .percent, used: used, limit: 100)
        data.displayMode = .remaining
        data.resetsAt = resetsIn.map { Date().addingTimeInterval($0) }
        return data
    }

    /// Robin: "always show it as if they had multiple accounts". The header is the logo, 12 pt in and as
    /// tall as the line, then the provider's name 8 pt after it, centred on the logo, and nothing else:
    /// no account name, no status, no plan, over a sole account as over several.
    func testTheHeaderIsTheLogoAndTheProvidersNameAlone() throws {
        let sole = section(family([claude("Sunstory")]), plans: ["claude@1": "Pro 200"])
        let bitmap = try Bitmap(sole.header, width: boxWidth, scale: 2)
        XCTAssertEqual(CGFloat(bitmap.height) / bitmap.scale, DashboardGrid.headerHeight)
        let logoStart = inset
        let logoEnd = logoStart + DashboardGrid.iconSize
        let nameStart = logoEnd + DashboardGrid.columnGap
        let nameAlone = try XCTUnwrap(Bitmap(Text("Claude").font(DashboardGrid.headerFont).fixedSize().padding(20), width: 120, scale: 2).inkSpan())

        let logo = try XCTUnwrap(bitmap.inkSpan(from: 0, to: logoEnd + 2), "no logo drawn")
        XCTAssertEqual(logo.first, logoStart, accuracy: 1.5, "the logo doesn't start 12 pt in")
        XCTAssertEqual(logo.last, logoEnd, accuracy: 1.5, "the logo isn't as wide as the line is tall")
        XCTAssertNil(bitmap.inkSpan(from: logoEnd + 1, to: nameStart - 1), "something sits between the logo and the name")

        let title = try XCTUnwrap(bitmap.inkSpan(from: nameStart - 1, to: boxWidth), "no name drawn")
        XCTAssertEqual(title.first, nameStart, accuracy: 1.5, "the name doesn't start 8 pt after the logo")
        XCTAssertEqual(title.last - title.first, nameAlone.last - nameAlone.first, accuracy: 1.5, "the header draws more than the provider's name")

        let nameRows = try XCTUnwrap(bitmap.inkRows(from: nameStart, to: title.last))
        let logoRows = try XCTUnwrap(bitmap.inkRows(from: logoStart, to: logoEnd))
        XCTAssertEqual((nameRows.first + nameRows.last) / 2, (logoRows.first + logoRows.last) / 2, accuracy: 2, "the name isn't centred on the logo")
    }

    /// Every header reads the provider's name, whatever its accounts are called and however many there
    /// are: drawn in the same place and font, a header over "Attention Machine", "Claude", an unnamed
    /// account, an email or two accounts ends at the same x.
    func testEveryHeaderReadsTheProviderWhateverItsAccounts() throws {
        func titleEnd(_ accounts: [Provider]) throws -> CGFloat {
            let bitmap = try Bitmap(section(family(accounts)).header, width: boxWidth, scale: 2)
            return try XCTUnwrap(bitmap.inkSpan(from: 0, to: boxWidth)).last
        }
        let providerAlone = try titleEnd([claude("Attention Machine"), claude("Home", "claude@2")])
        for name in ["Attention Machine", "Claude", nil, "sam@hey.com"] {
            XCTAssertEqual(try titleEnd([claude(name)]), providerAlone, accuracy: 0.5, name ?? "unnamed")
        }
    }

    /// Every account is captioned with its name and plan over its rows, a sole account named like its
    /// provider (Robin's OpenCode card) or by its email as much as each of several; the header never
    /// carries a plan.
    func testEveryAccountIsCaptionedWithItsPlanWhateverTheirNumber() throws {
        let rows = [line(percent("Session", used: 8)), line(percent("Weekly", used: 81))]
        let planArea = (boxWidth / 2, boxWidth)
        for name in ["Claude", "rob@sunstory.com"] {
            let sole = section(family([claude(name)], lines: rows), plans: ["claude@1": "Max 20x"])
            let bands = try Bitmap(sole, width: boxWidth, scale: 2).inkBands()
            XCTAssertEqual(bands.count, 4, "\(name): a header, a caption and two rows")
            XCTAssertEqual(bands[1].last, boxWidth - inset, accuracy: 1.5, "\(name): the caption's plan doesn't end where the reset column does")
            XCTAssertEqual(try Bitmap(sole, width: boxWidth).height, 90, "\(name): a header and a card of a caption and two rows")
            XCTAssertNil(try Bitmap(sole.header, width: boxWidth, scale: 2).inkSpan(from: planArea.0, to: planArea.1), "\(name): the plan is on the header")
        }

        let several = section(family([claude("Personal"), claude("Work", "claude@2")], lines: rows), plans: ["claude@1": "Max 20x", "claude@2": "Max 5x"])
        XCTAssertEqual(try Bitmap(several, width: boxWidth).inkBands().count, 7, "a header, then a caption and two rows per account")
        XCTAssertNil(try Bitmap(several.header, width: boxWidth, scale: 2).inkSpan(from: planArea.0, to: planArea.1), "the plan is on the header over several accounts")
    }

    /// The header's logo, each caption and each label start 12 pt in from the card's edge, and the
    /// header's name 8 pt after the logo; the plan on a caption and the reset column end 12 pt before
    /// the edge. A sole account lines up the same way.
    func testTheLogoSharesTheLabelsLeadingEdgeAndThePlansEndWithTheResets() throws {
        let session = line(percent("Session", used: 0, resetsIn: 3 * 3600))
        let two = family([claude("Personal"), claude("Work", "claude@2")], lines: [session, line(percent("Weekly", used: 24, resetsIn: 86_400))])
        let bands = try Bitmap(section(two, plans: ["claude@1": "Max 5x", "claude@2": "Max 5x"]), width: boxWidth, scale: 2).inkBands()
        XCTAssertEqual(bands.count, 7, "the header, then a caption and two rows per account")
        let edges = bands.map(\.first)
        XCTAssertLessThanOrEqual((edges.max() ?? 0) - (edges.min() ?? 0), 1.5, "leading edges \(edges)")
        XCTAssertEqual(edges.min() ?? 0, inset, accuracy: 1.5)
        XCTAssertEqual(bands[2].last, boxWidth - inset, accuracy: 1.5, "the reset ends 12 pt before the edge")
        XCTAssertEqual(bands[1].last, bands[2].last, accuracy: 1.5, "the caption's plan ends where the reset does")
        let name = try XCTUnwrap(Bitmap(section(two).header, width: boxWidth, scale: 2).inkSpan(from: inset + DashboardGrid.iconSize + 1, to: boxWidth))
        XCTAssertEqual(name.first, inset + DashboardGrid.iconSize + DashboardGrid.columnGap, accuracy: 1.5, "the name doesn't start 8 pt after the logo")
        let sole = family([claude("Personal")], lines: [session])
        let soleBands = try Bitmap(section(sole, plans: ["claude@1": "Max 20x"]), width: boxWidth, scale: 2).inkBands()
        XCTAssertEqual(soleBands.count, 3, "the header, the caption, then one row")
        XCTAssertLessThanOrEqual(soleBands.map(\.first).max()! - soleBands.map(\.first).min()!, 1.5, "a sole account's edges \(soleBands.map(\.first))")
        XCTAssertEqual(soleBands[1].last, soleBands[2].last, accuracy: 1.5, "a sole account's plan doesn't end where the reset does")
    }

    /// Robin: "Everything takes too much space." The steps are pinned in literal points, so changing any
    /// fails here: a 16 pt header (one Headline line), 4 to the card, 8 inside it, 14 per caption (one
    /// Subheadline line), 20 per row, 16 between accounts, 16 between providers.
    func testSectionsKeepTheirHeights() throws {
        let rows = ["Session", "Weekly", "Fable"].map { line(percent($0, used: 30)) }
        let one = family([claude("Work")], lines: rows)
        XCTAssertEqual(try Bitmap(section(one), width: boxWidth).height, 110, "a header and a card of a caption and three rows")
        let two = family([claude("Personal"), claude("Work", "claude@2")], lines: Array(rows.prefix(2)))
        XCTAssertEqual(try Bitmap(section(two), width: boxWidth).height, 160, "two accounts, each a caption and two rows")
        XCTAssertEqual(DashboardGrid.sectionSpacing, 16)
        XCTAssertEqual(DashboardGrid.headerHeight, DashboardGrid.lineHeight(.preferredFont(forTextStyle: .headline)))
        XCTAssertEqual(DashboardGrid.captionHeight, DashboardGrid.lineHeight(.preferredFont(forTextStyle: .subheadline)))
        XCTAssertEqual(DashboardGrid.iconSize, DashboardGrid.headerHeight, "the logo isn't as tall as the header's line")
    }

    /// A row at rest shows every column in its fixed place: the bar starts 8 pt after the 86 pt label
    /// column and fills its slot, the value is right-aligned in its 52 pt column, the reset in its 56 pt
    /// column ending 12 pt before the card's edge. A row without a limit shows its value where the bar
    /// would start, at its natural width.
    func testARowShowsItsBarValueAndResetInTheirColumns() throws {
        let end = boxWidth - inset
        let barStart = inset + DashboardGrid.labelWidth + DashboardGrid.columnGap
        let resetStart = end - DashboardGrid.resetWidth
        let valueStart = resetStart - DashboardGrid.columnGap - DashboardGrid.valueWidth
        let barEnd = valueStart - DashboardGrid.columnGap
        let full = percent("Weekly", used: 0, resetsIn: 5 * 3600)
        var credits = WidgetData(title: "Credits", icon: "codex", kind: .count, used: 452, limit: nil)
        credits.values = [MetricValue(number: 452, kind: .count, label: "credits")]
        func row(_ data: WidgetData) -> some View {
            DashboardMetricRow(model: data.dashboardRow()).padding(.horizontal, DashboardGrid.cardPadding)
        }

        let bitmap = try Bitmap(row(full), width: boxWidth, scale: 2)
        XCTAssertEqual(CGFloat(bitmap.height) / 2, DashboardGrid.rowHeight)
        let label = try XCTUnwrap(bitmap.inkSpan(from: 0, to: barStart - 2), "no label")
        XCTAssertEqual(label.first, inset, accuracy: 1.5)
        let bar = try XCTUnwrap(bitmap.inkSpan(from: barStart - 2, to: barEnd + 2), "no bar")
        XCTAssertEqual(bar.first, barStart, accuracy: 1.5, "the bar doesn't start after the label column")
        XCTAssertEqual(bar.last, barEnd, accuracy: 1.5, "the bar doesn't fill its slot")
        let value = try XCTUnwrap(bitmap.inkSpan(from: valueStart - 2, to: resetStart - 4), "no value at rest")
        XCTAssertEqual(value.last, valueStart + DashboardGrid.valueWidth, accuracy: 1.5, "the value isn't right-aligned in its column")
        let reset = try XCTUnwrap(bitmap.inkSpan(from: resetStart - 2, to: boxWidth), "no reset at rest")
        XCTAssertEqual(reset.last, end, accuracy: 1.5, "the reset isn't right-aligned at the card's inset")
        XCTAssertGreaterThan(reset.last - reset.first, 8, "the reset is empty")

        let plain = try Bitmap(row(credits), width: boxWidth, scale: 2)
        let drawn = try XCTUnwrap(plain.inkSpan(from: barStart - 2, to: boxWidth))
        let alone = try XCTUnwrap(Bitmap(Text("452 credits").font(DashboardMetricRow.font).monospacedDigit().fixedSize().padding(20), width: 200, scale: 2).inkSpan())
        XCTAssertEqual(drawn.first, barStart, accuracy: 1.5, "the value doesn't start where the bar would")
        XCTAssertEqual(drawn.last - drawn.first, alone.last - alone.first, accuracy: 1, "the value shrank")
    }

    /// A row running out shows the flame before its value, inside the value column, and nothing else
    /// moves: the label, the bar, the value's right edge and the reset sit where they do on a row at
    /// rest, and even the widest value, "100%", keeps the flame inside the column.
    func testTheFlameSitsInTheValueColumnAndMovesNothing() throws {
        let end = boxWidth - inset
        let resetStart = end - DashboardGrid.resetWidth
        let valueStart = resetStart - DashboardGrid.columnGap - DashboardGrid.valueWidth
        let barEnd = valueStart - DashboardGrid.columnGap
        func row(flame: Bool, value: String = "100%") -> some View {
            DashboardMetricRow(model: DashboardRowModel(label: "Weekly", mark: .bar(fill: 0.6, severity: flame ? .critical : .normal, value: value, reset: "3d 12h", flame: flame)))
                .padding(.horizontal, DashboardGrid.cardPadding)
        }
        let rest = try Bitmap(row(flame: false), width: boxWidth, scale: 2)
        let hot = try Bitmap(row(flame: true), width: boxWidth, scale: 2)
        for (name, from, to) in [("label", 0, valueStart - DashboardGrid.columnGap - 60), ("bar", valueStart - DashboardGrid.columnGap - 60, barEnd + 2), ("reset", resetStart - 2, boxWidth)] {
            let atRest = try XCTUnwrap(rest.inkSpan(from: from, to: to), "no \(name) at rest")
            let withFlame = try XCTUnwrap(hot.inkSpan(from: from, to: to), "no \(name) with the flame")
            XCTAssertEqual(withFlame.first, atRest.first, accuracy: 0.5, "the flame moved the \(name)")
            XCTAssertEqual(withFlame.last, atRest.last, accuracy: 0.5, "the flame moved the \(name)")
        }
        let restValue = try XCTUnwrap(rest.inkSpan(from: barEnd + 2, to: resetStart - 4))
        let hotValue = try XCTUnwrap(hot.inkSpan(from: barEnd + 2, to: resetStart - 4))
        XCTAssertEqual(hotValue.last, restValue.last, accuracy: 0.5, "the flame moved the value")
        XCTAssertLessThan(hotValue.first, restValue.first - 6, "no flame before the value")
        XCTAssertGreaterThanOrEqual(hotValue.first, valueStart - 0.5, "the flame runs out of the value column")
    }
}

/// A view rendered offscreen in light mode, as RGBA pixels with the top row first.
private struct Bitmap {
    struct Band {
        /// The x of the band's first and last ink, in points.
        let first: CGFloat
        let last: CGFloat
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    private var pixels: [UInt8]

    @MainActor
    init(_ content: some View, width: CGFloat, scale: CGFloat = 1) throws {
        let renderer = ImageRenderer(content: content
            .environment(\.hoverTooltipsDisabled, true)
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        self.width = image.width
        self.height = image.height
        self.scale = scale
        pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
    }

    subscript(x: Int, y: Int) -> (Int, Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    /// Ink is a pixel that differs clearly from its row's background, sampled 6 pt in from the leading
    /// edge, where only a card's rounded edge can be.
    private func isInk(_ x: Int, _ y: Int) -> Bool {
        let (p, q) = (self[x, y], self[Int(6 * scale), y])
        return max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2), abs(p.3 - q.3)) > 40
    }

    /// The first and last ink between two x positions in points (the whole width by default), or `nil`
    /// when there is none.
    func inkSpan(from start: CGFloat = 0, to end: CGFloat? = nil) -> Band? {
        let columns = max(0, Int(start * scale))..<min(width, end.map { Int($0 * scale) } ?? width)
        let inked = columns.filter { x in (0..<height).contains { isInk(x, $0) } }
        guard let first = inked.first, let last = inked.last else { return nil }
        return Band(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale)
    }

    /// The first and last ink row between two x positions, in points from the top.
    func inkRows(from start: CGFloat, to end: CGFloat) -> Band? {
        let columns = max(0, Int(start * scale))..<min(width, Int(end * scale))
        let inked = (0..<height).filter { y in columns.contains { isInk($0, y) } }
        guard let first = inked.first, let last = inked.last else { return nil }
        return Band(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale)
    }

    /// Each horizontal band of ink, top to bottom: a line of text, or the provider's mark. The 6 pt at
    /// either side hold only a grouped box's rounded edge, and so do bands under 4 pt tall, so neither
    /// counts.
    func inkBands() -> [Band] {
        let background = Int(6 * scale)
        var bands: [Band] = []
        var top: Int?
        var first = Int.max, last = Int.min
        for y in 0...height {
            let ink = y < height ? (background..<(width - background)).filter { isInk($0, y) } : []
            if let x = ink.first, let end = ink.last {
                top = top ?? y
                first = min(first, x)
                last = max(last, end)
            } else if let start = top {
                if CGFloat(y - start) >= 4 * scale {
                    bands.append(Band(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale))
                }
                top = nil
                first = .max
                last = .min
            }
        }
        return bands
    }
}

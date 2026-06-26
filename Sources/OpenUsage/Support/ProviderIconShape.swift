import SwiftUI

/// Where a tile/gallery icon comes from: a copied provider vector mark, or an SF Symbol.
enum IconSource: Hashable {
    case providerMark(String)   // provider id, e.g. "claude"
    case symbol(String)         // SF Symbol name
}

/// Renders an `IconSource` in monochrome (`Theme.iconGray`): on the glass popover, icon color
/// reads as noise (WWDC25 — monochrome reduces it), and provider identity comes from the name
/// beside the mark.
struct ProviderIcon: View {
    let source: IconSource
    /// Margin kept around a vector provider mark, forwarded to `ProviderIconShape`. Defaults to the
    /// breathing-room value used in list contexts (e.g. Settings); callers that want the mark to
    /// fill its box — like the section header matching the menu-bar strip glyph — pass a smaller value.
    var inset: CGFloat = 0.14

    var body: some View {
        switch source {
        case .providerMark(let id):
            if let mark = ProviderMarks.mark(for: id) {
                ProviderIconShape(pathData: mark.path, inset: inset)
                    .fill(Theme.iconGray)
            } else {
                Image(systemName: ProviderMarks.symbolFallback(for: id))
                    .foregroundStyle(Theme.iconGray)
            }
        case .symbol(let name):
            Image(systemName: name)
                .foregroundStyle(Theme.iconGray)
        }
    }
}

/// A SwiftUI `Shape` built from an SVG path `d` string, scaled to fit the frame and centered.
///
/// It normalizes by the artwork's **true bounding box** (not the declared `viewBox`): some source SVGs
/// bake whitespace into their viewBox (Claude/Codex/Cursor sit ~10% inside a 100×100 box) while others
/// run edge-to-edge (Devin, Grok). Fitting the real path bounds gives every provider mark the same
/// optical weight, then a single shared `inset` adds consistent breathing room so none touch the edge.
struct ProviderIconShape: Shape {
    let pathData: String
    /// Fraction of the frame kept as margin on every side, so normalized marks have uniform padding.
    var inset: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.parse(pathData)
        let bounds = raw.cgPath.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return raw }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let dx = target.midX - bounds.midX * scale
        let dy = target.midY - bounds.midY * scale
        return raw
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// A provider vector mark: the combined SVG path data. `ProviderIconShape` normalizes by the path's
/// true bounding box, so the source `viewBox` isn't needed.
struct ProviderMark: Hashable {
    let path: String
}

/// Loads copied provider SVGs from the bundle and extracts their path data (cached).
@MainActor
enum ProviderMarks {
    private static var cache: [String: ProviderMark] = [:]
    private static var missing: Set<String> = []

    static func mark(for id: String) -> ProviderMark? {
        if let cached = cache[id] { return cached }
        if missing.contains(id) { return nil }
        guard
            let url = Bundle.openUsageResources.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            let d = extractD(text)
        else {
            missing.insert(id)
            return nil
        }
        let mark = ProviderMark(path: d)
        cache[id] = mark
        return mark
    }

    static func symbolFallback(for id: String) -> String {
        switch id {
        case "antigravity": return "paperplane"
        case "claude": return "sparkle"
        case "codex": return "circle.hexagongrid"
        case "cursor": return "cube"
        case "grok": return "bolt.fill"
        default: return "app.dashed"
        }
    }

    private static func extractD(_ svg: String) -> String? {
        var values: [String] = []
        var searchStart = svg.startIndex
        while let start = svg[searchStart...].range(of: "d=\"") {
            let rest = svg[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            values.append(String(rest[..<end]))
            searchStart = end
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
}

/// Minimal SVG path parser supporting M/L/H/V/C/S/Q/T/Z (absolute + relative, implicit repeats).
/// Sufficient for the single-path provider marks; arcs (A) are not used by them.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var prevWasCubic = false
        var prevWasQuad = false

        func skipSeparators() {
            while i < n {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < n {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." && !sawDot {
                    sawDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        func reflected() -> CGPoint {
            guard let lc = lastControl else { return current }
            return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
        }

        while i < n {
            skipSeparators()
            if i >= n { break }

            if chars[i].isLetter {
                lastCommand = chars[i]
                i += 1
            }

            let cmd = lastCommand
            var failed = false
            var isCubic = false
            var isQuad = false

            switch cmd {
            case "M", "m":
                if let p = readPoint(relative: cmd == "m") {
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    lastCommand = (cmd == "m") ? "l" : "L"
                } else { failed = true }

            case "L", "l":
                if let p = readPoint(relative: cmd == "l") {
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "H", "h":
                if let x = readNumber() {
                    let nx = (cmd == "h") ? current.x + x : x
                    let p = CGPoint(x: nx, y: current.y)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "V", "v":
                if let y = readNumber() {
                    let ny = (cmd == "v") ? current.y + y : y
                    let p = CGPoint(x: current.x, y: ny)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "C", "c":
                if let c1 = readPoint(relative: cmd == "c"),
                   let c2 = readPoint(relative: cmd == "c"),
                   let end = readPoint(relative: cmd == "c") {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "S", "s":
                if let c2 = readPoint(relative: cmd == "s"),
                   let end = readPoint(relative: cmd == "s") {
                    let c1 = prevWasCubic ? reflected() : current
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "Q", "q":
                if let c = readPoint(relative: cmd == "q"),
                   let end = readPoint(relative: cmd == "q") {
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "T", "t":
                if let end = readPoint(relative: cmd == "t") {
                    let c = prevWasQuad ? reflected() : current
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                failed = true
            }

            if failed { break }
            prevWasCubic = isCubic
            prevWasQuad = isQuad
        }

        return path
    }
}

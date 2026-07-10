import Foundation

/// Minimal CSV parser supporting quoted fields with embedded commas, newlines, and escaped quotes
/// (`""` → `"`). Streams records keyed by the header row. Ported verbatim from
/// `../cursorcat/Sources/CursorCat/API/CSVParser.swift`.
enum CursorCSVParser {
    static func forEachRecord(in text: String, _ body: ([String: String]) -> Void) {
        var header: [String]?
        forEachRow(in: text) { row in
            guard let keys = header else {
                header = row
                return
            }

            var dict: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < row.count {
                dict[key] = row[i]
            }
            body(dict)
        }
    }

    private static func forEachRow(in text: String, _ body: ([String]) -> Void) {
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]

            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                        i = next
                        continue
                    }
                } else {
                    field.append(c)
                    i = text.index(after: i)
                    continue
                }
            }

            switch c {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                row.append(field)
                emit(row, body)
                row = []
                field = ""
            default:
                field.append(c)
            }
            i = text.index(after: i)
        }

        // Trailing partial row.
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            emit(row, body)
        }
    }

    private static func emit(_ row: [String], _ body: ([String]) -> Void) {
        if !row.allSatisfy(\.isEmpty) {
            body(row)
        }
    }
}

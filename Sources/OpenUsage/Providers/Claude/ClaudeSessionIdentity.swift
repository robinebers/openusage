import Foundation

/// Conflicting ownership must never be treated as an unattributed session.
enum ClaudeSessionIdentity: Equatable, Sendable {
    case owned(organizationID: String, accountID: String?)
    case unattributed
    case conflicted

    /// Search bounded byte ranges instead of materializing an array of every line. Even a huge
    /// single record checks cancellation each megabyte; complete records still cross chunk edges.
    static func parse(
        _ data: Data,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Self? {
        let newline = Data([UInt8(ascii: "\n")])
        let marker = Data(#""ownerOrganizationUuid""#.utf8)
        var owner: String?
        var account: String?
        var lineStart = data.startIndex
        var cursor = lineStart
        while cursor < data.endIndex {
            guard !isCancelled() else { return nil }
            let chunkEnd = min(cursor + 1_048_576, data.endIndex)
            while cursor < chunkEnd {
                let separator = data.range(of: newline, in: cursor..<chunkEnd)
                let end = separator?.lowerBound ?? chunkEnd
                cursor = separator?.upperBound ?? chunkEnd
                guard separator != nil || end == data.endIndex else { continue }
                let line = data[lineStart..<end]
                lineStart = cursor
                guard line.range(of: marker) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let value = object["ownerOrganizationUuid"] as? String, !value.isEmpty
                else { continue }
                let candidate = value.lowercased()
                if let owner, owner != candidate { return .conflicted }
                owner = candidate
                if let value = object["ownerAccountUuid"] as? String, !value.isEmpty {
                    let candidate = value.lowercased()
                    if let account, account != candidate { return .conflicted }
                    account = candidate
                }
            }
        }
        guard !isCancelled() else { return nil }
        return owner.map { .owned(organizationID: $0, accountID: account) } ?? .unattributed
    }
}

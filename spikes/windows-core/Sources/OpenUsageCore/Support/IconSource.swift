import Foundation

/// Platform-neutral icon reference (extracted from SwiftUI `ProviderIconShape.swift` for Windows spike).
enum IconSource: Hashable, Sendable {
    case providerMark(String)
    case symbol(String)
}

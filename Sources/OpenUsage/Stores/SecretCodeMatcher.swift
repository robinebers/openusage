import Foundation

/// One recognized key in the secret transparency code. A pure token so the matcher carries no AppKit
/// dependency and stays unit-testable by feeding tokens directly (the `NSEvent` → token mapping lives in
/// `TooMuchTransparencyKeyReader`, the event-source layer).
enum SecretCodeKey: Equatable, Sendable {
    case up, down, left, right, a, b
}

/// Matches the secret transparency code (↑ ↑ ↓ ↓ ← → ← → B A) from a stream of key tokens. Pure value
/// type, no UI.
///
/// Uses an overlapping sliding window: it keeps only the last N tokens and checks them against the
/// target, so a run of extra keys before a clean entry still matches and the user never has to "start
/// from empty". `accept` returns `true` exactly on the keystroke that completes the full sequence, then
/// clears its buffer so the next full entry matches again — which is what lets re-typing the code toggle
/// the easter egg back off.
struct SecretCodeMatcher {
    /// The canonical secret code.
    static let sequence: [SecretCodeKey] = [.up, .up, .down, .down, .left, .right, .left, .right, .b, .a]

    private let target: [SecretCodeKey]
    private var buffer: [SecretCodeKey] = []

    init(target: [SecretCodeKey] = SecretCodeMatcher.sequence) {
        self.target = target
    }

    /// Feed one token. Returns `true` when this token completes the full sequence.
    mutating func accept(_ token: SecretCodeKey) -> Bool {
        buffer.append(token)
        if buffer.count > target.count {
            buffer.removeFirst(buffer.count - target.count)
        }
        guard buffer == target else { return false }
        buffer.removeAll(keepingCapacity: true)
        return true
    }

    /// Drop any partial progress (e.g. when a non-sequence key breaks the run).
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

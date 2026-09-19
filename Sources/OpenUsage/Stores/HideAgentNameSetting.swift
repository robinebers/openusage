import Foundation

/// Whether provider card headers drop the agent prefix a multi-account provider repeats on every one
/// of its cards ("Claude: Acme (jane@example.com)" becomes "Acme (jane@example.com)"). Off by
/// default. The provider mark already says which agent a card belongs to, so with several accounts
/// signed in, the prefix costs header width that the account label needs more. Single-account
/// providers carry no prefix and are unaffected.
enum HideAgentNameSetting {
    static let key = "hideAgentNameInHeaders"
    static let fallback = false
}

import Foundation

/// Cleans up the organization name Claude reports for a personal account.
///
/// Anthropic names a personal organization after its owner, so the name comes back as
/// "jane@example.com's Organization". In a 320pt card header that suffix repeats nothing the address
/// doesn't already say, and it is what survives truncation while the address itself gets cut off. A
/// default-named organization is therefore shown as the address alone. A real team name ("Acme") is
/// never touched, and neither is a team whose name merely ends the same way, since only an
/// email-shaped owner counts as the generated form.
enum ClaudeOrganizationLabel {
    /// Both apostrophes: the API has been seen to use the typographic one.
    private static let suffixes = ["'s Organization", "\u{2019}s Organization"]

    static func collapsingDefaultName(_ organization: String) -> String {
        let trimmed = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in suffixes where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            let owner = String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEmailShaped(owner) else { continue }
            return owner
        }
        return organization
    }

    /// Deliberately narrow: one "@" with something either side and no spaces. A team called
    /// "Dave's Organization" keeps its name because "Dave" is not an address.
    private static func isEmailShaped(_ value: String) -> Bool {
        guard !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

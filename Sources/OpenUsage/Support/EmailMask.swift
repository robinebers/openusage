import Foundation

/// Masks email addresses in display text for Settings → Privacy → Hide Emails, in the same shape
/// Ghostex uses: the first and last characters before the `@` survive and every domain collapses to
/// one identical placeholder, so `jane@example.com` reads `j•••e@•••••.•••`. Two accounts on
/// different domains stay distinguishable by their visible letters, and no domain leaks at all.
///
/// One deliberate difference from Ghostex's matcher: an address is only the email-shaped run itself,
/// so punctuation around it survives. Provider names wrap emails in parentheses and possessives
/// ("Acme (jane@example.com)", "name@gmail.com's Organization"), and a greedy match would
/// swallow the closing parenthesis or the "'s" along with the domain.
enum EmailMask {
    static func mask(_ text: String) -> String {
        // Local part and a dotted domain, in any script. Brackets, quotes, and apostrophes are
        // excluded from both halves so they bound the match instead of joining it. Built per call:
        // `Regex` isn't `Sendable`, and a literal is compiled at build time, so this costs nothing.
        let pattern = /([\p{L}\p{N}._%+\-]+)@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)+/
        return text.replacing(pattern) { match in
            let local = match.output.1
            guard let first = local.first else { return String(match.output.0) }
            let last = local.count > 1 ? String(local.last!) : ""
            return "\(first)•••\(last)@•••••.•••"
        }
    }
}

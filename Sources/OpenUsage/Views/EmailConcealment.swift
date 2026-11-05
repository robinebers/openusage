import SwiftUI

extension EnvironmentValues {
    /// On while Hide From Screen Share sees a capture, and always on a copied card.
    @Entry var concealsEmails = false
}

extension View {
    /// Blurs the account's name in place when it is an email and \`concealsEmails\` is on.
    func concealingEmail(of provider: Provider) -> some View {
        modifier(EmailConcealment(isEmail: provider.isNamedByEmail))
    }
}

private struct EmailConcealment: ViewModifier {
    let isEmail: Bool
    @Environment(\.concealsEmails) private var concealsEmails

    func body(content: Content) -> some View {
        content.blur(radius: isEmail && concealsEmails ? 4 : 0)
    }
}

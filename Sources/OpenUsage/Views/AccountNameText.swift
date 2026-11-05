import SwiftUI

/// A fixed stand-in keeps the hidden name's characters and length out of the rendered view.
struct AccountNameText: View {
    let provider: Provider
    let privacyMode: Bool

    var body: some View {
        if privacyMode {
            PrivacyPlaceholderText(
                placeholder: "m7xq4p@r8n2k.dev",
                accessibilityLabel: PrivacyModeSetting.accountName(provider, isEnabled: true)
            )
        } else {
            Text(provider.accountName)
        }
    }
}

/// Both account and domain stand-ins use the same blur without drawing any saved private text.
struct PrivacyPlaceholderText: View {
    let placeholder: String
    let accessibilityLabel: String

    var body: some View {
        Text(verbatim: placeholder)
            .truncationMode(.tail)
            .blur(radius: 5)
            .textSelection(.disabled)
            .accessibilityLabel(accessibilityLabel)
    }
}

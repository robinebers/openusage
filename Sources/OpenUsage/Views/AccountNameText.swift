import SwiftUI

/// A fixed stand-in keeps the hidden name's characters and length out of the rendered view.
struct AccountNameText: View {
    let provider: Provider
    let privacyMode: Bool

    private let placeholder = "m7xq4p@r8n2k.dev"

    var body: some View {
        if privacyMode {
            Text(verbatim: placeholder)
                .truncationMode(.tail)
                .blur(radius: 5)
                .textSelection(.disabled)
                .accessibilityLabel(PrivacyModeSetting.accountName(provider, isEnabled: true))
        } else {
            Text(provider.accountName)
        }
    }
}

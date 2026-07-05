import SwiftUI

/// The centered source-note footer the hover popovers share (model breakdown, usage trend), so the
/// two panels can't drift apart in style.
struct PopoverSourceNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

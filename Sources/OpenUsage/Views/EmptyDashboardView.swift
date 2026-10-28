import AppKit
import SwiftUI

struct EmptyDashboardView: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text("Add an Account")
                .font(.system(size: 19, weight: .semibold))
                .padding(.bottom, 7)
            Text("Sign in to see your usage limits.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 230)
                .padding(.bottom, 20)

            Button(action: addAccount) {
                Label("Add Account", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .fixedSize(horizontal: false, vertical: true)
    }
}

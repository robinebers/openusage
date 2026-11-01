import AppKit
import SwiftUI

struct EmptyDashboardView: View {
    var defaults: UserDefaults = .standard
    let addAccount: () -> Void

    /// 0.7.x found accounts on its own, so an install it ran on opens here with nothing signed in. Every
    /// 0.7.x release stamps `openusage.settings.schemaVersion` at launch, and this build never writes it.
    var subtitle: String {
        defaults.object(forKey: "openusage.settings.schemaVersion") != nil
            ? "OpenUsage no longer reads other apps' sign-ins. Add your accounts again."
            : "Sign in to see your usage limits."
    }

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
            Text(subtitle)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .fixedSize(horizontal: false, vertical: true)
    }
}

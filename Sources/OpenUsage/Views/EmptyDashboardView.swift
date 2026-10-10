import AppKit
import SwiftUI

struct EmptyDashboardView: View {
    let chooseProviders: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text("Make It Yours")
                .font(.system(size: 19, weight: .semibold))
                .padding(.bottom, 7)
            Text("Bring your AI usage, limits, and spend together. Choose what goes on your dashboard.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 230)
                .padding(.bottom, 20)

            Button(action: chooseProviders) {
                Label("Choose Providers", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .onboardingPrimaryAction()
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
    }
}

import SwiftUI

struct UpdateBannerCard: View {
    @Environment(UpdaterController.self) private var updater
    let version: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("Update Available")
                    .font(.subheadline.weight(.semibold))
                Text("OpenUsage \(version) is ready to download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Update") { updater.checkForUpdates() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(Motion.spring) { updater.dismissAvailableUpdate() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .cardSurface()
    }
}

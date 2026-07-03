import SwiftUI

/// The "Update Available" banner at the top of the dashboard. Shows while a *scheduled* Sparkle check
/// has found a new version (`UpdaterController.availableUpdateVersion`): for a menu-bar (dockless)
/// app macOS keeps Sparkle's own alert window behind everything, so the popover carries the reminder
/// instead. The install button runs a user-initiated check, which Sparkle presents frontmost (its
/// window with release notes, download progress, and the install flow). The close button snoozes the
/// banner; the next scheduled check re-surfaces the update.
///
/// Same grouped content card as `CustomizeHintCard` (`cardSurface`), scrolling with the sections.
struct UpdateBannerCard: View {
    @Environment(UpdaterController.self) private var updater
    /// The found update's display version, e.g. "0.8.1".
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
                Button("Install Update") {
                    updater.installAvailableUpdate()
                }
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

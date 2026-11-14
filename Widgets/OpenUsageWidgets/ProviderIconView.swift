import AppKit
import SwiftUI

struct ProviderIconView: View {
    let iconID: String

    var body: some View {
        if let image = ProviderIconLoader.image(for: iconID) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private enum ProviderIconLoader {
    private static var cache: [String: NSImage] = [:]

    static func image(for iconID: String) -> NSImage? {
        if let image = cache[iconID] { return image }
        let url = Bundle.main.url(
            forResource: iconID,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) ?? Bundle.main.url(forResource: iconID, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[iconID] = image
        return image
    }
}

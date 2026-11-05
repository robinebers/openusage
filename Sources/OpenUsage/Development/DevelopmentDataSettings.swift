#if OPENUSAGE_DEVELOPMENT
import SwiftUI

struct DevelopmentDataSettings: View {
    @Environment(AppContainer.self) private var container
    @State private var mode = DevelopmentDataMode()

    var body: some View {
        if mode.isAvailable {
            Section {
                // Swift 6.3.3 crashes lowering the actor-isolated method reference as this setter.
                Toggle("Sample Data", isOn: Binding(
                    get: { mode.isOn },
                    set: { enabled in mode.setSampleData(enabled) }
                ))
                    .disabled(mode.isSwitching)
                if let demo = container.demo {
                    LabeledContent("Seed \(String(demo.seed))") {
                        Button("Reshuffle") { demo.reshuffle() }
                    }
                }
            } header: {
                Text("Development")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restarts in an isolated demo app with random sample accounts for every provider. Each launch draws a new seed.")
                        .foregroundStyle(.secondary)
                    if let errorMessage = mode.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Theme.notice)
                    }
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Marks the demo app's footer with the seed that reproduces its data.
struct DemoDataLabel: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        if let demo = container.demo {
            Text("Demo Data · \(String(demo.seed))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
#endif

#if OPENUSAGE_DEVELOPMENT
import SwiftUI

struct DevelopmentDataSettings: View {
    let mode: DevelopmentDataMode

    var body: some View {
        Section {
            Toggle("Sample Data", isOn: Binding(get: { mode.isOn }, set: mode.setSampleData))
                .disabled(mode.isSwitching)
        } header: {
            Text("Development")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restarts in an isolated demo app with sample accounts for every provider. Sample changes reset at each launch.")
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
#endif

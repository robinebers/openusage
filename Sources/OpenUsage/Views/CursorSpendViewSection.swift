import SwiftUI

/// The Cursor-only spend-view card in its Customize detail: picks which side of the usage export
/// the spend tiles (Today / Yesterday / Last 30 Days) and the Usage Trend aggregate — everything,
/// plan-included rows only, or billed API usage only. The bounded meters (Total / Auto / API
/// Usage %) always stay as Cursor reports them. Changing the view forces a refresh so the tiles
/// update immediately instead of waiting for the next pass.
struct CursorSpendViewSection: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(CursorSpendViewSetting.key) private var spendView = CursorSpendViewSetting.fallback

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Spend View")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                // Same row shape as a Settings row: label leading, popup picker trailing.
                HStack(spacing: 10) {
                    Text("Spend Tiles Show")
                    Spacer(minLength: 8)
                    Picker("", selection: $spendView) {
                        ForEach(CursorSpendViewSetting.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)
            }
            .cardSurface()
        }
        .onChange(of: spendView) {
            // The setting is read at refresh time, so force one for an immediate tile update.
            Task { await dataStore.refresh(providerID: "cursor", force: true) }
        }
    }
}

import SwiftUI
import WidgetKit

@main
struct OpenUsageWidgets: WidgetBundle {
    var body: some Widget {
        ProviderUsageWidget()
    }
}

struct ProviderUsageWidget: Widget {
    static let kind = "ProviderUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: ProviderWidgetConfiguration.self,
            provider: ProviderUsageTimelineProvider()
        ) { entry in
            ProviderUsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Provider Usage")
        .description("See current AI provider usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

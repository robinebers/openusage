// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenUsage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "OpenUsage", targets: ["OpenUsage"])
    ],
    dependencies: [
        // The de-facto standard recorder + global hotkey for Mac apps (System Settings-style field).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // In-app auto-updates (appcast + EdDSA-signed downloads). 2.8+ adds macOS 26 Tahoe support.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        // Anonymous, opt-out product analytics (official, MIT-licensed, first-party Swift SDK).
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.62.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenUsage",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/OpenUsage",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/model_manifest.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OpenUsageTests",
            dependencies: ["OpenUsage"],
            path: "Tests/OpenUsageTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)

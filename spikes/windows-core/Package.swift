// swift-tools-version: 6.2

import PackageDescription



let package = Package(

    name: "OpenUsageCore",

    platforms: [

        .macOS(.v15)

    ],

    products: [

        .library(name: "OpenUsageCore", targets: ["OpenUsageCore"]),

        .executable(name: "e2e-harness", targets: ["e2e-harness"]),

        .executable(name: "sidecar", targets: ["sidecar"])

    ],

    dependencies: [

        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0")

    ],

    targets: [

        .target(

            name: "Win32Shim",

            path: "Sources/Win32Shim",

            publicHeadersPath: "include",

            cSettings: [

                .define("WIN32_LEAN_AND_MEAN")

            ],

            linkerSettings: [

                .linkedLibrary("advapi32", .when(platforms: [.windows])),

                .linkedLibrary("kernel32", .when(platforms: [.windows]))

            ]

        ),

        .target(

            name: "OpenUsageCore",

            dependencies: [

                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows])),

                .target(name: "Win32Shim", condition: .when(platforms: [.windows]))

            ],

            path: "Sources/OpenUsageCore",

            resources: [

                .copy("Resources/pricing_supplement.json"),

                .copy("Resources/pricing_litellm_snapshot.json"),

                .copy("Resources/pricing_models_dev_snapshot.json")

            ],

            swiftSettings: [

                .swiftLanguageMode(.v6)

            ]

        ),

        .executableTarget(

            name: "e2e-harness",

            dependencies: ["OpenUsageCore"],

            path: "Sources/e2e-harness",

            swiftSettings: [

                .swiftLanguageMode(.v6)

            ]

        ),

        .executableTarget(

            name: "sidecar",

            dependencies: ["OpenUsageCore", "Win32Shim"],

            path: "Sources/sidecar",

            swiftSettings: [

                .swiftLanguageMode(.v6)

            ]

        ),

        .testTarget(

            name: "OpenUsageCoreTests",

            dependencies: ["OpenUsageCore"],

            path: "Tests/OpenUsageCoreTests",

            swiftSettings: [

                .swiftLanguageMode(.v6)

            ]

        )

    ]

)


// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokIslandCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GrokIslandCore", targets: ["GrokIslandCore"])
    ],
    dependencies: [
        // Combine is Apple-only. On non-Apple platforms (e.g. Linux CI / Cloud
        // Agents) OpenCombine provides ObservableObject/@Published so the core
        // library and its tests can build and run. It is linked only where
        // Combine is unavailable (see the target dependency condition below).
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0")
    ],
    targets: [
        .target(
            name: "GrokIslandCore",
            dependencies: [
                .product(
                    name: "OpenCombine",
                    package: "OpenCombine",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi])
                )
            ],
            path: "GrokIsland",
            exclude: [
                "GrokIslandApp.swift",
                "IslandPanel.swift",
                "ShellView.swift",
                "IslandChrome.swift",
                "DesktopShortcut.swift",
                "PageCapture.swift",
                "ActivityViews.swift",
                "GrokViews.swift",
                "Info.plist",
                "GrokIsland.entitlements",
                "Assets.xcassets"
            ]
        ),
        .testTarget(
            name: "GrokIslandCoreTests",
            dependencies: ["GrokIslandCore"],
            path: "Tests/GrokIslandCoreTests"
        )
    ]
)

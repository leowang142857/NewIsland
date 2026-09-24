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
    targets: [
        .target(
            name: "GrokIslandCore",
            path: "GrokIsland",
            exclude: [
                "GrokIslandApp.swift",
                "IslandPanel.swift",
                "ShellView.swift",
                "CyberCodeRain.swift",
                "DesktopShortcut.swift",
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

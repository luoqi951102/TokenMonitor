// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    defaultLocalization: "zh",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenMonitor", targets: ["TokenMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "TokenMonitor",
            path: "Sources/TokenMonitor",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .unsafeFlags(["-lsqlite3"])
            ]
        ),
        .executableTarget(
            name: "WidgetSupport",
            dependencies: [],
            path: "Sources/WidgetSupport",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Foundation")
            ]
        )
    ]
)

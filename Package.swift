// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iStats",
            path: "Sources/iStats",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)

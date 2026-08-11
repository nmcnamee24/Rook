// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RookCore",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RookCore", targets: ["RookCore"]),
        .library(name: "RookKit", targets: ["RookKit"]),
    ],
    targets: [
        .target(
            name: "RookKit",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "RookCore",
            dependencies: ["RookKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("Speech"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "RookKitTests",
            dependencies: ["RookKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

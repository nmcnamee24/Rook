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
        .linkedFramework("Network"),
        .linkedFramework("Security"),
      ]
    ),
    .executableTarget(
      name: "RookCore",
      dependencies: ["RookKit"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreLocation"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOKit"),
        .linkedFramework("Network"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Security"),
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

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "RookCore",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "RookCore", targets: ["RookCore"]),
    .executable(name: "RookWakeRecorder", targets: ["RookWakeRecorder"]),
    .executable(name: "RookWakeTool", targets: ["RookWakeTool"]),
    .library(name: "RookKit", targets: ["RookKit"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/livekit/livekit-wakeword",
      revision: "95448a7559c453fcd87645bd67b247ffb45f85b0"
    ),
    .package(
      url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
      exact: "1.24.2"
    ),
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.15.3"
    ),
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
      dependencies: [
        "RookKit",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
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
    .executableTarget(
      name: "RookWakeRecorder",
      linkerSettings: [
        .linkedFramework("AVFoundation")
      ]
    ),
    .executableTarget(
      name: "RookWakeTool",
      dependencies: [
        "RookKit",
        .product(name: "LiveKitWakeWord", package: "livekit-wakeword"),
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
      ]
    ),
    .testTarget(
      name: "RookKitTests",
      dependencies: ["RookKit"]
    ),
  ],
  swiftLanguageModes: [.v5]
)

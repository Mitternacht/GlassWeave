// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassWeave",
    platforms: [
        // iOS/iPadOS 26 is the first presentation target. macOS 26 is a
        // core-compilation target only; it does not imply a macOS UI adapter.
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "GlassWeave", targets: ["GlassWeave"]),
        .library(name: "GlassWeaveUIKit", targets: ["GlassWeaveUIKit"]),
    ],
    targets: [
        // CPU/GPU record layouts shared by Swift and Metal shaders. C only;
        // the header is the single definition of every uploaded record.
        .target(name: "GlassWeaveShaderTypes"),
        // Core: Metal, simd, and os only. Must not import UIKit or SwiftUI.
        // Shaders live in Sources/GlassWeave/Shaders and are compiled by Xcode
        // into the target's default.metallib.
        .target(name: "GlassWeave", dependencies: ["GlassWeaveShaderTypes"]),
        // UIKit presentation. Every file is guarded by `#if canImport(UIKit)`
        // so the macOS core build still compiles the package.
        .target(name: "GlassWeaveUIKit", dependencies: ["GlassWeave"]),
        .testTarget(
            name: "GlassWeaveTests",
            dependencies: ["GlassWeave", "GlassWeaveShaderTypes"]
        ),
        .testTarget(
            name: "GlassWeaveUIKitTests",
            dependencies: ["GlassWeaveUIKit", "GlassWeave"]
        ),
        // GW-09's fixed workload rendered offscreen and measured with
        // RenderMetrics. Uses no `@testable` import, so the
        // GlassWeaveCharacterization scheme can run it in Release without
        // Metal API Validation; its shader is a copy of the laboratory's
        // ProceduralBackground.metal (CI checks they stay identical).
        .testTarget(
            name: "GlassWeaveCharacterizationTests",
            dependencies: ["GlassWeave"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

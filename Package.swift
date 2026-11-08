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
    ],
    targets: [
        // Core: Metal and simd only. Must not import UIKit or SwiftUI.
        .target(name: "GlassWeave"),
    ],
    swiftLanguageModes: [.v6]
)

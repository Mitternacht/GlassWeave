// swift-tools-version: 6.2
import PackageDescription

// A clean consumer of GlassWeave (GW-10): it resolves the package from a git
// URL at one revision and uses only its public products. The URL and the
// revision come from the environment so that the check pins exactly the
// commit under test; scripts/consumer_check.sh sets both.
guard let url = Context.environment["GLASSWEAVE_URL"], let revision = Context.environment["GLASSWEAVE_REVISION"] else {
    fatalError("Set GLASSWEAVE_URL and GLASSWEAVE_REVISION to the GlassWeave repository and commit to check; scripts/consumer_check.sh sets both.")
}
// SwiftPM names a URL dependency after the last path component of its URL,
// which for a local clone is the clone's directory name.
let dependencyName = url.split(separator: "/").last.map { name in
    name.hasSuffix(".git") ? String(name.dropLast(4)) : String(name)
} ?? "GlassWeave"

let package = Package(
    name: "GlassWeaveConsumer",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ConsumerKit", targets: ["ConsumerKit"]),
    ],
    dependencies: [
        .package(url: url, revision: revision),
    ],
    targets: [
        .target(
            name: "ConsumerKit",
            dependencies: [
                .product(name: "GlassWeave", package: dependencyName),
                .product(name: "GlassWeaveUIKit", package: dependencyName),
            ]
        ),
        .testTarget(name: "ConsumerKitTests", dependencies: ["ConsumerKit"]),
    ],
    swiftLanguageModes: [.v6]
)

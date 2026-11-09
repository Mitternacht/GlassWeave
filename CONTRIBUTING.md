# Contributing to GlassWeave

GlassWeave is in early development: the `implement/milestone-1` branch holds the v0.1
pre-alpha candidate (package, UIKit laboratory, tests, CI), unreleased and not measured on
a physical device. Start with [HANDOFF.md](HANDOFF.md), read the
[plan](tasks/plan.md), and use the [ordered backlog](tasks/todo.md) as the source of
implementation tasks. Review the relevant [architecture](docs/architecture.md) contracts
before adding behavior.

## Work in verifiable slices

Keep changes focused on one useful outcome. Define behavior before adding a public API;
do not publish placeholder protocols or methods that silently do nothing. Add focused
Swift Testing coverage with the first testable behavior. Use XCTest where UI automation
or performance measurement requires it. Keep the package building between slices once
it exists.

For visual changes, include a small reproducible example, reference captures, and the
device/OS used. Follow the [validation protocol](docs/validation.md) for GPU correctness,
frame pacing, resource lifetime, energy, and accessibility work. Simulator checks are
useful for integration and are not evidence of physical-device performance.

## Implementation setup

The package uses Swift tools 6.2 and Swift 6 language mode with iOS/iPadOS 26 and
macOS 26 deployment floors (declared; only the 27.2 runtimes have been run). Open
`Examples/GlassWeave.xcworkspace`, which contains the package and the laboratory. Native
UI work targets iOS/iPadOS; the macOS core build does not imply a macOS UI adapter.

Coding agents must follow [AGENTS.md](AGENTS.md): load the matching installed Apple
Xcode 27 skill and use the native Xcode MCP server for Apple project edits, documentation,
builds, diagnostics, previews, runs, and tests. Human contributors may use Xcode directly.

## Continuous integration

`.github/workflows/build.yml` selects Xcode 27.2 on `macos-26` and builds the package
(macOS Debug and Release, iOS Simulator Release), runs the package tests on macOS with
Metal API Validation, builds the package and laboratory tests for the iOS Simulator, runs
the clean-consumer check, and checks the documentation examples, the characterization
shader copy, and that no source blocks on GPU work. It has not run on GitHub yet. Do not
add tests that merely prove an empty module compiles.

Use read-only workflow permissions, pinned action revisions, and `pull_request` for
contributor builds. Avoid signing credentials for package-only checks. Keep physical
device validation separate from simulator build results.

Apple documents `xcodebuild` for external CI in its
[Swift package CI guidance](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows).
Verify toolchain availability against the
[official runner image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
when implementing CI; the installed default can change.

## Pull requests and releases

Explain the problem, the resulting behavior, and checks actually performed. Update the
backlog and relevant docs in the same change. Public API changes need a compatibility
note; rendering or performance claims need evidence. Do not weaken existing checks to
make a change pass.

`main` contains the planning documents until the `implement/milestone-1` branch is
merged. There is no release tag. The first release
follows its roadmap acceptance gates, includes a changelog and usable example, and is
tagged with a semantic version. Contributions are made under the repository's
[MIT license](LICENSE).

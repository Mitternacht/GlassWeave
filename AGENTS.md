# Agent instructions

## Project state and scope

GlassWeave is an Apple-native framework in early development. The
`implement/milestone-1` branch holds the v0.1 pre-alpha candidate: the Swift package
(`GlassWeave`, `GlassWeaveUIKit`), the UIKit laboratory app, Swift Testing and XCTest
suites, the clean-consumer check, and a CI workflow that has not run on GitHub yet.
Nothing is released, and no physical device has been measured. `tasks/todo.md` is the
only completion checklist; it records which acceptance items are verified and why the
others are open. Read `HANDOFF.md`, `README.md`, `tasks/plan.md`, `tasks/todo.md`, and
the relevant architecture section before implementation. The branch `implement/glass-beyond` adds the experimental GW-21 to GW-29 effects; they are
unreleased and unmeasured on devices, as are GW-12 (touch response), GW-13 (merging two
custom surfaces) and GW-15 (the optional `GlassWeaveSwiftUI` product), now built on the
same branch, as is GW-11 (a package-level Metal 4 submission experiment that no host
uses: the recorded decision keeps conventional Metal as the only shipped backend). Do not
treat planned tasks (GW-16), their APIs and examples, or provisional performance budgets
as existing functionality. Distinguish implemented behavior from planned capabilities in
documentation and reports.

Work on small, unblocked slices. Preserve existing work and unchecked tasks. Update
acceptance evidence as work completes. Do not expose speculative APIs, return fake
success, introduce no-op implementations, or add tests of an empty scaffold.

## Apple tools and skills

For every Apple-platform task, load the matching installed Xcode 27 skill first and use
the native Xcode MCP server, started with `xcrun mcpbridge`, for project edits,
documentation search, builds, runs, tests, previews, and diagnostics. Use both every time.
Apple's skill guidance supersedes prior model knowledge. After updating Xcode, refresh
the installed skill copies from `xcrun agent plugin path --plugin-format codex`.

The package exists (GW-01). In Xcode, open only `Examples/GlassWeave.xcworkspace`,
which contains the package and the laboratory; opening the package folder or the
laboratory project on its own leaves a stale package root behind in the native bridge.
If a required tool is unavailable, report the concrete limitation rather than claiming
that a build or runtime check passed.

## Architecture rules

- Keep the rendering core independent of SwiftUI and native view update frequency.
- Preserve native controls, hit testing, text, and accessibility where possible.
- Keep background texture provenance, ownership, color handling, and GPU synchronization explicit.
- Detect capabilities at runtime; do not equate OS availability with Metal 4 support.
- Keep the two repositories independently usable. Extract shared infrastructure only
  after real implementations demonstrate a need, with no glass-to-scene dependency.
- Use public Apple APIs. Do not promise native/custom optical merging or arbitrary
  backdrop capture without a documented and validated public mechanism.

## Validation and handoff

Build with the native Xcode tools after Apple source changes. Add meaningful focused
Swift Testing coverage when behavior exists; use XCTest for UI/performance APIs where
needed. Follow `docs/validation.md` for physical-device evidence before performance
claims. Do not suppress failing checks, weaken expectations, or claim unrun tests.

Keep generated build output, signing material, and private local information out of
commits. Explain what changed, what was verified, and what remains unimplemented.

# GlassWeave

An Apple-native glass framework for custom optical surfaces and native interaction.

GlassWeave is planned as an independently usable framework that brings custom Metal
glass surfaces into native apps while preserving native text, controls, gestures, and
accessibility. It will coexist visually with Apple's Liquid Glass.

## Status

**Planning stage; implementation has not started.** This repository contains the
architecture, implementation backlog, validation criteria, and a handoff for Claude.
There is no package manifest, source implementation, test suite, sample app, or release
yet. All framework capabilities described below are planned work.

## Direction

- **Native:** configure and choreograph genuine Apple glass without starting a Metal loop.
- **Enhanced-native:** compose independent visual effects around genuine Apple glass.
- **Custom:** render our own optical material over an explicitly supplied background.

The first milestone is one custom refractive panel beside genuine Apple glass over
moving, app-owned content, with responsive native controls. A transparent Metal view
does not itself provide a texture of arbitrary content behind it. Custom optical merging
will apply to surfaces rendered by GlassWeave; no shared optical surface with unchanged
Apple glass is promised.

## Start here

- [Claude implementation handoff](HANDOFF.md)
- [Implementation plan](tasks/plan.md)
- [Ordered tasks and acceptance criteria](tasks/todo.md)
- [Architecture](docs/architecture.md)
- [Language strategy](docs/language-strategy.md)
- [Validation and performance protocol](docs/validation.md)
- [Contributing](CONTRIBUTING.md)

## Proposed development baseline

| Area | Initial choice |
| --- | --- |
| Language | Swift 6 mode; Swift tools version 6.2 |
| First UI target | iOS and iPadOS 26 or later |
| macOS | macOS 26 core build checks; a native macOS UI adapter is future work |
| Local agent workflow | Xcode 27 skills and the native Xcode MCP server |
| Future CI | macOS 26 runner; macOS Debug/Release and iOS Simulator Release builds |
| Dependencies | None selected; keep the first implementation independent |

Start implementation from [HANDOFF.md](HANDOFF.md). The first implementation task
will create the Swift package and establish native Xcode builds. Add focused tests
with testable behavior and a runnable reference example with the rendering milestone.
No build or runtime checks can be reported for this documentation-only repository.

The OS baseline is a project choice. Metal 4 capability will be checked independently
of OS availability when a backend is implemented.

## Companion project

[Frostfield](https://github.com/Mitternacht/Frostfield) is the companion creative graphics
framework. GlassWeave currently has no Frostfield dependency and must remain usable
without a scene engine. A shared low-level Metal product is a later option, subject to
measurements and demonstrated common requirements.

## License

[MIT](LICENSE).

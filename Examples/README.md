# GlassWeave examples

Open `GlassWeave.xcworkspace`. It contains the package and the UIKit
laboratory, `GlassWeaveLab`, which consumes the package through a local
package reference.

The laboratory has one screen with two labeled regions and a Reset action:

- **Custom GlassWeave** presents an app-owned background source through
  `GlassSurfaceView`: a deterministic four-corner orientation pattern
  (`PatternSource.swift`) uploaded on the renderer's queue and handed over
  with a completion lease. Reset produces a new frame; the diagnostics line
  reports the presented frame, the drawable's pixel size, the last draw
  outcome, and the release of the previous frame.
- **Native reference** is reserved for genuine Apple glass.

No refraction is implemented yet, and nothing here is evidence of physical
device performance. The remaining work and its acceptance gates are listed in
[the task checklist](../tasks/todo.md).

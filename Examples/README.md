# GlassWeave examples

Open `GlassWeave.xcworkspace`. It contains the package and the UIKit
laboratory, `GlassWeaveLab`, which consumes the package through a local
package reference.

The laboratory has one screen: a stage with the rendered background, and the
comparison controls below it (portrait) or beside it (landscape).

- **Background.** By default the stage shows an app-owned moving source
  (`ProceduralBackground.swift`, `ProceduralBackground.metal`): a GPU-rendered
  pattern that is a pure function of one deterministic clock, advanced one
  1/60 s step per `UIUpdateLink` tick. Each frame is produced inside the
  command buffer that GlassWeave then uses to sample it. A frame-ID strip (16
  bit cells, white for 1) runs through the panel and the background so both
  can be compared; the Frame ID switch turns it off. Pause stops the clock;
  Reset returns it to zero. Launch with `-lab.source pattern` to show the still
  four-corner orientation pattern (`PatternSource.swift`) instead.
- **Custom GlassWeave panel.** One rounded glass panel (`GlassRenderer`) drawn
  over the same frame, under native UIKit content: a title and a "Custom
  action" button. The glass panel follows that content's frame.
- **Native reference.** Beside the panel, genuine Apple glass
  (`NativeGlassView`, a public `UIGlassEffect`) around a real "Native action"
  button, over the same stage. The tint and Enabled controls change the
  comparison state; Reset restores untinted, enabled, interactive glass and
  clears both tap counts. This control creates no GlassWeave renderer; the
  stage's renderer belongs to the custom panel. The two are separate material
  systems: nothing here merges the native glass with the custom panel.

The diagnostics list the clock state and content time, both tap counts, the
presented and produced frame IDs, the drawable size, pooled textures and
coalesced ticks, and the last released frame. The background stops moving
while Reduce Motion is on; that path is not yet verified (GW-08 owns the
accessibility checks).

Nothing here is evidence of physical device performance. The remaining work
and its acceptance gates are listed in [the task checklist](../tasks/todo.md).

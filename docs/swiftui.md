# The SwiftUI adapter (GW-15)

Experimental. `GlassWeaveSwiftUI` is an optional library product with one view,
`GlassSurface`, that shows the UIKit host (`GlassSurfaceView`) inside SwiftUI.
It owns no rendering: the renderer, the Metal view, the effect clock, the
visibility rules and the accessibility policy are the UIKit host's, unchanged.

macOS is not a presentation target. The target compiles to nothing there
(`#if canImport(UIKit)`), so the package still builds on My Mac; there is no
macOS view.

`GlassWeave` and `GlassWeaveUIKit` do not import or depend on the adapter. The
manifest shows it: the adapter depends on both, and no other target lists it
except its own test target.

## The three types

| Type | What it is |
|---|---|
| `GlassSurface` | The view. `GlassSurface(commandQueue:configuration:onFailure:)`. |
| `GlassSurfaceConfiguration` | A value: `panels`, `quality`, `motionClass`, `accessibilitySettings`, `qualityEnvironment`, `content`. `Equatable`, with the content compared by identity. |
| `GlassSurfaceContent` | A reference type that supplies the background: a frame producer (`init(producer:)`) or one frame (`init(source:)`). `requestFrame()` asks for a new frame. |

There is no other API and no builder syntax. The renderer needs a Metal command
queue, which the library never creates: pass the app's, the one the producer's
textures live on.

```swift
ZStack {
    GlassSurface(commandQueue: queue, configuration: GlassSurfaceConfiguration(
        panels: [GlassPanel(frame: cardFrame, parameters: parameters)],
        quality: model.quality,
        content: sky.content            // made once, held by the app
    ))
    .ignoresSafeArea()
    Controls()                           // native SwiftUI, above the glass
}
```

Panel frames are in the surface's own points (origin at its top-left). The
example measures the card with `onGeometryChange` in the `.global` space and
subtracts the surface's own origin, measured inside `ignoresSafeArea` so it is
the whole screen.

## What runs where

- **`body`** only describes the surface. It builds a configuration value.
- **`makeUIView`** runs once per view identity and builds the renderer and the
  surface there, in the coordinator, which owns both. SwiftUI updates never
  recreate them.
- **`updateUIView`** compares the new configuration with the last applied one
  and applies only the fields that changed (the UIKit setters guard again). Equal
  configurations do nothing. This is the low-frequency path: a slider, a toggle,
  a picker, a layout change.
- **The producer** (`GlassSurfaceContent`) runs inside the UIKit host's draw, on
  the main thread, as for a `GlassSurfaceView` used directly. It is never called
  from body evaluation. The app's own clock calls `content.requestFrame()`; a
  producer that has nothing new returns `nil`, and a new surface (a new
  identity) holds no frame yet, so it asks `content.surface?.renderer.currentFrame`
  before it does.

Per-frame values do not belong in the configuration: it is compared and applied
on every SwiftUI update.

## Lifecycle

| Event | What happens |
|---|---|
| First display | One surface, one renderer (`makeUIView`). |
| State updates | Configuration diff; no renderer, pipeline or texture is made. |
| Disappear or hide (a navigation push, `isHidden`, alpha, a background scene) | The UIKit host's own rules: it leaves its window, stops drawing and keeps one frame pending. The adapter adds none. |
| New `.id` | The old surface is torn down (`dismantleUIView` hands the content back) and released; the new identity makes one new surface with one new renderer. |
| Removal | Same teardown. |

If the renderer cannot be built (the shader library or a pipeline is missing),
the view is an opaque, decorative fill, the same as a surface without a source,
and `onFailure` gets the error. `onFailure` also gets `GlassParameterError` for
a panel with a non-finite value and `BackgroundSourceError` for a rejected
source frame; the previous panels or source stay. It is called after the update
that hit the error, so it may change state.

## Accessibility

The surface stays decorative: `GlassSurface` applies `accessibilityHidden(true)`,
and the UIKit host hides its own elements, is no accessibility element and takes
no touches. SwiftUI controls above it keep their own behavior. Reduce
Transparency, Increase Contrast and Reduce Motion are the UIKit host's
(`GlassAccessibilityPolicy`); `GlassSurfaceConfiguration.accessibilitySettings`
can fix the first and last for previews and comparison runs.

## The laboratory example

`-lab.swiftui YES` opens it as the window's root; the main screen's
"GlassSurface in SwiftUI" button opens it over the screen with a Close button.
It is a `UIHostingController` around `SwiftUIExampleScreen`
(`Examples/GlassWeaveLab/GlassWeaveLab/SwiftUIExample.swift`):

- The shelf study's sky and pebbles, drawn by the laboratory's own renderer
  inside the surface's draw (a producer in a `GlassSurfaceContent`).
- One rounded panel behind a `Slider` (lens strength), a `Toggle` (the light), a
  `Picker` (the quality tier) and a `Button` ("Rebuild surface", which gives the
  surface a new `.id`).
- A real `UIGlassEffect` (`NativeGlassView`) in the same shape above it, to
  compare. The panel uses the lab's shared refined look; the tuning that
  mattered was to keep the legibility scrim light (contrast 2.4 with a wide
  feather) and the frost low (6 points), so the body stays a calm, mostly clear
  material and not a gray veil.
- A census line: control updates, renderers created, renderers alive, relative
  to when the screen opened. It reads the package's renderer census through
  `@_spi(Census) import GlassWeave` (`GlassRendererCensus`, a read-only SPI added
  for this). Dragging the slider leaves "created" at 1; Rebuild makes it 2 and
  "alive" stays 1.

Launch arguments for captures: `-lab.studyTime <s>` pins the pebbles,
`-lab.swiftui.strength <0...1>`, `-lab.swiftui.light NO`,
`-lab.swiftui.quality balanced|minimal`, and the lab's `-lab.reduceMotion` and
`-lab.reduceTransparency`.

## The one test

`Tests/GlassWeaveSwiftUITests/AdapterLifecycleTests.swift` hosts a SwiftUI
screen in a `UIHostingController` and counts renderers with the renderer census:
one after the first display; still one after 50 state updates, each of which is
seen to reach the UIKit host; two after a new `.id`, with the first renderer
released; three after a navigation push to a screen with its own surface, and
three after the pop, with the pushed renderer released and the first screen's
surface still the same instance. At each step the surface and its ancestors are
no accessibility elements, the surface hides its elements and takes no touches.

## Not done in this pass

Listed with reasons in `tasks/todo.md` (GW-15): a test of real scene visibility
through the adapter (the unit-test process has no window scenes), live VoiceOver,
an Xcode preview, Dynamic Type at accessibility sizes for the example screen,
and a device run.

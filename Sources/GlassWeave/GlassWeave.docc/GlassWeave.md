# ``GlassWeave``

One custom refractive glass panel for UIKit apps, beside genuine Apple glass,
over a background the app owns.

## Overview

> Important: GlassWeave is a pre-alpha (v0.1 candidate). Every API is
> experimental and may change without notice. Nothing has been measured on a
> physical iPhone or iPad yet; see Measured limitations below.

GlassWeave has two modes in v0.1. Both keep text, controls, layout, focus,
hit testing, and accessibility in UIKit.

| Mode | Who draws the glass | Background | GlassWeave's part |
| --- | --- | --- | --- |
| Native | Apple (`UIGlassEffect`) | The system's own backdrop | `NativeGlassView` in GlassWeaveUIKit configures it; no renderer, Metal device, or display loop is created. |
| Custom | GlassWeave | A texture the app produces and hands over explicitly | ``GlassRenderer`` draws the background and one rounded panel; `GlassSurfaceView` in GlassWeaveUIKit presents them through an `MTKView`. |

The two are separate materials. GlassWeave does not merge its panel optically
with Apple's glass, and a custom panel can refract only the frames the app
gives it: a transparent Metal view cannot read the UI behind it.

This module, `GlassWeave`, is the core: the source contract, the renderers,
resources, scheduling counts, and measurement. It imports Metal, not UIKit,
and compiles for iOS 26 and macOS 26. `GlassWeaveUIKit` adds the views. The
examples below use both; each one is compiled and run by the package's tests.

### Native mode

Put native controls in a `NativeGlassView`'s `contentView`. They stay ordinary
UIKit controls.

```swift
import GlassWeaveUIKit
import UIKit

/// Genuine Apple glass around a native button. Creates no GlassWeave renderer.
@MainActor
func makeNativeGlassButton(title: String, action: UIAction) -> NativeGlassView {
    let glass = NativeGlassView(configuration: .init(tintColor: nil, isInteractive: true))
    glass.cornerConfiguration = .capsule()
    let button = UIButton(configuration: .plain(), primaryAction: action)
    button.configuration?.title = title
    button.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 20),
        button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -20),
        button.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
        button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
    ])
    return glass
}
```

### Custom mode: one rounded panel over your background

The app creates the Metal device and command queue; GlassWeave never does.
A `GlassSurfaceView` draws on demand. To animate, produce each frame inside
the draw's own command buffer with `setFrameProducer(_:)` and ask for draws
from your own clock with `requestFrame()`. A ``FrameTexturePool`` keeps the
producer's textures bounded and hands a texture back only after the GPU has
finished with it. Place native content above the surface and give the panel
the same frame, in the surface's points.

```swift
import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// One rounded glass panel over a background the app renders itself.
@MainActor
final class GlassStage {
    let surface: GlassSurfaceView
    private let pool: FrameTexturePool
    private var nextFrameID: UInt64 = 1
    private let start = ContinuousClock.now

    init(commandQueue: any MTLCommandQueue) throws {
        surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: commandQueue))
        // The presented frame plus the two the surface may have in flight.
        pool = FrameTexturePool(
            device: commandQueue.device,
            descriptor: .init(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: .bgra8Unorm_srgb
            ),
            capacity: 3
        )
        surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
            self?.produceFrame(into: commandBuffer, pixelSize: pixelSize)
        }
        // While the surface is not visible, give free textures back.
        surface.visibilityHandler = { [weak self] visible in
            if !visible { self?.pool.trim() }
        }
    }

    /// Places the panel over `frame`, in the surface's points: for example,
    /// the frame of the native content the panel carries.
    func placePanel(over frame: CGRect) throws {
        try surface.setPanel(GlassPanel(
            frame: frame,
            parameters: GlassParameters(cornerRadius: 30, bezelWidth: 22, refraction: 0.85)
        ))
    }

    /// Encodes the app's background into a pooled texture, inside the draw's
    /// own command buffer, and hands it over.
    private func produceFrame(
        into commandBuffer: any MTLCommandBuffer,
        pixelSize: (width: Int, height: Int)
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else {
            return nil // Every texture is in use: skip; the current frame is drawn again.
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        // Draw your background here.
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: nextFrameID,
            timestamp: ContinuousClock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        nextFrameID += 1
        return pool.lease(frame, using: pooled) { _ in }
    }
}
```

The producer writes `bgra8Unorm` and hands GlassWeave a `bgra8Unorm_srgb`
view, because the iOS Simulator cannot render into sRGB textures.

### Source ownership

A ``BackgroundFrame`` states everything the renderer needs and nothing it
guesses: the texture, a frame ID that must increase, a timestamp that must
not go back, the valid rectangle, orientation, the color convention, and how
the writes are ordered before sampling. v0.1 accepts exactly one source
format: a single-sample 2D `bgra8Unorm_srgb` texture with `shaderRead` usage
on the renderer's device, declared ``BackgroundColorConvention/sRGBOpaque``
(sampled in linear light, alpha ignored). Writes are ordered by the
renderer's own queue: committed earlier to it
(``BackgroundFrameReadiness/committed(on:)``) or encoded earlier in the
draw's command buffer (``BackgroundFrameReadiness/encoded(in:)``).

A ``BackgroundFrameLease`` owns the frame until every consumer is done. Its
release handler runs exactly once, on any thread, after the last GPU use, and
reports what happened in a ``BackgroundFrameRelease``. Until then the texture
must not be written.

```swift
import GlassWeave
import GlassWeaveUIKit
import Metal

/// Shows a still image whose upload was committed to the renderer's queue.
/// `reusable` runs once the surface and the GPU are done with the texture.
@MainActor
func presentStill(
    _ texture: any MTLTexture,
    on surface: GlassSurfaceView,
    reusable: @escaping @Sendable (BackgroundFrameRelease) -> Void
) throws(BackgroundSourceError) {
    let frame = BackgroundFrame(
        texture: texture,
        frameID: 1,
        timestamp: .zero,
        colorConvention: .sRGBOpaque,
        readiness: .committed(on: surface.renderer.commandQueue)
    )
    let lease = BackgroundFrameLease(frame: frame, onRelease: reusable)
    try surface.setSource(lease)
    // This frame goes to no other consumer.
    lease.retire()
}
```

### Lifecycle

`GlassSurfaceView` draws only when something changed (a source, a panel, its
size or display scale, or `requestFrame()`); requests before the next display
pass merge into one draw. It draws only while it is visible: in a window, not
hidden (nor any ancestor), with an alpha above zero, and with its *own* window
scene in the foreground, so a hidden surface never pauses one in another
scene. At most two frames are in flight; a draw at that bound waits for a
completion instead of queueing. Every texture a submitted frame uses stays
alive until that frame completes, and no path waits for the GPU on the main
thread. ``FrameStatistics`` (the surface's `frameStatistics`) counts requests,
coalesced requests, submissions, completions, skips, and deferrals.

### Failure behavior

| Condition | Behavior |
| --- | --- |
| No source | A defined skip: the surface's opaque `backgroundColor` shows; nothing is drawn. |
| Zero size or zero display scale | A defined skip before a drawable is requested. |
| No drawable | A defined skip; a produced frame's writes still run, and the frame is drawn by a later draw. |
| No free pooled texture | The producer returns `nil`; the current frame is drawn again (counted in ``RenderMetrics/Counts/declinedProductions``). |
| A source that breaks the contract | ``BackgroundSourceError`` names the fix; the previous source stays. A rejected produced frame is reported in the surface's `lastProducedFrameError`, and its writes still complete before release. |
| Non-finite panel parameters | ``GlassParameterError``; the previous panel stays. Finite out-of-range values are clamped, and ``GlassRenderer/panel`` reports what is drawn. |
| Missing shader library or pipeline | ``BackgroundRendererError`` when the renderer is created, never while drawing. |

See ``BackgroundRenderSkipReason`` and ``BackgroundRenderOutcome``.

### Accessibility

The surface is decorative: it and its Metal view expose no accessibility
elements and take no touches, so VoiceOver and touches reach only the native
content above it. Under Reduce Transparency the panel becomes an opaque
`secondarySystemBackground` surface with the same shape
(`GlassAccessibilityPolicy`); under Reduce Motion nothing in the panel moves,
and the surface reports the setting so the app can stop its own source. For
see-through glass, choose a tint strength that keeps text legible over any
background:

```swift
import GlassWeave
import UIKit

/// A panel tint that keeps label text at 4.5:1 over any background, or 7:1
/// with Increase Contrast.
func legibleTint(for traits: UITraitCollection) -> GlassTint {
    var tint = traits.userInterfaceStyle == .dark
        ? GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45)
        : GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
    let target = traits.accessibilityContrast == .high ? 7.0 : 4.5
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor.label.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let text = GlassTint.relativeLuminance(red: red, green: green, blue: blue)
    if let minimum = tint.minimumStrength(forContrast: target, againstTextLuminance: text) {
        tint.strength = max(tint.strength, minimum)
    }
    return tint
}
```

### Measuring

Assign a ``RenderMetrics`` recorder to ``GlassRenderer/metrics`` to record,
for every committed command buffer, the CPU time of GlassWeave's encoding,
of your producer, and of drawable acquisition, and the GPU start and end
times.

```swift
import GlassWeave

/// Starts measuring a renderer and later reports its GPU p95 in milliseconds,
/// or `nil` when the device reports no GPU times.
func measure(_ renderer: GlassRenderer) -> () -> Double? {
    let metrics = RenderMetrics()
    renderer.metrics = metrics
    return {
        guard let gpu = metrics.summary().gpu else { return nil }
        let components = gpu.p95.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
```

### Measured limitations

- **No physical device has been measured.** No iPhone or iPad class is
  qualified, and every performance budget in the validation protocol is
  unmeasured on hardware.
- The evidence so far is Swift Testing on an Apple M5 Mac and the iOS 27.2
  Simulator, UI tests on iPhone 18 Pro and iPad Pro 13-inch (M5) simulators,
  and an offscreen Mac characterization of the fixed workload. None of these
  is device evidence.
- No iOS 26 runtime was available; the deployment floor of 26.0 is declared,
  not run.
- Live VoiceOver navigation has not been exercised (the Simulator has no
  VoiceOver).
- macOS compiles and tests the core only; there is no macOS view.

## Topics

### Custom rendering

- ``GlassRenderer``
- ``GlassPanel``
- ``GlassParameters``
- ``GlassTint``
- ``GlassParameterError``

### Background source

- ``BackgroundFrame``
- ``BackgroundFrameLease``
- ``BackgroundFrameRelease``
- ``BackgroundFrameReadiness``
- ``BackgroundColorConvention``
- ``SourceOrientation``
- ``PixelRect``
- ``BackgroundSourceError``

### Producer textures

- ``FrameTexturePool``
- ``PooledTexture``

### Drawing without the UIKit view

- ``BackgroundRenderer``
- ``BackgroundDrawTarget``
- ``BackgroundRenderOutcome``
- ``BackgroundRenderSkipReason``
- ``BackgroundRendererError``

### Scheduling, capabilities, and measurement

- ``FrameStatistics``
- ``RenderCapabilities``
- ``RenderMetrics``

### Test patterns

- ``OrientationPattern``

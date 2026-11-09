import CoreGraphics
import Metal
internal import GlassWeaveShaderTypes

/// Frost infrastructure (GW-24a): the pyramid of filtered backgrounds that
/// the glass shader will sample for a blur that varies over a shape.
///
/// **Experimental.** This round builds, caches and measures the pyramid; the
/// glass shader does not read it yet, so requesting frost costs the pyramid
/// and changes no pixel on screen. See `docs/frost.md`.
extension GlassRenderer {
    /// The bytes of frost pyramids the renderer owns now: the computed size
    /// of each pyramid (every level at 8 bytes a texel). Zero until a frost
    /// is requested and drawn, and zero again after ``trimFrostResources()``.
    public var frostMemoryBytes: Int {
        frostPyramids.memoryBytes
    }

    /// Releases the frost pyramids, for a host whose surface is hidden;
    /// ``GlassSurfaceView`` calls it when it stops being visible. Draws in
    /// flight finish with the pyramid they hold, and the next draw that needs
    /// one builds it. Does nothing when no pyramid exists.
    public func trimFrostResources() {
        frostPyramids.trim()
    }

    /// Requests a pyramid of filtered backgrounds for every following draw,
    /// or none with ``GlassFrost/none`` (the default).
    ///
    /// **Experimental diagnostic** (GW-24a), for the laboratory and tests,
    /// until each panel carries its own frost. The frost is normalized
    /// (``GlassFrost/normalized()``): a non-finite field throws and leaves
    /// the request as it was.
    ///
    /// - Parameters:
    ///   - region: The frosted area in points (origin at the surface's
    ///     top-left), or `nil` for the whole surface. The pyramid covers it
    ///     grown by three times the blur radius.
    ///   - margin: Extra reach in points added on every side, for example
    ///     the largest refraction offset.
    @_spi(FrostLab)
    public func setFrost(
        _ frost: GlassFrost, region: CGRect? = nil, margin: Double = 0
    ) throws(GlassFrostError) {
        let normalized = try frost.normalized()
        frostRequest = normalized.isNone ? nil : FrostRequest(frost: normalized, region: region, margin: max(margin, 0))
    }

    /// An image of the latest pyramid for the laboratory: a tile for each
    /// level and a tile for each frost profile's blur map, in rows of `columns`. `nil` while no
    /// pyramid exists. Suspends until the GPU finishes and blocks no thread.
    @_spi(FrostLab)
    nonisolated(nonsending) public func frostAtlasImage(tileHeight: Int = 160, columns: Int = 3) async -> CGImage? {
        guard let pyramid = frostPyramids.current, let frost = frostRequest?.frost else { return nil }
        return await frostPyramids.atlasImage(pyramid, frost: frost, tileHeight: tileHeight, columns: columns)
    }

    /// The preparation a draw does for the current request, or `nil` when
    /// there is no frost (the draw then runs exactly as it did before).
    func frostPreRender(displayScale: Double) -> BackgroundRenderer.PreRender? {
        guard let request = frostRequest, !isFrostSuppressed else { return nil }
        let ring = frostPyramids
        func key(_ frame: BackgroundFrame, _ size: (width: Int, height: Int)) -> FrostCacheKey? {
            request.plan(displayScale: displayScale, targetSize: size).map {
                FrostCacheKey(frameID: frame.frameID, plan: $0, targetWidth: size.width, targetHeight: size.height)
            }
        }
        return BackgroundRenderer.PreRender(
            // Nothing to filter (the frosted region is off the target) is
            // not a reason to skip.
            admit: { frame, size in key(frame, size).map(ring.canServe) ?? true },
            encode: { commandBuffer, frame, background, size in
                guard let key = key(frame, size) else { return true }
                return ring.encode(key: key, frame: frame, source: background, into: commandBuffer)
            }
        )
    }
}

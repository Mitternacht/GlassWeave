import Metal
import Testing
@testable import GlassWeave

/// Offscreen GPU rendering of explicit sources: orientation, crop, color
/// round trip, defined skips, and lease completion through real command
/// buffers. Runs with Metal API Validation when the scheme sets
/// MTL_DEBUG_LAYER=1.
@Suite(.timeLimit(.minutes(1)))
struct BackgroundRendererTests {
    typealias Color = OrientationPattern.Color

    /// Renders `lease` into a new `width` x `height` target and reads it back.
    private func render(
        _ gpu: GPUContext, _ renderer: BackgroundRenderer,
        width: Int, height: Int
    ) async throws -> RenderedImage {
        let target = try gpu.makeTarget(width: width, height: height)
        let outcome = renderer.draw(targetPixelSize: (width, height)) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    @Test func `A 1:1 presentation reproduces every source pixel`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makePatternLease(width: 32, height: 32))
        let image = try await render(gpu, renderer, width: 32, height: 32)

        // Each destination pixel center lands on the matching texel center,
        // so decode (sRGB to linear) then encode (linear to sRGB) must give
        // back the stored bytes, including the sRGB 128 mid-gray.
        let pattern = OrientationPattern(width: 32, height: 32)
        var mismatches = 0
        for y in 0..<32 {
            for x in 0..<32 where !image.color(x: x, y: y).isClose(to: pattern.color(x: x, y: y), tolerance: 1) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
        #expect(image.color(x: 16, y: 16).isClose(to: OrientationPattern.center, tolerance: 1))
        #expect(image.color(x: 0, y: 0) == OrientationPattern.topLeft)
        #expect(image.color(x: 31, y: 0) == OrientationPattern.topRight)
        #expect(image.color(x: 0, y: 31) == OrientationPattern.bottomLeft)
        #expect(image.color(x: 31, y: 31) == OrientationPattern.bottomRight)
    }

    /// The color expected at each destination corner (top-left, top-right,
    /// bottom-left, bottom-right) when the stored pattern carries each
    /// orientation, derived by turning the stored quadrants by hand.
    static let orientationCases: [(SourceOrientation, [Color])] = {
        let r = OrientationPattern.topLeft, g = OrientationPattern.topRight
        let b = OrientationPattern.bottomLeft, y = OrientationPattern.bottomRight
        return [
            (SourceOrientation(rotation: .none, verticalOrigin: .top), [r, g, b, y]),
            (SourceOrientation(rotation: .clockwise90, verticalOrigin: .top), [b, r, y, g]),
            (SourceOrientation(rotation: .clockwise180, verticalOrigin: .top), [y, b, g, r]),
            (SourceOrientation(rotation: .clockwise270, verticalOrigin: .top), [g, y, r, b]),
            (SourceOrientation(rotation: .none, verticalOrigin: .bottom), [b, y, r, g]),
            (SourceOrientation(rotation: .clockwise90, verticalOrigin: .bottom), [r, b, g, y]),
            (SourceOrientation(rotation: .clockwise180, verticalOrigin: .bottom), [g, r, y, b]),
            (SourceOrientation(rotation: .clockwise270, verticalOrigin: .bottom), [y, g, b, r]),
        ]
    }()

    @Test(arguments: orientationCases)
    func `Orientation metadata turns the stored pattern upright`(orientation: SourceOrientation, corners: [Color]) async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makePatternLease(width: 32, height: 32, orientation: orientation))
        let image = try await render(gpu, renderer, width: 32, height: 32)
        #expect([image.color(x: 4, y: 4), image.color(x: 27, y: 4), image.color(x: 4, y: 27), image.color(x: 27, y: 27)] == corners)
        #expect(image.color(x: 16, y: 16).isClose(to: OrientationPattern.center))
    }

    @Test func `A quarter-turned landscape source fills a portrait target upright`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makePatternLease(width: 64, height: 32, orientation: SourceOrientation(rotation: .clockwise90)))
        let image = try await render(gpu, renderer, width: 32, height: 64)
        // Stored bottom-left (blue) turns to the upright top-left.
        #expect(image.color(x: 2, y: 2) == OrientationPattern.bottomLeft)
        #expect(image.color(x: 29, y: 2) == OrientationPattern.topLeft)
        #expect(image.color(x: 2, y: 61) == OrientationPattern.bottomRight)
        #expect(image.color(x: 29, y: 61) == OrientationPattern.topRight)
        #expect(image.color(x: 16, y: 32).isClose(to: OrientationPattern.center))
    }

    @Test func `Aspect fill crops a wide target symmetrically`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makePatternLease(width: 32, height: 32))
        // Scale 2 covers 64 x 12 with source rows 13 to 19, the centered
        // 3/16 of the height. The mid-gray square spans rows 12 to 19, so
        // every bilinear sample down the center column stays inside it; an
        // off-center crop would reach the quadrant colors.
        let image = try await render(gpu, renderer, width: 64, height: 12)
        for y in 0..<12 {
            #expect(image.color(x: 32, y: y).isClose(to: OrientationPattern.center), "row \(y)")
        }
        // The visible rows straddle the source's horizontal midline, so the
        // left and right edges show all four quadrants upright.
        #expect(image.color(x: 2, y: 1) == OrientationPattern.topLeft)
        #expect(image.color(x: 61, y: 1) == OrientationPattern.topRight)
        #expect(image.color(x: 2, y: 10) == OrientationPattern.bottomLeft)
        #expect(image.color(x: 61, y: 10) == OrientationPattern.bottomRight)
    }

    @Test func `Sampling never leaves the valid rectangle`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        // The valid content is the 12 x 12 red corner. The texels just past
        // its right and bottom edges are gray; without the half-texel clamp
        // linear filtering would blend them into the last columns and rows.
        try renderer.setSource(gpu.makePatternLease(width: 32, height: 32, validRect: PixelRect(x: 0, y: 0, width: 12, height: 12)))
        let image = try await render(gpu, renderer, width: 24, height: 24)
        var nonRed = 0
        for y in 0..<24 {
            for x in 0..<24 where image.color(x: x, y: y) != OrientationPattern.topLeft {
                nonRed += 1
            }
        }
        #expect(nonRed == 0)
    }

    @Test func `Missing source is a skip that never acquires a target`() throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        var acquired = false
        let outcome = renderer.draw(targetPixelSize: (32, 32)) { acquired = true; return nil }
        #expect(outcome == .skipped(.missingSource))
        #expect(!acquired)
    }

    @Test(arguments: [(0, 32), (32, 0), (0, 0)])
    func `Zero-size target is a skip that never acquires a target`(width: Int, height: Int) throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        let recorder = ReleaseRecorder()
        let lease = try gpu.makePatternLease(width: 8, height: 8, onRelease: recorder.handler)
        try renderer.setSource(lease)
        var acquired = false
        let outcome = renderer.draw(targetPixelSize: (width, height)) { acquired = true; return nil }
        #expect(outcome == .skipped(.zeroSizeTarget))
        #expect(!acquired)
        renderer.clearSource()
        lease.retire()
        #expect(recorder.releases.map(\.skippedSubmissions) == [0])
    }

    @Test func `Unavailable drawable is a skip the producer hears about`() throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        let recorder = ReleaseRecorder()
        let lease = try gpu.makePatternLease(width: 8, height: 8, onRelease: recorder.handler)
        try renderer.setSource(lease)
        lease.retire()
        #expect(renderer.draw(targetPixelSize: (8, 8)) { nil } == .skipped(.drawableUnavailable))
        #expect(recorder.releases.isEmpty, "The renderer still presents the frame")
        renderer.clearSource()
        #expect(recorder.releases == [BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 0, failedSubmissions: 0,
            skippedSubmissions: 1, cancelledSubmissions: 0
        )])
    }

    @Test func `Release waits for every submitted draw to complete`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        let recorder = ReleaseRecorder()
        let lease = try gpu.makePatternLease(width: 16, height: 16, onRelease: recorder.handler)
        try renderer.setSource(lease)
        lease.retire()
        for _ in 0..<3 {
            let target = try gpu.makeTarget(width: 16, height: 16)
            #expect(renderer.draw(targetPixelSize: (16, 16)) { target } == .submitted(frameID: 1))
        }
        renderer.clearSource()
        let release = await recorder.firstRelease()
        #expect(release == BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 3, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        ))
        #expect(lease.isReleased)
        #expect(recorder.releases.count == 1)
    }

    @Test func `Replacing the source releases the previous frame`() async throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        let firstRecorder = ReleaseRecorder()
        let first = try gpu.makePatternLease(width: 8, height: 8, frameID: 1, onRelease: firstRecorder.handler)
        let second = try gpu.makePatternLease(width: 8, height: 8, frameID: 2, timestamp: .milliseconds(16))
        try renderer.setSource(first)
        first.retire()
        let target = try gpu.makeTarget(width: 8, height: 8)
        #expect(renderer.draw(targetPixelSize: (8, 8)) { target } == .submitted(frameID: 1))
        try renderer.setSource(second)
        #expect(renderer.currentFrame?.frameID == 2)
        #expect(await firstRecorder.firstRelease().completedSubmissions == 1)
        #expect(!second.isReleased)
    }

    @Test func `Rejected sources leave the current source in place`() throws {
        let gpu = try GPUContext()
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makePatternLease(width: 8, height: 8, frameID: 5))

        // Unsupported format: a non-sRGB texture is refused, not reinterpreted.
        let linearTexture = try gpu.makeTexture(width: 8, height: 8, pixelFormat: .bgra8Unorm)
        let linearFrame = BackgroundFrame(
            texture: linearTexture, frameID: 6, timestamp: .zero,
            colorConvention: .sRGBOpaque, readiness: .committed(on: gpu.queue)
        )
        #expect(throws: BackgroundSourceError.pixelFormatMismatch(declared: .sRGBOpaque, actual: .bgra8Unorm)) {
            try renderer.setSource(BackgroundFrameLease(frame: linearFrame) { _ in })
        }

        // Writes committed to another queue have no ordering guarantee.
        let otherQueue = try #require(gpu.device.makeCommandQueue())
        let otherTexture = try gpu.makeTexture(width: 8, height: 8)
        let otherFrame = BackgroundFrame(
            texture: otherTexture, frameID: 7, timestamp: .zero,
            colorConvention: .sRGBOpaque, readiness: .committed(on: otherQueue)
        )
        #expect(throws: BackgroundSourceError.queueMismatch) {
            try renderer.setSource(BackgroundFrameLease(frame: otherFrame) { _ in })
        }

        // A stale frame from the same producer.
        #expect(throws: BackgroundSourceError.outOfOrderFrame(previousID: 5, receivedID: 4)) {
            try renderer.setSource(gpu.makePatternLease(width: 8, height: 8, frameID: 4))
        }

        // A lease whose producer already let go may have been reused.
        let released = try gpu.makePatternLease(width: 8, height: 8, frameID: 8)
        released.retire()
        #expect(throws: BackgroundSourceError.leaseAlreadyReleased(frameID: 8)) {
            try renderer.setSource(released)
        }

        #expect(renderer.currentFrame?.frameID == 5)
    }

    @Test func `Creating a renderer is counted and signposted`() throws {
        let gpu = try GPUContext()
        let before = RendererCensus.created
        let renderer = try BackgroundRenderer(commandQueue: gpu.queue)
        #expect(RendererCensus.created >= before + 1)
        #expect(renderer.commandQueue === gpu.queue)
        #expect(renderer.device === gpu.device)
    }
}

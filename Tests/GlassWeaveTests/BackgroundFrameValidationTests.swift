import Metal
import Testing
@testable import GlassWeave

/// The stateless source contract, checked without a GPU so every rejection,
/// including a device mismatch, can be exercised on any machine.
struct SourceFrameValidationTests {
    private final class Identity {}
    private let device = Identity()
    private let otherDevice = Identity()
    private let queue = Identity()
    private let otherQueue = Identity()

    private func facts(
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
        textureType: MTLTextureType = .type2D,
        sampleCount: Int = 1,
        usage: MTLTextureUsage = [.shaderRead],
        device: Identity? = nil
    ) -> SourceTextureFacts {
        SourceTextureFacts(
            pixelFormat: pixelFormat, textureType: textureType, sampleCount: sampleCount,
            usage: usage, width: 64, height: 32,
            deviceIdentity: ObjectIdentifier(device ?? self.device), deviceName: "Source GPU"
        )
    }

    private func validate(
        _ facts: SourceTextureFacts,
        validRect: PixelRect = PixelRect(x: 0, y: 0, width: 64, height: 32),
        readinessQueue: Identity? = nil
    ) throws(BackgroundSourceError) {
        try SourceFrameValidation.validate(
            texture: facts, colorConvention: .sRGBOpaque, validRect: validRect,
            readinessQueue: ObjectIdentifier(readinessQueue ?? queue),
            rendererDevice: ObjectIdentifier(device), rendererDeviceName: "Renderer GPU",
            rendererQueue: ObjectIdentifier(queue)
        )
    }

    @Test func `Accepts the v0.1 source format`() throws {
        try validate(facts())
        try validate(facts(usage: [.shaderRead, .renderTarget]))
        try validate(facts(), validRect: PixelRect(x: 10, y: 4, width: 54, height: 28))
    }

    @Test(arguments: [MTLPixelFormat.bgra8Unorm, .rgba8Unorm_srgb, .rgba16Float, .bgr10a2Unorm])
    func `Rejects other pixel formats instead of guessing their color`(format: MTLPixelFormat) {
        #expect(throws: BackgroundSourceError.pixelFormatMismatch(declared: .sRGBOpaque, actual: format)) {
            try validate(facts(pixelFormat: format))
        }
    }

    @Test func `Rejects a texture from another device`() {
        #expect(throws: BackgroundSourceError.deviceMismatch(sourceDevice: "Source GPU", rendererDevice: "Renderer GPU")) {
            try validate(facts(device: otherDevice))
        }
    }

    @Test func `Rejects writes ordered on another queue`() {
        #expect(throws: BackgroundSourceError.queueMismatch) {
            try validate(facts(), readinessQueue: otherQueue)
        }
    }

    @Test func `Rejects non-2D, multisampled, and unreadable textures`() {
        #expect(throws: BackgroundSourceError.unsupportedTextureType(.type2DArray)) {
            try validate(facts(textureType: .type2DArray))
        }
        #expect(throws: BackgroundSourceError.unsupportedSampleCount(4)) {
            try validate(facts(sampleCount: 4))
        }
        #expect(throws: BackgroundSourceError.missingShaderReadUsage) {
            try validate(facts(usage: [.renderTarget]))
        }
    }

    @Test(arguments: [
        PixelRect(x: 0, y: 0, width: 0, height: 32),
        PixelRect(x: 0, y: 0, width: 64, height: 0),
        PixelRect(x: -1, y: 0, width: 10, height: 10),
        PixelRect(x: 60, y: 0, width: 5, height: 10),
        PixelRect(x: 0, y: 30, width: 10, height: 3),
        PixelRect(x: 64, y: 0, width: 1, height: 1),
        PixelRect(x: 1, y: 1, width: .max, height: .max),
    ])
    func `Rejects an empty or out-of-bounds valid rectangle`(rect: PixelRect) {
        #expect(throws: BackgroundSourceError.invalidValidRect(rect, textureWidth: 64, textureHeight: 32)) {
            try validate(facts(), validRect: rect)
        }
    }

    @Test func `Frame IDs must increase and timestamps must not go back`() throws {
        try SourceFrameValidation.validateOrder(frameID: 1, timestamp: .zero, after: nil)
        try SourceFrameValidation.validateOrder(frameID: 2, timestamp: .seconds(1), after: (1, .seconds(1)))
        #expect(throws: BackgroundSourceError.outOfOrderFrame(previousID: 5, receivedID: 5)) {
            try SourceFrameValidation.validateOrder(frameID: 5, timestamp: .seconds(2), after: (5, .seconds(1)))
        }
        #expect(throws: BackgroundSourceError.outOfOrderFrame(previousID: 5, receivedID: 4)) {
            try SourceFrameValidation.validateOrder(frameID: 4, timestamp: .seconds(2), after: (5, .seconds(1)))
        }
        #expect(throws: BackgroundSourceError.timestampRegressed(previous: .seconds(2), received: .seconds(1))) {
            try SourceFrameValidation.validateOrder(frameID: 6, timestamp: .seconds(1), after: (5, .seconds(2)))
        }
    }

    @Test func `Errors name the problem and the fix`() {
        let format = BackgroundSourceError.pixelFormatMismatch(declared: .sRGBOpaque, actual: .bgra8Unorm).description
        #expect(format.contains(".bgra8Unorm_srgb"))
        #expect(format.contains("but its texture is .bgra8Unorm"))
        #expect(BackgroundSourceError.queueMismatch.description.contains("commandQueue"))
        #expect(BackgroundSourceError.deviceMismatch(sourceDevice: "A", rendererDevice: "B").description.contains("Produce the texture on the renderer's device"))
    }
}

import Metal

/// A rectangle in texture pixels. The origin is the top-left texel of texture
/// memory (Metal's texture origin), x to the right and y downward.
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// How a source's stored pixels relate to its upright image.
///
/// Applied in this order to go from texture memory to the upright image:
/// 1. If `verticalOrigin` is `.bottom`, memory row 0 is the *bottom* row of
///    the image, so the rows are flipped first.
/// 2. The result is rotated clockwise by `rotation`.
public struct SourceOrientation: Hashable, Sendable {
    /// Clockwise quarter turns that bring the stored image upright.
    public enum Rotation: Int, Hashable, Sendable, CaseIterable {
        case none = 0
        case clockwise90 = 1
        case clockwise180 = 2
        case clockwise270 = 3
    }

    /// Which end of the image the first row of texture memory holds.
    public enum VerticalOrigin: Hashable, Sendable, CaseIterable {
        /// Memory row 0 is the top of the image (Metal and UIKit convention).
        case top
        /// Memory row 0 is the bottom of the image (for example, a
        /// bottom-up bitmap or an OpenGL-style render).
        case bottom
    }

    public var rotation: Rotation
    public var verticalOrigin: VerticalOrigin

    public init(rotation: Rotation = .none, verticalOrigin: VerticalOrigin = .top) {
        self.rotation = rotation
        self.verticalOrigin = verticalOrigin
    }

    /// Stored upright, top row first.
    public static let up = SourceOrientation()
}

/// The color and alpha convention a producer declares for its frame.
///
/// GlassWeave never infers color or alpha from a texture. The producer states
/// the convention, and the renderer rejects a texture that does not match it.
public enum BackgroundColorConvention: Hashable, Sendable {
    /// SDR sRGB-encoded 8-bit BGRA (`MTLPixelFormat.bgra8Unorm_srgb`). The
    /// renderer samples it in linear light (the hardware decodes sRGB on
    /// read). The source is opaque: its alpha channel is ignored.
    ///
    /// This is the only convention accepted by GlassWeave v0.1.
    case sRGBOpaque

    /// The texture pixel format this convention requires.
    public var requiredPixelFormat: MTLPixelFormat {
        switch self {
        case .sRGBOpaque: .bgra8Unorm_srgb
        }
    }
}

/// How the consumer knows the producer's writes are visible before it samples.
///
/// A Swift actor hop or CPU lock does not order GPU work. GlassWeave v0.1
/// accepts one mechanism, same-queue encode order, in two forms.
///
/// Not `Sendable`: `.encoded(in:)` carries a command buffer, which belongs to
/// the code encoding it. Like the frame it describes, a readiness value stays
/// in the producer's and renderer's isolation domain.
public enum BackgroundFrameReadiness {
    /// Every command that writes the texture was encoded into command buffers
    /// that the producer committed to `queue` *before* handing over the frame.
    /// The consumer must commit its sampling work to the same queue, which
    /// Metal executes after those writes.
    case committed(on: any MTLCommandQueue)
    /// Every command that writes the texture was encoded earlier in
    /// `commandBuffer`, which belongs to the renderer's queue.
    ///
    /// Produced inside ``GlassRenderer/drawProducing(targetPixelSize:displayScale:produce:acquireTarget:)``,
    /// the command buffer is the draw's own: the renderer encodes its
    /// sampling later in the same command buffer and commits it. Handed to
    /// `setSource` directly, the command buffer must already be enqueued or
    /// committed, which fixes its place in the queue before the renderer's
    /// later work.
    case encoded(in: any MTLCommandBuffer)
}

/// One produced background image and its metadata, immutable for a submission.
///
/// The frame does not own reuse of its texture; wrap it in a
/// ``BackgroundFrameLease`` so the producer learns when every consumer has
/// finished with it.
public struct BackgroundFrame {
    /// The source pixels. Must be a single-sample 2D texture with shader-read
    /// usage on the consuming renderer's device.
    public let texture: any MTLTexture
    /// Producer sequence number. A renderer accepts only increasing IDs.
    public let frameID: UInt64
    /// When the producer generated this content, on the producer's own clock.
    /// A renderer accepts only non-decreasing timestamps.
    public let timestamp: Duration
    /// The texels that hold valid content, in texture pixels. Samples never
    /// read outside it.
    public let validRect: PixelRect
    /// How the stored pixels relate to the upright image.
    public let orientation: SourceOrientation
    /// The declared color and alpha convention.
    public let colorConvention: BackgroundColorConvention
    /// How producer writes are ordered before consumer reads.
    public let readiness: BackgroundFrameReadiness

    /// Creates frame metadata. Validation happens when a renderer accepts the
    /// frame, so a rejected frame produces an actionable
    /// ``BackgroundSourceError`` instead of an incorrect image.
    ///
    /// - Parameter validRect: The valid content in texture pixels. Pass `nil`
    ///   for the whole texture.
    public init(
        texture: any MTLTexture,
        frameID: UInt64,
        timestamp: Duration,
        validRect: PixelRect? = nil,
        orientation: SourceOrientation = .up,
        colorConvention: BackgroundColorConvention,
        readiness: BackgroundFrameReadiness
    ) {
        self.texture = texture
        self.frameID = frameID
        self.timestamp = timestamp
        self.validRect = validRect ?? PixelRect(x: 0, y: 0, width: texture.width, height: texture.height)
        self.orientation = orientation
        self.colorConvention = colorConvention
        self.readiness = readiness
    }
}

/// Why a renderer refused a source frame. Each case names the fix.
public enum BackgroundSourceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The texture's pixel format does not match the declared convention.
    case pixelFormatMismatch(declared: BackgroundColorConvention, actual: MTLPixelFormat)
    /// The texture is not a 2D texture.
    case unsupportedTextureType(MTLTextureType)
    /// The texture is multisampled.
    case unsupportedSampleCount(Int)
    /// The texture was created without `MTLTextureUsage.shaderRead`.
    case missingShaderReadUsage
    /// The texture belongs to a different GPU device than the renderer.
    case deviceMismatch(sourceDevice: String, rendererDevice: String)
    /// The producer committed its writes to a different command queue.
    case queueMismatch
    /// The frame's writes are in a command buffer that has not been enqueued
    /// or committed, so nothing orders them before the renderer's sampling.
    case commandBufferNotEnqueued
    /// The valid rectangle is empty or extends outside the texture.
    case invalidValidRect(PixelRect, textureWidth: Int, textureHeight: Int)
    /// The frame ID is not greater than the last accepted frame's ID.
    case outOfOrderFrame(previousID: UInt64, receivedID: UInt64)
    /// The timestamp is earlier than the last accepted frame's timestamp.
    case timestampRegressed(previous: Duration, received: Duration)
    /// The producer already released this lease, so its storage may be reused.
    case leaseAlreadyReleased(frameID: UInt64)

    public var description: String {
        switch self {
        case let .pixelFormatMismatch(declared, actual):
            "The frame declares \(declared), which requires \(Self.name(of: declared.requiredPixelFormat)), but its texture is \(Self.name(of: actual)). Render or convert the source into a \(Self.name(of: declared.requiredPixelFormat)) texture."
        case let .unsupportedTextureType(type):
            "The source texture type is \(Self.name(of: type)); GlassWeave samples only single-sample 2D textures (.type2D). Copy or resolve the content into a 2D texture."
        case let .unsupportedSampleCount(count):
            "The source texture has \(count) samples; GlassWeave samples only single-sample textures. Resolve the multisample texture into a single-sample texture first."
        case .missingShaderReadUsage:
            "The source texture lacks MTLTextureUsage.shaderRead. Create it with .shaderRead in its usage."
        case let .deviceMismatch(sourceDevice, rendererDevice):
            "The source texture belongs to \(sourceDevice) but the renderer uses \(rendererDevice). Produce the texture on the renderer's device."
        case .queueMismatch:
            "The frame's writes were committed to a different command queue than the renderer's. GlassWeave v0.1 orders producer and consumer by same-queue encode order; encode the producer's writes on the renderer's commandQueue."
        case .commandBufferNotEnqueued:
            "The frame's writes are in a command buffer that is not yet enqueued or committed. Commit (or enqueue) it before handing over the frame, or produce the frame inside GlassRenderer.drawProducing, which commits it."
        case let .invalidValidRect(rect, width, height):
            "The valid rectangle (x \(rect.x), y \(rect.y), \(rect.width) x \(rect.height)) must be non-empty and lie inside the \(width) x \(height) texture."
        case let .outOfOrderFrame(previousID, receivedID):
            "Frame \(receivedID) arrived after frame \(previousID). Frame IDs from one producer must increase; drop the stale frame."
        case let .timestampRegressed(previous, received):
            "Frame timestamp \(received) is earlier than the previous \(previous). Producer timestamps must not go backwards."
        case let .leaseAlreadyReleased(frameID):
            "The lease for frame \(frameID) was already released, so the producer may have reused its texture. Hand the lease to the renderer before retiring it."
        }
    }

    static func name(of format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm_srgb: ".bgra8Unorm_srgb"
        case .bgra8Unorm: ".bgra8Unorm"
        case .rgba8Unorm: ".rgba8Unorm"
        case .rgba8Unorm_srgb: ".rgba8Unorm_srgb"
        case .rgba16Float: ".rgba16Float"
        case .bgr10a2Unorm: ".bgr10a2Unorm"
        case .rgb10a2Unorm: ".rgb10a2Unorm"
        case .r8Unorm: ".r8Unorm"
        default: "MTLPixelFormat raw value \(format.rawValue)"
        }
    }

    static func name(of type: MTLTextureType) -> String {
        switch type {
        case .type1D: ".type1D"
        case .type1DArray: ".type1DArray"
        case .type2D: ".type2D"
        case .type2DArray: ".type2DArray"
        case .type2DMultisample: ".type2DMultisample"
        case .type2DMultisampleArray: ".type2DMultisampleArray"
        case .type3D: ".type3D"
        case .typeCube: ".typeCube"
        case .typeCubeArray: ".typeCubeArray"
        case .typeTextureBuffer: ".typeTextureBuffer"
        @unknown default: "MTLTextureType raw value \(type.rawValue)"
        }
    }
}

/// The properties of a source texture that the contract checks, separated
/// from the texture so validation is a pure function.
struct SourceTextureFacts: Equatable {
    var pixelFormat: MTLPixelFormat
    var textureType: MTLTextureType
    var sampleCount: Int
    var usage: MTLTextureUsage
    var width: Int
    var height: Int
    var deviceIdentity: ObjectIdentifier
    var deviceName: String

    init(
        pixelFormat: MTLPixelFormat, textureType: MTLTextureType, sampleCount: Int,
        usage: MTLTextureUsage, width: Int, height: Int,
        deviceIdentity: ObjectIdentifier, deviceName: String
    ) {
        self.pixelFormat = pixelFormat
        self.textureType = textureType
        self.sampleCount = sampleCount
        self.usage = usage
        self.width = width
        self.height = height
        self.deviceIdentity = deviceIdentity
        self.deviceName = deviceName
    }

    init(_ texture: any MTLTexture) {
        self.init(
            pixelFormat: texture.pixelFormat, textureType: texture.textureType,
            sampleCount: texture.sampleCount, usage: texture.usage,
            width: texture.width, height: texture.height,
            deviceIdentity: ObjectIdentifier(texture.device), deviceName: texture.device.name
        )
    }
}

/// The checks every source frame passes before a renderer samples it.
enum SourceFrameValidation {
    /// Validates the stateless parts of the contract: device, format,
    /// texture shape and usage, valid rectangle, and readiness queue.
    static func validate(
        texture facts: SourceTextureFacts,
        colorConvention: BackgroundColorConvention,
        validRect: PixelRect,
        readinessQueue: ObjectIdentifier,
        rendererDevice: ObjectIdentifier,
        rendererDeviceName: String,
        rendererQueue: ObjectIdentifier
    ) throws(BackgroundSourceError) {
        guard facts.deviceIdentity == rendererDevice else {
            throw .deviceMismatch(sourceDevice: facts.deviceName, rendererDevice: rendererDeviceName)
        }
        guard facts.textureType == .type2D else {
            throw .unsupportedTextureType(facts.textureType)
        }
        guard facts.sampleCount == 1 else {
            throw .unsupportedSampleCount(facts.sampleCount)
        }
        guard facts.pixelFormat == colorConvention.requiredPixelFormat else {
            throw .pixelFormatMismatch(declared: colorConvention, actual: facts.pixelFormat)
        }
        guard facts.usage.contains(.shaderRead) else {
            throw .missingShaderReadUsage
        }
        // Compare by subtraction so extreme values cannot overflow.
        guard validRect.width > 0, validRect.height > 0,
              validRect.x >= 0, validRect.y >= 0,
              validRect.x < facts.width, validRect.y < facts.height,
              validRect.width <= facts.width - validRect.x,
              validRect.height <= facts.height - validRect.y
        else {
            throw .invalidValidRect(validRect, textureWidth: facts.width, textureHeight: facts.height)
        }
        guard readinessQueue == rendererQueue else {
            throw .queueMismatch
        }
    }

    /// Validates ordering against the last frame a renderer accepted.
    static func validateOrder(
        frameID: UInt64, timestamp: Duration,
        after previous: (frameID: UInt64, timestamp: Duration)?
    ) throws(BackgroundSourceError) {
        guard let previous else { return }
        guard frameID > previous.frameID else {
            throw .outOfOrderFrame(previousID: previous.frameID, receivedID: frameID)
        }
        guard timestamp >= previous.timestamp else {
            throw .timestampRegressed(previous: previous.timestamp, received: timestamp)
        }
    }
}

extension BackgroundFrameReadiness {
    var queueIdentity: ObjectIdentifier {
        switch self {
        case let .committed(queue): ObjectIdentifier(queue)
        case let .encoded(commandBuffer): ObjectIdentifier(commandBuffer.commandQueue)
        }
    }

    /// The command buffer holding the writes, for `.encoded(in:)`.
    var encodingCommandBuffer: (any MTLCommandBuffer)? {
        switch self {
        case .committed: nil
        case let .encoded(commandBuffer): commandBuffer
        }
    }
}

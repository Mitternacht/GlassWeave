import Foundation
import Metal
import Testing
@testable import GlassWeave
import GlassWeaveShaderTypes

/// The CPU/GPU layout boundary: host layout assertions plus a GPU round-trip
/// with distinctive values, so a field shifted or reordered on either side
/// fails here rather than as a subtly wrong image.
struct ShaderLayoutTests {
    @Test func `Host layout of the background uniforms matches the documented record`() {
        #expect(MemoryLayout<GWBackgroundUniforms>.size == 40)
        #expect(MemoryLayout<GWBackgroundUniforms>.alignment == 8)
        #expect(MemoryLayout<GWBackgroundUniforms>.stride == 40)
        #expect(MemoryLayout<GWBackgroundUniforms>.offset(of: \.uvFromDestinationX) == 0)
        #expect(MemoryLayout<GWBackgroundUniforms>.offset(of: \.uvFromDestinationY) == 8)
        #expect(MemoryLayout<GWBackgroundUniforms>.offset(of: \.uvOrigin) == 16)
        #expect(MemoryLayout<GWBackgroundUniforms>.offset(of: \.sampleClampMin) == 24)
        #expect(MemoryLayout<GWBackgroundUniforms>.offset(of: \.sampleClampMax) == 32)
    }

    @Test func `Shader reads every uniform field at the host's offsets`() async throws {
        let gpu = try GPUContext()
        let library = try gpu.device.makeDefaultLibrary(bundle: .module)
        let function = try #require(library.makeFunction(name: "gw_test_background_uniforms_probe"))
        let pipeline = try await gpu.device.makeComputePipelineState(function: function)

        // Distinctive, exactly representable values: a shifted or swapped
        // field shows up as a specific wrong number.
        var record = GWBackgroundUniforms(
            uvFromDestinationX: [1.5, -2.25],
            uvFromDestinationY: [3.125, -4.0625],
            uvOrigin: [5.5, -6.75],
            sampleClampMin: [0.03125, 0.0625],
            sampleClampMax: [7.875, -8.5]
        )
        let expected: [Float] = [1.5, -2.25, 3.125, -4.0625, 5.5, -6.75, 0.03125, 0.0625, 7.875, -8.5]
        let recordBuffer = try #require(gpu.device.makeBuffer(bytes: &record, length: MemoryLayout<GWBackgroundUniforms>.stride, options: .storageModeShared))
        let values = try #require(gpu.device.makeBuffer(length: expected.count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let layout = try #require(gpu.device.makeBuffer(length: 7 * MemoryLayout<UInt32>.stride, options: .storageModeShared))

        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(recordBuffer, offset: 0, index: 0)
        encoder.setBuffer(values, offset: 0, index: 1)
        encoder.setBuffer(layout, offset: 0, index: 2)
        let one = MTLSize(width: 1, height: 1, depth: 1)
        encoder.dispatchThreadgroups(one, threadsPerThreadgroup: one)
        encoder.endEncoding()
        #expect(await commandBuffer.commitAndWait() == .completed)

        let readValues = Array(UnsafeBufferPointer(start: values.contents().assumingMemoryBound(to: Float.self), count: expected.count))
        #expect(readValues == expected)
        let readLayout = Array(UnsafeBufferPointer(start: layout.contents().assumingMemoryBound(to: UInt32.self), count: 7))
        #expect(readLayout == [40, 8, 0, 8, 16, 24, 32])
    }

    @Test func `Host layout of the glass uniforms matches the documented record`() {
        #expect(MemoryLayout<GWGlassUniforms>.size == 1056)
        #expect(MemoryLayout<GWGlassUniforms>.alignment == 16)
        #expect(MemoryLayout<GWGlassUniforms>.stride == 1056)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.background) == 0)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.targetSize) == 40)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.panelCenter) == 48)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.panelHalfSize) == 56)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.cornerRadius) == 64)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.bezelWidth) == 68)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.normalRadius) == 72)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.maxDisplacement) == 76)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.edgeHighlight) == 80)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.tint) == 96)
        // The glow (GW-17) follows the GW-05 fields, which keep their layout.
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowColor0) == 112)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowColor1) == 128)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowColor2) == 144)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowColor3) == 160)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowStopTurns) == 176)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowLightDirection) == 192)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowStopCount) == 200)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowRimWidth) == 204)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowRimFeather) == 208)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowRimIntensity) == 212)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowInnerRadius) == 216)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowInnerIntensity) == 220)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowCenterOpacity) == 224)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowDirectionality) == 228)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowNormalRadius) == 232)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding3) == 236)
        // The halo (GW-18) follows the GW-17 fields, which keep their layout.
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowHaloRadius) == 240)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.glowHaloIntensity) == 244)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding4) == 248)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding5) == 252)
        // The interior (GW-19) follows the GW-18 fields, which keep their layout.
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorColor0) == 256)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorColor1) == 272)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorColor2) == 288)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorEffect) == 304)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorColorCount) == 308)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorSeed) == 312)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorIntensity) == 316)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorPhase) == 320)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorCenterFade) == 324)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorPixelsPerPoint) == 328)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding6) == 332)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.interiorSparks) == 336)
        // The inner light (GW-21) follows the GW-19 fields, which keep their layout.
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightEmitterCount) == 528)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightComposite) == 532)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightCenterFade) == 536)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightPiping) == 540)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightPipingWidth) == 544)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightBodyScale) == 548)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding7) == 552)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding8) == 556)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lightEmitters) == 560)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensProfile) == 1008)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensThickness) == 1012)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensBevel) == 1016)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensFieldRadius) == 1020)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensIOR) == 1024)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensMaximumOffset) == 1028)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensOffsetScale) == 1032)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensProfileA) == 1036)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.lensProfileB) == 1040)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding9) == 1044)
        #expect(MemoryLayout<GWGlassUniforms>.offset(of: \.padding11) == 1052)
        #expect(MemoryLayout<GWLightEmitter>.size == 112)
        #expect(MemoryLayout<GWLightEmitter>.alignment == 16)
        #expect(MemoryLayout<GWLightEmitter>.stride == 112)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.color0) == 0)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.color1) == 16)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.color2) == 32)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.color3) == 48)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.shape) == 64)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.motion) == 80)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.kind) == 96)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.colorCount) == 100)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.intensity) == 104)
        #expect(MemoryLayout<GWLightEmitter>.offset(of: \.seed) == 108)
        // The effect codes the shader switches on.
        #expect(GWInteriorEffectNone.rawValue == 0 && GWInteriorEffectEnergy.rawValue == 1)
        #expect(GWInteriorEffectRays.rawValue == 2 && GWInteriorEffectEmbers.rawValue == 3)
    }

    /// A distinctive, exactly representable light emitter `index` (GW-21).
    private static func emitter(_ index: Int) -> GWLightEmitter {
        let i = Float(index)
        return GWLightEmitter(
            color0: [0.5 + i * 0.0625, 0.25, 0.125, -11], color1: [0.0625, 0.75 - i * 0.0625, 0.875, -12],
            color2: [0.9375, 0.03125, 0.40625 + i * 0.0625, -13], color3: [0.15625, 0.6875, 0.59375, -14 - i],
            shape: [-0.625 + i, 0.84375, 12.5 * (i + 1), 1.75], motion: [0.375 + i, -0.1875, 0.28125, 96.5 + i],
            kind: UInt32(1 + index), colorCount: UInt32(4 - index), intensity: 0.703125 - i * 0.0625,
            seed: 0xc0ffee00 &+ UInt32(index)
        )
    }

    /// A distinctive, exactly representable spark for lane `index`.
    private static func spark(_ index: Int) -> SIMD4<Float> {
        let i = Float(index)
        return SIMD4(-40.5 + i * 7.25, 12.125 - i * 3.5, 1.75 + i * 0.0625, 0.03125 * (i + 1))
    }

    @Test func `Shader reads every glass uniform field at the host's offsets`() async throws {
        let gpu = try GPUContext()
        let library = try gpu.device.makeDefaultLibrary(bundle: .module)
        let function = try #require(library.makeFunction(name: "gw_test_glass_uniforms_probe"))
        let pipeline = try await gpu.device.makeComputePipelineState(function: function)

        // Distinctive, exactly representable values, with nonzero padding so
        // a field read from the padding shows up as a wrong number.
        var record = GWGlassUniforms(
            background: GWBackgroundUniforms(
                uvFromDestinationX: [1.5, -2.25],
                uvFromDestinationY: [3.125, -4.0625],
                uvOrigin: [5.5, -6.75],
                sampleClampMin: [0.03125, 0.0625],
                sampleClampMax: [7.875, -8.5]
            ),
            targetSize: [1179, 2556],
            panelCenter: [589.5, 1278.25],
            panelHalfSize: [480, 270.5],
            cornerRadius: 84,
            bezelWidth: 48.5,
            normalRadius: 84.25,
            maxDisplacement: 14.5,
            edgeHighlight: 0.125,
            padding0: -999, padding1: -998, padding2: -997,
            tint: [0.0078125, 0.25, 0.75, 0.375],
            glowColor0: [0.5, 0.25, 0.125, -1],
            glowColor1: [0.0625, 0.75, 0.875, -2],
            glowColor2: [0.9375, 0.03125, 0.40625, -3],
            glowColor3: [0.15625, 0.6875, 0.59375, -4],
            glowStopTurns: [0.0, 0.125, 0.5625, 0.9375],
            glowLightDirection: [0.625, -0.78125],
            glowStopCount: 3,
            glowRimWidth: 4.5,
            glowRimFeather: 2.75,
            glowRimIntensity: 0.875,
            glowInnerRadius: 72.25,
            glowInnerIntensity: 0.4375,
            glowCenterOpacity: 0.1875,
            glowDirectionality: 0.65625,
            glowNormalRadius: 90.5,
            padding3: -996,
            glowHaloRadius: 36.75,
            glowHaloIntensity: 0.34375,
            padding4: -995, padding5: -994,
            interiorColor0: [0.21875, 0.84375, 0.46875, -5],
            interiorColor1: [0.71875, 0.09375, 0.53125, -6],
            interiorColor2: [0.28125, 0.96875, 0.015625, -7],
            interiorEffect: 3,
            interiorColorCount: 2,
            interiorSeed: 0xdeadbeef,
            interiorIntensity: 0.828125,
            interiorPhase: 41.25,
            interiorCenterFade: 0.671875,
            interiorPixelsPerPoint: 2.5,
            padding6: -993,
            interiorSparks: (
                Self.spark(0), Self.spark(1), Self.spark(2), Self.spark(3), Self.spark(4), Self.spark(5),
                Self.spark(6), Self.spark(7), Self.spark(8), Self.spark(9), Self.spark(10), Self.spark(11)
            ),
            lightEmitterCount: 3,
            lightComposite: 1,
            lightCenterFade: 0.859375,
            lightPiping: 0.296875,
            lightPipingWidth: 33.5,
            lightBodyScale: 0.5625,
            padding7: -992, padding8: -991,
            lightEmitters: (Self.emitter(0), Self.emitter(1), Self.emitter(2), Self.emitter(3)),
            lensProfile: 5,
            lensThickness: 24.5,
            lensBevel: 18.25,
            lensFieldRadius: 21.5,
            lensIOR: 1.625,
            lensMaximumOffset: 33.75,
            lensOffsetScale: 0.8125,
            lensProfileA: 0.4375,
            lensProfileB: 0.0625,
            padding9: -990, padding10: -989, padding11: -988
        )
        let expected: [Float] = [
            1.5, -2.25, 3.125, -4.0625, 5.5, -6.75, 0.03125, 0.0625, 7.875, -8.5,
            1179, 2556, 589.5, 1278.25, 480, 270.5, 84, 48.5, 84.25, 14.5, 0.125,
            0.0078125, 0.25, 0.75, 0.375,
            0.5, 0.25, 0.125, -1, 0.0625, 0.75, 0.875, -2,
            0.9375, 0.03125, 0.40625, -3, 0.15625, 0.6875, 0.59375, -4,
            0.0, 0.125, 0.5625, 0.9375, 0.625, -0.78125, 3,
            4.5, 2.75, 0.875, 72.25, 0.4375, 0.1875, 0.65625, 90.5,
            36.75, 0.34375,
            0.21875, 0.84375, 0.46875, -5, 0.71875, 0.09375, 0.53125, -6, 0.28125, 0.96875, 0.015625, -7,
            3, 2, 0.828125, 41.25, 0.671875, 2.5,
        ] + (0..<12).flatMap { index in
            let spark = Self.spark(index)
            return [spark.x, spark.y, spark.z, spark.w]
        } + [3, 1, 0.859375, 0.296875, 33.5, 0.5625] + (0..<4).flatMap { index -> [Float] in
            let e = Self.emitter(index)
            return [e.color0, e.color1, e.color2, e.color3, e.shape, e.motion].flatMap { [$0.x, $0.y, $0.z, $0.w] }
                + [Float(e.kind), Float(e.colorCount), e.intensity]
        }
        let recordBuffer = try #require(gpu.device.makeBuffer(bytes: &record, length: MemoryLayout<GWGlassUniforms>.stride, options: .storageModeShared))
        let values = try #require(gpu.device.makeBuffer(length: expected.count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let layout = try #require(gpu.device.makeBuffer(length: 63 * MemoryLayout<UInt32>.stride, options: .storageModeShared))
        let seed = try #require(gpu.device.makeBuffer(length: 5 * MemoryLayout<UInt32>.stride, options: .storageModeShared))

        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(recordBuffer, offset: 0, index: 0)
        encoder.setBuffer(values, offset: 0, index: 1)
        encoder.setBuffer(layout, offset: 0, index: 2)
        encoder.setBuffer(seed, offset: 0, index: 3)
        let one = MTLSize(width: 1, height: 1, depth: 1)
        encoder.dispatchThreadgroups(one, threadsPerThreadgroup: one)
        encoder.endEncoding()
        #expect(await commandBuffer.commitAndWait() == .completed)

        let readValues = Array(UnsafeBufferPointer(start: values.contents().assumingMemoryBound(to: Float.self), count: expected.count))
        #expect(readValues == expected)
        // The seed is read as an integer, all 32 bits.
        let readSeeds = Array(UnsafeBufferPointer(start: seed.contents().assumingMemoryBound(to: UInt32.self), count: 5))
        #expect(readSeeds == [0xdeadbeef] + (0..<4).map { Self.emitter($0).seed })
        let readLayout = Array(UnsafeBufferPointer(start: layout.contents().assumingMemoryBound(to: UInt32.self), count: 63))
        #expect(readLayout == [
            1056, 16, 0, 40, 48, 56, 64, 68, 72, 76, 80, 96,
            112, 128, 144, 160, 176, 192, 200, 204, 208, 212, 216, 220, 224, 228, 232,
            240, 244,
            256, 272, 288, 304, 308, 312, 316, 320, 324, 328, 332,
            0, 336,
            528, 532, 536, 540, 544, 548, 552, 556, 560,
            112, 16, 0, 16, 32, 48, 64, 80, 96, 100, 104, 108,
        ])
    }
}

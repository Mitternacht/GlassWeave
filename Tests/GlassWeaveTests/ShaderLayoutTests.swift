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
        #expect(MemoryLayout<GWGlassUniforms>.size == 112)
        #expect(MemoryLayout<GWGlassUniforms>.alignment == 16)
        #expect(MemoryLayout<GWGlassUniforms>.stride == 112)
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
            tint: [0.0078125, 0.25, 0.75, 0.375]
        )
        let expected: [Float] = [
            1.5, -2.25, 3.125, -4.0625, 5.5, -6.75, 0.03125, 0.0625, 7.875, -8.5,
            1179, 2556, 589.5, 1278.25, 480, 270.5, 84, 48.5, 84.25, 14.5, 0.125,
            0.0078125, 0.25, 0.75, 0.375,
        ]
        let recordBuffer = try #require(gpu.device.makeBuffer(bytes: &record, length: MemoryLayout<GWGlassUniforms>.stride, options: .storageModeShared))
        let values = try #require(gpu.device.makeBuffer(length: expected.count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let layout = try #require(gpu.device.makeBuffer(length: 12 * MemoryLayout<UInt32>.stride, options: .storageModeShared))

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
        let readLayout = Array(UnsafeBufferPointer(start: layout.contents().assumingMemoryBound(to: UInt32.self), count: 12))
        #expect(readLayout == [112, 16, 0, 40, 48, 56, 64, 68, 72, 76, 80, 96])
    }
}

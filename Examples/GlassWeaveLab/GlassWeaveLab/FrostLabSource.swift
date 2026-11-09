import CoreGraphics
import GlassWeave
import Metal
import UIKit

/// The frost screen's still background: an original, procedural picture made
/// to show what a blur does (saturated discs of many sizes, fine lines, a
/// hard-edged word) rather than to look like anything. A different frame ID
/// shifts its hues, so a new frame is visibly new.
struct FrostLabSource {
    static let width = 900
    static let height = 1600

    let queue: any MTLCommandQueue

    /// The picture as BGRA bytes, premultiplied-first little-endian, opaque.
    static func bgra(hueShift: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            // UIKit's top-left origin.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let size = CGSize(width: width, height: height)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            func color(_ hue: Double, _ saturation: Double, _ brightness: Double, _ alpha: Double = 1) -> CGColor {
                UIColor(hue: (hue + hueShift).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: alpha).cgColor
            }
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [color(0.62, 0.8, 0.22), color(0.78, 0.7, 0.35), color(0.02, 0.8, 0.45)] as CFArray,
                locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.4, y: size.height), options: [])
            }
            // Discs from a fixed sequence, so every frame has the same layout.
            var seed: UInt64 = 0x9E37_79B9
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 33) / Double(1 << 31)
            }
            for index in 0..<46 {
                let radius = 18 + next() * next() * 150
                let center = CGPoint(x: next() * size.width, y: next() * size.height)
                context.setFillColor(color(next(), 0.55 + next() * 0.45, 0.65 + next() * 0.35, 0.9))
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                if index % 3 == 0 {
                    context.setStrokeColor(UIColor(white: 1, alpha: 0.85).cgColor)
                    context.setLineWidth(2)
                    context.strokeEllipse(in: CGRect(x: center.x - radius * 0.6, y: center.y - radius * 0.6, width: radius * 1.2, height: radius * 1.2))
                }
            }
            // Fine lines: the first thing a blur removes.
            context.setStrokeColor(UIColor(white: 1, alpha: 0.7).cgColor)
            context.setLineWidth(1.5)
            for x in stride(from: 0, through: width, by: 60) {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
            }
            for y in stride(from: 0, through: height, by: 60) {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
            }
            context.strokePath()
            // A hard-edged word.
            UIGraphicsPushContext(context)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: "FROST", attributes: [
                .font: UIFont.systemFont(ofSize: 250, weight: .black),
                .foregroundColor: UIColor(white: 1, alpha: 0.95),
                .paragraphStyle: paragraph,
            ])
            text.draw(in: CGRect(x: 0, y: size.height * 0.5 - 150, width: size.width, height: 300))
            UIGraphicsPopContext()
        }
        return bytes
    }

    /// Makes frame `frameID`, uploaded by a blit committed to the renderer's
    /// queue so same-queue readiness holds.
    func makeFrame(frameID: UInt64) -> BackgroundFrameLease? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat,
            width: Self.width, height: Self.height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let device = queue.device
        let bytes = Self.bgra(hueShift: Double(frameID - 1) * 0.12)
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        texture.label = "GlassWeaveLab frost source \(frameID)"
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: Self.width * 4, sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.label = "GlassWeaveLab frost source upload \(frameID)"
        commandBuffer.commit()
        let frame = BackgroundFrame(
            texture: texture, frameID: frameID, timestamp: .milliseconds(Int(frameID)),
            colorConvention: .sRGBOpaque, readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: { _ in })
    }
}

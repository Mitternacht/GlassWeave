import CoreGraphics
import UIKit

/// An image redrawn upright into 8-bit sRGB RGBA memory, row 0 on top.
struct SRGBPixels {
    struct Failure: Error {}

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure() }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Flip so UIKit drawing (origin top-left) lands with row 0 on top,
            // and let UIImage apply its orientation.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { throw Failure() }
        self.width = width
        self.height = height
        self.bytes = pixels
    }

    func color(x: Int, y: Int) -> (Int, Int, Int) {
        let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}

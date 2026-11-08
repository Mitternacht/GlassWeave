/// A deterministic four-corner test image for checking source orientation,
/// cropping, and color handling.
///
/// The upright image has four quadrants with distinct saturated colors (red,
/// green, blue, yellow) and a mid-gray square at its center. Any rotation or
/// mirroring moves at least one corner color, every corner stands out against
/// light and dark backgrounds, and the gray square checks that sRGB decode on
/// read and encode on write cancel out.
///
/// Pixels are sRGB-encoded 8-bit BGRA, matching
/// ``BackgroundColorConvention/sRGBOpaque``.
public struct OrientationPattern: Sendable {
    /// One sRGB-encoded color, in byte order blue, green, red, alpha.
    public struct Color: Hashable, Sendable {
        public let blue: UInt8
        public let green: UInt8
        public let red: UInt8
        public let alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.blue = blue
            self.green = green
            self.red = red
            self.alpha = alpha
        }
    }

    public static let topLeft = Color(red: 255, green: 0, blue: 0)
    public static let topRight = Color(red: 0, green: 255, blue: 0)
    public static let bottomLeft = Color(red: 0, green: 0, blue: 255)
    public static let bottomRight = Color(red: 255, green: 255, blue: 0)
    /// sRGB 128: a mid-tone whose round trip through linear light is visible.
    public static let center = Color(red: 128, green: 128, blue: 128)

    public let width: Int
    public let height: Int

    /// - Precondition: `width` and `height` are at least 2.
    public init(width: Int, height: Int) {
        precondition(width >= 2 && height >= 2, "The pattern needs at least 2 x 2 pixels")
        self.width = width
        self.height = height
    }

    /// The color of the upright pixel at column `x`, row `y` (row 0 on top).
    public func color(x: Int, y: Int) -> Color {
        let side = min(width, height) / 4
        let centerX = (width - side) / 2
        let centerY = (height - side) / 2
        if x >= centerX, x < centerX + side, y >= centerY, y < centerY + side {
            return Self.center
        }
        let left = x < width / 2
        let top = y < height / 2
        switch (top, left) {
        case (true, true): return Self.topLeft
        case (true, false): return Self.topRight
        case (false, true): return Self.bottomLeft
        case (false, false): return Self.bottomRight
        }
    }

    /// Tightly packed BGRA bytes, rows top to bottom (`width * 4` bytes per row).
    public func bgraBytes() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = color(x: x, y: y)
                bytes.append(color.blue)
                bytes.append(color.green)
                bytes.append(color.red)
                bytes.append(color.alpha)
            }
        }
        return bytes
    }
}

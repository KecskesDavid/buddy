import AppKit

/// Draws the user's red stroke onto the screenshot and encodes it for Claude.
enum ScreenshotAnnotator {
    static func annotate(_ image: CGImage, with shape: DrawnShape) -> CGImage? {
        let width = image.width, height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Global points (bottom-left origin) → image pixels (CGContext is also bottom-left origin).
        let frame = shape.screen.frame
        let sx = CGFloat(width) / frame.width
        let sy = CGFloat(height) / frame.height
        let pixels = shape.points.map { CGPoint(x: ($0.x - frame.minX) * sx, y: ($0.y - frame.minY) * sy) }

        context.setStrokeColor(BuddyColors.stroke.cgColor)
        context.setLineWidth(max(3, 3 * sx))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: pixels)
        context.strokePath()

        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

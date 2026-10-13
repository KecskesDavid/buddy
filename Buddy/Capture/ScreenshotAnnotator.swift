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

    /// Claude's answer time grows with the image bytes (Haiku, measured: ~680 KB ≈ 11 s, ~250 KB ≈ 5 s),
    /// so step the JPEG quality down until it fits the budget.
    static func jpegData(_ image: CGImage, maxBytes: Int = 250 * 1024) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        var data: Data?
        for quality: CGFloat in [0.6, 0.45, 0.3] {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
            if let data, data.count <= maxBytes { break }
        }
        return data
    }
}

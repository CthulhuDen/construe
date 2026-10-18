import AppKit
import CoreGraphics

/// Prepares a pasted screenshot for the Messages API.
enum ImageAttachment {
    /// Longer images are scaled down; larger sizes cost more tokens without helping the model.
    static let maxLongEdge = 1568

    static func pngData(for image: CGImage) -> Data? {
        let image = downscaled(image) ?? image
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Returns `image` scaled so its longer edge is at most `maxLongEdge`, or unchanged if it already fits.
    static func downscaled(_ image: CGImage) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }

        let scale = Double(maxLongEdge) / Double(longEdge)
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turning an image into the PNG bytes an attachment stores.
///
/// In Core, and built on CoreGraphics + ImageIO rather than NSImage or UIImage, because both apps
/// need the identical answer: a screenshot pasted on the Mac and one picked on the phone should
/// produce the same kind of file, and duplicating the resize maths is how they'd stop doing that.
/// Neither framework is UI — no window, no view, no main actor — so this stays unit-testable.
public enum ImageBytes {

    /// Longest edge, in pixels.
    ///
    /// A retina screenshot is several megabytes, and every one of those bytes gets uploaded to the
    /// transport and downloaded again by each device. Enough pixels to see what's wrong is the whole
    /// requirement.
    public static let maxDimension = 1600

    /// The size an image should be stored at: unchanged if it's already small enough, otherwise
    /// scaled to fit `maxDimension` with its aspect ratio kept.
    ///
    /// Split out from the encoding so the arithmetic can be tested without a real image.
    public static func targetSize(width: Int, height: Int,
                                  maxDimension: Int = maxDimension) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        // Never round down to nothing: a 4000×1 strip would otherwise become zero-height and fail
        // to encode at all.
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// PNG bytes for `image`, downscaled if it's bigger than `maxDimension`.
    public static func png(from image: CGImage, maxDimension: Int = maxDimension) -> Data? {
        let target = targetSize(width: image.width, height: image.height,
                                maxDimension: maxDimension)
        guard target.width != image.width || target.height != image.height else {
            return encode(image)
        }
        guard let context = CGContext(
            data: nil, width: target.width, height: target.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? image.colorSpace
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return encode(image) }   // full size beats no image at all
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return encode(context.makeImage() ?? image)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

import AppKit
import UniformTypeIdentifiers

/// Getting a screenshot out of the clipboard (or off a drop) and into PNG bytes.
///
/// Everything is normalised to PNG and scaled down on the way in. A retina screenshot is several
/// megabytes of TIFF, and every one of those bytes would be uploaded to Drive and downloaded again
/// by each device — a feedback note doesn't need more than enough pixels to see what's wrong.
enum ClipboardImage {
    /// Longest edge, in pixels.
    static let maxDimension: CGFloat = 1600

    static func png() -> Data? {
        let board = NSPasteboard.general
        // Ask for the image types first, then fall back to a file URL: dragging a screenshot from
        // the desktop puts a URL on the board, not pixels.
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return png(from: image)
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            return png(from: image)
        }
        return nil
    }

    /// Drop handler: providers are resolved asynchronously, so this hands the result back.
    static func png(from providers: [NSItemProvider], completion: @escaping (Data?) -> Void) {
        guard let provider = providers.first else { return completion(nil) }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                let data = (object as? NSImage).flatMap(png(from:))
                DispatchQueue.main.async { completion(data) }
            }
            return
        }
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            let data = (object as? URL).flatMap(NSImage.init(contentsOf:)).flatMap(png(from:))
            DispatchQueue.main.async { completion(data) }
        }
    }

    static func png(from image: NSImage) -> Data? {
        guard let source = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        else { return nil }

        // pixelsWide, not size.width: `size` is in points, so on a retina display it reports half
        // the real resolution and the image would be scaled to twice the intended size.
        let w = CGFloat(source.pixelsWide), h = CGFloat(source.pixelsHigh)
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return source.representation(using: .png, properties: [:]) }

        let target = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let cg = source.cgImage
        else { return source.representation(using: .png, properties: [:]) }

        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else {
            return source.representation(using: .png, properties: [:])
        }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

import AppKit
import TimesliceCore
import UniformTypeIdentifiers

/// Getting a screenshot out of the clipboard (or off a drop) and into PNG bytes.
///
/// Everything is normalised to PNG and scaled down on the way in — see `ImageBytes`, which both
/// apps share so a screenshot is stored the same way whichever one took it.
enum ClipboardImage {
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

    /// The `NSImage` → `CGImage` step is all that's platform-specific; the resize and encode live
    /// in `ImageBytes` so the phone produces byte-identical output for the same picture.
    static func png(from image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        return ImageBytes.png(from: cg)
    }
}

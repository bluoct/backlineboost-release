import AppKit
import BackbeatCore
import ImageIO

/// NSImage is safe to share once fully constructed and never mutated; the
/// box opts that guarantee into Sendable for the Core cache actor.
struct ArtworkThumbnail: @unchecked Sendable {
    let image: NSImage
}

/// App-wide artwork thumbnail repository (EFF-004): ImageIO downsamples to
/// the requested tile pixel size at decode time — the full-resolution
/// bitmap never materializes — and the shared store byte-budgets what it
/// keeps.
enum ArtworkThumbnails {
    static let store = ThumbnailStore<ArtworkThumbnail>(totalCostLimit: 32 * 1024 * 1024) { url, pixelSize in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image: ArtworkThumbnail(image: image), byteCost: cgImage.bytesPerRow * cgImage.height)
    }
}

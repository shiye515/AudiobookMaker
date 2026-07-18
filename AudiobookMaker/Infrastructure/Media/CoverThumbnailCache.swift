import CoreGraphics
import Foundation
import ImageIO

actor CoverThumbnailCache {
    static let shared = CoverThumbnailCache()

    private struct Key: Hashable {
        let url: URL
        let maximumPixelSize: Int
    }

    private var images: [Key: CGImage] = [:]

    func image(at url: URL, maximumPixelSize: Int) async -> CGImage? {
        let key = Key(url: url, maximumPixelSize: maximumPixelSize)
        if let cached = images[key] { return cached }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let image { images[key] = image }
        if images.count > 100 { images.remove(at: images.startIndex) }
        return image
    }
}

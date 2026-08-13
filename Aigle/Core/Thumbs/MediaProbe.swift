import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os.log

/// A `CGImage` box that is safe to hand between concurrency domains.
/// `CGImage` is immutable once created; the box makes that promise explicit.
public struct RenderedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }

    public var nsImage: NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

public struct MediaDimensions: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Reads intrinsic sizes and renders downsampled previews for every format Aigle supports.
public enum MediaProbe {
    private static let log = Logger(subsystem: "cool.aigle.Aigle", category: "media")

    // MARK: - Dimensions

    public static func dimensions(of url: URL, kind: ItemKind) async -> MediaDimensions? {
        switch kind {
        case .image, .animatedImage:
            return imageDimensions(url)
        case .vector:
            return vectorDimensions(url)
        case .document:
            return pdfDimensions(url)
        case .video:
            return await videoDimensions(url)
        case .audio, .link, .other:
            return nil
        }
    }

    static func imageDimensions(_ url: URL) -> MediaDimensions? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { return nil }
        // Honour EXIF orientation so portrait photos aren't reported landscape.
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapped = orientation >= 5 && orientation <= 8
        return MediaDimensions(width: swapped ? height : width, height: swapped ? width : height)
    }

    static func vectorDimensions(_ url: URL) -> MediaDimensions? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return MediaDimensions(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    static func pdfDimensions(_ url: URL) -> MediaDimensions? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return MediaDimensions(width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()))
    }

    static func videoDimensions(_ url: URL) async -> MediaDimensions? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let size = natural.applying(transform)
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())
        guard width > 0, height > 0 else { return nil }
        return MediaDimensions(width: width, height: height)
    }

    // MARK: - Rendering

    /// Renders a preview no larger than `maxPixel` on the long edge.
    public static func render(url: URL, kind: ItemKind, maxPixel: Int) async -> RenderedImage? {
        let direct: RenderedImage?
        switch kind {
        case .image, .animatedImage: direct = downsample(url, maxPixel: maxPixel)
        case .vector: direct = renderVector(url, maxPixel: maxPixel)
        case .document: direct = renderPDF(url, maxPixel: maxPixel)
        case .video: direct = await videoPosterFrame(url, maxPixel: maxPixel)
        case .audio, .other, .link: direct = nil
        }
        if let direct { return direct }
        return await quickLook(url, maxPixel: maxPixel)
    }

    /// ImageIO downsampling — the fast path, never fully decoding the original.
    public static func downsample(_ url: URL, maxPixel: Int) -> RenderedImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return RenderedImage(image)
    }

    static func renderVector(_ url: URL, maxPixel: Int) -> RenderedImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let scale = min(CGFloat(maxPixel) / max(natural.width, natural.height), 8)
        let target = NSSize(width: max(1, natural.width * scale), height: max(1, natural.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: natural),
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage.map(RenderedImage.init)
    }

    static func renderPDF(_ url: URL, maxPixel: Int) -> RenderedImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixel) / max(box.width, box.height)
        let pixelWidth = max(1, Int((box.width * scale).rounded()))
        let pixelHeight = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: CGFloat(pixelWidth) / box.width, y: CGFloat(pixelHeight) / box.height)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        return context.makeImage().map(RenderedImage.init)
    }

    /// A poster frame slightly past t=0, because the first frame is often black.
    public static func videoPosterFrame(_ url: URL, maxPixel: Int) async -> RenderedImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let sample = duration > 1
            ? CMTime(seconds: min(1, duration * 0.1), preferredTimescale: 600)
            : .zero
        guard let result = try? await generator.image(at: sample) else { return nil }
        return RenderedImage(result.image)
    }

    /// Exact-frame extraction for ⌘⇧S in the expanded player.
    public static func exactVideoFrame(_ url: URL, at seconds: Double) async -> RenderedImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return RenderedImage(result.image)
    }

    static func quickLook(_ url: URL, maxPixel: Int) async -> RenderedImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation.map { RenderedImage($0.cgImage) }
    }

    // MARK: - Encoding

    public static func pngData(_ image: RenderedImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    public static func jpegData(_ image: RenderedImage, quality: Double = 0.82) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

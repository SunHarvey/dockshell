import CoreGraphics
import Foundation
import ImageIO

/// Decoded approved artwork, resolved only from the explicitly supplied app resources.
/// Load together with localization off the main actor; views reuse the immutable image.
public struct DockShellBrand: Sendable {
    public static let resourceName = "DockShellMark"
    public static let resourceDirectory = "Branding"
    public let image: CGImage

    init(resourceBundle: Bundle) throws {
        guard let url = resourceBundle.url(forResource: Self.resourceName, withExtension: "png",
                                          subdirectory: Self.resourceDirectory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [
                NSFilePathErrorKey: resourceBundle.bundleURL
                    .appendingPathComponent(Self.resourceDirectory)
                    .appendingPathComponent(Self.resourceName + ".png").path,
            ])
        }
        let data = try Data(contentsOf: url)
        let options = [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, options),
              decoded.width > 0, decoded.height > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        image = decoded
    }
}

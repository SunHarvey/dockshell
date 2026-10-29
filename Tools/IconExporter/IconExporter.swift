import CoreGraphics
import Foundation
import ImageIO

private struct ExportFailure: Error, CustomStringConvertible {
    let description: String
}

/// Resamples approved artwork with ImageIO and wraps the PNGs in standard ICNS elements.
/// Explicit Retina tags avoid the system ICNS encoder silently discarding some sizes.
private enum IconExporter {
    static func run(sourceURL: URL, iconURL: URL, markURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == height, width >= 1024 else {
            throw ExportFailure(description: "Icon master must be a square image of at least 1024 pixels.")
        }
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        var pngs: [Int: Data] = [:]
        for size in sizes {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width == size, image.height == size else {
                throw ExportFailure(description: "Could not export the \(size)-pixel icon representation.")
            }
            pngs[size] = try encodePNG(image)
        }

        // Each element carries its intended point/scale role, even where pixel sizes match.
        // ICNS lengths include their 8-byte headers and use unsigned big-endian integers.
        let elements: [(tag: String, pixels: Int)] = [
            ("icp4", 16), ("ic11", 32),
            ("icp5", 32), ("ic12", 64),
            ("ic07", 128), ("ic13", 256),
            ("ic08", 256), ("ic14", 512),
            ("ic09", 512), ("ic10", 1024),
        ]
        var payload = Data()
        for element in elements {
            guard let png = pngs[element.pixels] else {
                throw ExportFailure(description: "An encoded icon representation is missing.")
            }
            payload.append(Data(element.tag.utf8))
            try appendLength(png.count + 8, to: &payload)
            payload.append(png)
        }
        var icon = Data("icns".utf8)
        try appendLength(payload.count + 8, to: &icon)
        icon.append(payload)
        try icon.write(to: iconURL, options: .atomic)

        // Read back with the same system decoder used by macOS icon consumers.
        guard let result = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
              CGImageSourceGetType(result) as String? == "com.apple.icns",
              CGImageSourceGetCount(result) == elements.count else {
            throw ExportFailure(description: "The exported ICNS could not be decoded.")
        }
        var decodedSizes = Set<Int>()
        for index in 0..<CGImageSourceGetCount(result) {
            guard let image = CGImageSourceCreateImageAtIndex(result, index, nil), image.width == image.height else {
                throw ExportFailure(description: "An exported icon representation is invalid.")
            }
            decodedSizes.insert(image.width)
        }
        guard decodedSizes == Set(sizes) else {
            throw ExportFailure(description: "The exported icon is missing a required pixel size.")
        }
        guard let mark = pngs[256] else {
            throw ExportFailure(description: "The in-app branding representation is missing.")
        }
        try mark.write(to: markURL, options: .atomic)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        guard let buffer = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else {
            throw ExportFailure(description: "The system PNG writer is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportFailure(description: "Could not encode an icon PNG representation.")
        }
        return buffer as Data
    }

    private static func appendLength(_ length: Int, to data: inout Data) throws {
        guard let value = UInt32(exactly: length) else {
            throw ExportFailure(description: "The icon exceeds the ICNS container size limit.")
        }
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw ExportFailure(description: "Usage: IconExporter.swift MASTER.png OUTPUT.icns MARK.png")
    }
    try IconExporter.run(sourceURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                         iconURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                         markURL: URL(fileURLWithPath: CommandLine.arguments[3]))
} catch {
    FileHandle.standardError.write(Data(("Icon export failed: \(error)\n").utf8))
    exit(EXIT_FAILURE)
}

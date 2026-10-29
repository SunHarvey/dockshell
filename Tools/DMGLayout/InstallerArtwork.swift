import AppKit
import Foundation

/// Draws the installer background with native AppKit primitives and the approved mark.
/// Both bitmap representations have the same point size, so Finder lays out Retina
/// and standard-resolution windows consistently without a separate image dependency.
@MainActor
enum InstallerArtwork {
    static let size = NSSize(width: 660, height: 440)

    enum ArtworkError: Error, CustomStringConvertible {
        case invalidMark
        case unavailableBitmap
        case encodingFailed
        case unsupportedDestination

        var description: String {
            switch self {
            case .invalidMark: "The approved DockShell brand mark could not be decoded."
            case .unavailableBitmap: "The system could not create the installer artwork canvas."
            case .encodingFailed: "The system could not encode the installer background."
            case .unsupportedDestination: "Installer artwork must be written as TIFF or PNG."
            }
        }
    }

    /// Creates a multi-resolution TIFF for Finder or a Retina PNG for visual review.
    /// Visible instructions are supplied by the installer's String Catalog reader.
    static func render(
        to destination: URL,
        brandMark: URL,
        instructionChinese: String,
        instructionEnglish: String
    ) throws {
        guard let mark = NSImage(contentsOf: brandMark), mark.isValid else {
            throw ArtworkError.invalidMark
        }
        let representations = try [1, 2].map { scale in
            try draw(scale: scale, mark: mark, instructionChinese: instructionChinese,
                     instructionEnglish: instructionEnglish)
        }
        let data: Data?
        switch destination.pathExtension.lowercased() {
        case "tiff", "tif":
            data = NSBitmapImageRep.representationOfImageReps(
                in: representations, using: .tiff, properties: [:])
        case "png":
            data = representations[1].representation(using: .png, properties: [:])
        default:
            throw ArtworkError.unsupportedDestination
        }
        guard let data else { throw ArtworkError.encodingFailed }
        try data.write(to: destination, options: .atomic)
    }

    private static func draw(
        scale: Int,
        mark: NSImage,
        instructionChinese: String,
        instructionEnglish: String
    ) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ArtworkError.unavailableBitmap
        }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = bitmapContext.cgContext
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let navy = color(0x103C58)
        let muted = color(0x647481)
        let canvas = NSRect(origin: .zero, size: size)

        // A warm paper surface keeps Finder's native dark icon labels readable.
        NSGradient(starting: color(0xFFFEFA), ending: color(0xF1F4F3))?
            .draw(in: canvas, angle: 76)

        let upperFold = NSBezierPath()
        upperFold.move(to: NSPoint(x: 413, y: 0))
        upperFold.line(to: NSPoint(x: 660, y: 0))
        upperFold.line(to: NSPoint(x: 660, y: 153))
        upperFold.curve(to: NSPoint(x: 413, y: 0),
                        controlPoint1: NSPoint(x: 558, y: 115),
                        controlPoint2: NSPoint(x: 475, y: 48))
        upperFold.close()
        color(0xDFE9EA).withAlphaComponent(0.48).setFill()
        upperFold.fill()

        let lowerFold = NSBezierPath()
        lowerFold.move(to: NSPoint(x: 0, y: 321))
        lowerFold.line(to: NSPoint(x: 0, y: 440))
        lowerFold.line(to: NSPoint(x: 213, y: 440))
        lowerFold.curve(to: NSPoint(x: 0, y: 321),
                        controlPoint1: NSPoint(x: 123, y: 415),
                        controlPoint2: NSPoint(x: 66, y: 360))
        lowerFold.close()
        color(0xEEE6D6).withAlphaComponent(0.32).setFill()
        lowerFold.fill()

        mark.draw(in: NSRect(x: 34, y: 31, width: 40, height: 40),
                  from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        text("DockShell", in: NSRect(x: 86, y: 35, width: 250, height: 38),
             font: .systemFont(ofSize: 25, weight: .semibold), color: navy)

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 34, y: 99))
        divider.line(to: NSPoint(x: 626, y: 99))
        divider.lineWidth = 0.75
        color(0xCFD9DC).withAlphaComponent(0.8).setStroke()
        divider.stroke()

        // Finder supplies the actual app and folder icons over these quiet wells.
        for centerX in [CGFloat(170), CGFloat(490)] {
            let well = NSBezierPath(roundedRect: NSRect(x: centerX - 75, y: 146,
                                                       width: 150, height: 154),
                                    xRadius: 26, yRadius: 26)
            NSColor.white.withAlphaComponent(0.55).setFill()
            well.fill()
            color(0xE3E8E8).withAlphaComponent(0.75).setStroke()
            well.lineWidth = 0.8
            well.stroke()
        }

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 293, y: 220))
        arrow.line(to: NSPoint(x: 366, y: 220))
        arrow.move(to: NSPoint(x: 355, y: 209))
        arrow.line(to: NSPoint(x: 366, y: 220))
        arrow.line(to: NSPoint(x: 355, y: 231))
        arrow.lineWidth = 2.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        navy.withAlphaComponent(0.68).setStroke()
        arrow.stroke()

        text(instructionChinese, in: NSRect(x: 34, y: 329, width: 592, height: 30),
             font: .systemFont(ofSize: 19, weight: .medium), color: navy, alignment: .center)
        text(instructionEnglish, in: NSRect(x: 34, y: 366, width: 592, height: 24),
             font: .systemFont(ofSize: 13, weight: .regular), color: muted, alignment: .center)

        let accent = NSBezierPath(roundedRect: NSRect(x: 313, y: 412, width: 34, height: 3),
                                 xRadius: 1.5, yRadius: 1.5)
        navy.withAlphaComponent(0.2).setFill()
        accent.fill()
        context.flush()
        return bitmap
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    private static func text(
        _ value: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        (value as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }
}

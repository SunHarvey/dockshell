import AppKit
import Darwin
import Foundation

private struct LayoutToolError: Error, CustomStringConvertible {
    let description: String
}

/// A build-only native tool: renders catalog-backed artwork, writes Finder layout
/// on a mounted scratch image, and audits the final read-only installer volume.
@main
@MainActor
private struct DMGLayoutTool {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "artwork" where arguments.count == 4:
                let payload = try directory(arguments[1])
                let instructions = try readInstructions(at: URL(fileURLWithPath: arguments[3]))
                let background = payload.appendingPathComponent(".background", isDirectory: true)
                guard !FileManager.default.fileExists(atPath: background.path) else {
                    throw LayoutToolError(description: "The installer background directory already exists.")
                }
                try FileManager.default.createDirectory(at: background, withIntermediateDirectories: false)
                let image = background.appendingPathComponent("installer.tiff")
                try InstallerArtwork.render(
                    to: image,
                    brandMark: URL(fileURLWithPath: arguments[2]),
                    instructionChinese: instructions.chinese,
                    instructionEnglish: instructions.english
                )
                try verifyArtwork(at: image)
                print("PASS installer artwork: 660 × 440 points, standard/Retina representations, en/zh-Hans catalog")
            case "write" where arguments.count == 2:
                let volume = try installerVolume(arguments[1])
                try FinderLayout.write(to: volume)
                try MetadataRegression.runBookmark(on: volume)
            case "self-test" where arguments.count == 2:
                try MetadataRegression.run(fixturesURL: directory(arguments[1]))
            case "verify" where arguments.count == 2:
                let volume = try installerVolume(arguments[1])
                try verifyArtwork(at: volume.appendingPathComponent(".background/installer.tiff"))
                try FinderLayout.verify(at: volume)
            default:
                throw LayoutToolError(description:
                    "Usage: DMGLayout artwork PAYLOAD MARK.png CATALOG.xcstrings | write VOLUME | verify VOLUME | self-test FIXTURES")
            }
        } catch {
            FileHandle.standardError.write(Data("Installer layout failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func directory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LayoutToolError(description: "Expected an existing directory, not a symlink.")
        }
        return url
    }

    private static func installerVolume(_ path: String) throws -> URL {
        let volume = try directory(path)
        let values = try volume.resourceValues(forKeys: [.isVolumeKey])
        guard values.isVolume == true,
              FileManager.default.fileExists(atPath: volume.appendingPathComponent("DockShell.app").path),
              try FileManager.default.destinationOfSymbolicLink(
                atPath: volume.appendingPathComponent("Applications").path) == "/Applications" else {
            throw LayoutToolError(description: "Expected a mounted DockShell installer with its Applications shortcut.")
        }
        return volume
    }

    private static func verifyArtwork(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let image = NSImage(contentsOf: url),
              abs(image.size.width - 660) < 0.01, abs(image.size.height - 440) < 0.01,
              let representations = NSBitmapImageRep.imageReps(withContentsOf: url) as? [NSBitmapImageRep],
              representations.count == 2 else {
            throw LayoutToolError(description: "The installer background is not a valid multi-resolution image.")
        }
        let expectedPixels = Set(["660x440", "1320x880"])
        let actualPixels = Set(representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" })
        guard actualPixels == expectedPixels,
              representations.allSatisfy({ abs($0.size.width - 660) < 0.01 && abs($0.size.height - 440) < 0.01 }) else {
            throw LayoutToolError(description: "The installer background has incorrect dimensions or Retina density.")
        }
    }

    private struct Catalog: Decodable {
        let version: String
        let sourceLanguage: String
        let strings: [String: Entry]
        struct Entry: Decodable {
            let extractionState: String
            let localizations: [String: Localization]
        }
        struct Localization: Decodable {
            let stringUnit: Unit
        }
        struct Unit: Decodable {
            let state: String
            let value: String
        }
    }

    private static func readInstructions(at url: URL) throws -> (chinese: String, english: String) {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.version == "1.0", catalog.sourceLanguage == "en",
              Set(catalog.strings.keys) == ["installer.instruction"],
              let entry = catalog.strings["installer.instruction"], entry.extractionState == "manual",
              Set(entry.localizations.keys) == ["en", "zh-Hans"],
              let chinese = entry.localizations["zh-Hans"]?.stringUnit,
              let english = entry.localizations["en"]?.stringUnit,
              chinese.state == "translated", english.state == "translated",
              [chinese.value, english.value].allSatisfy({
                  !$0.isEmpty && $0.count <= 80 && !$0.contains("\n") && !$0.contains("\0")
              }) else {
            throw LayoutToolError(description: "The installer catalog requires translated en/zh-Hans instructions.")
        }
        return (chinese.value, english.value)
    }
}

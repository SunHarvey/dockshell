import Foundation

/// Exercises the actual cross-machine background failure with a published alias.
/// The broken fixture came from the public v0.1.0 DMG (SHA-256
/// ccedc9c832f88281940e7a77a29af9da7a83dfd3eaba34ff7632a53a78d60485).
/// Its extracted AliasRecord SHA-256 is
/// 6ad18865be852da9edb568149ce8c867aaca6a8ad8ea28fe60d413d46204074a.
/// The portable fixture retains its on-volume identities and removes CI-host
/// backing-image hints; neither fixture contains client credentials or paths.
enum MetadataRegression {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Validates portable metadata and rejects the shipped failure and corruptions.
    static func run(fixturesURL: URL) throws {
        let broken = try Data(contentsOf: fixturesURL.appendingPathComponent("published-ci-background.alias"))
        let portable = try Data(contentsOf: fixturesURL.appendingPathComponent("portable-background.alias"))
        guard broken.count == 1050, portable.count == 356,
              broken.range(of: Data("/Users/runner/work/".utf8)) != nil,
              portable.suffix(4) == Data([0xff, 0xff, 0, 0]) else {
            throw Failure(description: "The installer alias regression fixtures are incomplete.")
        }
        try FinderLayout.verifyPortableAlias(portable)
        try expectRejected(broken, label: "the actual published CI-host alias")

        var absoluteOrigin = portable
        absoluteOrigin.replaceSubrange(130..<134, with: [0xff, 0xff, 0xff, 0xff])
        try expectRejected(absoluteOrigin, label: "a background alias without its Finder database origin")

        let recursive = try appending(tag: 20, value: Data("deleted-ci-scratch.dmg".utf8), to: portable)
        try expectRejected(recursive, label: "a recursive backing-image alias")
        let home = try appending(tag: 21, value: Data([0, 13]), to: portable)
        try expectRejected(home, label: "a build-user home prefix")

        var hostPath = portable
        guard let mountPath = hostPath.range(of: Data("/Volumes/DockShell".utf8)) else {
            throw Failure(description: "The portable alias fixture has no canonical mount path.")
        }
        // These strings have equal byte lengths, preserving an otherwise valid TLV.
        hostPath.replaceSubrange(mountPath, with: Data("/Users/runner/work".utf8))
        try expectRejected(hostPath, label: "a CI-specific volume mount path")

        var localTime = portable
        let utcDate = portable[38..<42].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let shifted = utcDate &+ (8 * 60 * 60)
        localTime.replaceSubrange(38..<42, with: [UInt8(truncatingIfNeeded: shifted >> 24),
            UInt8(truncatingIfNeeded: shifted >> 16), UInt8(truncatingIfNeeded: shifted >> 8),
            UInt8(truncatingIfNeeded: shifted)])
        try expectRejected(localTime, label: "a legacy date shifted by the build machine timezone")

        var malformed = portable
        malformed.replaceSubrange(152..<154, with: Data([0xff, 0xff]))
        try expectRejected(malformed, label: "an out-of-bounds alias record length")
        print("PASS installer metadata regression: portable alias accepted; published CI alias, backing-image hints, host paths, timezone shifts and malformed lengths rejected")
    }

    /// Checks the modern background bookmark against a real mounted installer.
    /// Unlike a static fixture, this exercises the native resolver with this
    /// volume's actual UUID and file IDs, including colliding volume names.
    static func runBookmark(on volumeURL: URL, otherVolume: URL? = nil) throws {
        let background = volumeURL.appendingPathComponent(".background/installer.tiff")
        let portable = try BackgroundBookmark.create(for: background, relativeTo: volumeURL)
        try BackgroundBookmark.verify(portable, volumeURL: volumeURL)
        guard portable.count < 2048, portable.prefix(4) == Data("book".utf8),
              portable.range(of: Data("/Users/".utf8)) == nil,
              portable.range(of: Data("/private/".utf8)) == nil,
              portable.range(of: Data("scratch.dmg".utf8)) == nil else {
            throw Failure(description: "The portable background bookmark retained a build-host dependency.")
        }

        try expectBookmarkRejected(Data(portable.dropLast()), on: volumeURL,
                                   label: "a truncated modern bookmark")

        var invalidOffset = portable
        invalidOffset.replaceSubrange(48..<52, with: [0xff, 0xff, 0xff, 0xff])
        try expectBookmarkRejected(invalidOffset, on: volumeURL,
                                   label: "an invalid modern bookmark table offset")

        var targetPath = portable
        guard let pathRange = targetPath.range(of: Data("installer.tiff".utf8)) else {
            throw Failure(description: "The modern bookmark has no background target path.")
        }
        targetPath.replaceSubrange(pathRange, with: Data("unrelated.tiff".utf8))
        try expectBookmarkRejected(targetPath, on: volumeURL,
                                   label: "a background path pointing at another file")

        let uuid = try volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard let uuid, let uuidRange = portable.range(of: Data(uuid.uppercased().utf8)) else {
            throw Failure(description: "The modern bookmark has no real volume UUID.")
        }
        var wrongIdentity = portable
        wrongIdentity[uuidRange.lowerBound] = portable[uuidRange.lowerBound] == 0x30 ? 0x31 : 0x30
        try expectBookmarkRejected(wrongIdentity, on: volumeURL,
                                   label: "a modern bookmark for another volume identity")

        // Native minimal bookmarks may append a recursive provider graph with
        // the CI scratch image path. Even a valid-length trailing graph must
        // never be accepted by the allowlisted production representation.
        var providerGraph = portable
        providerGraph.append(Data("/Users/runner/work/dockshell/scratch.dmg".utf8))
        let length = UInt32(providerGraph.count)
        providerGraph.replaceSubrange(4..<8, with: [UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24)])
        try expectBookmarkRejected(providerGraph, on: volumeURL,
                                   label: "a native bookmark retaining a CI backing-image graph")

        if let otherVolume {
            let otherUUID = try otherVolume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard otherUUID?.uppercased() != uuid.uppercased() else {
                throw Failure(description: "The cross-volume bookmark regression needs distinct volume identities.")
            }
            try expectBookmarkRejected(portable, on: otherVolume,
                                       label: "metadata from another mounted installer with the same name")
        }
        print("PASS modern background bookmark: native target resolution; truncated data, table offsets, target paths, volume identities and CI provider graphs rejected")
    }

    private static func expectBookmarkRejected(_ data: Data, on volumeURL: URL, label: String) throws {
        do {
            try BackgroundBookmark.verify(data, volumeURL: volumeURL)
        } catch {
            return
        }
        throw Failure(description: "Installer metadata incorrectly accepted \(label).")
    }

    private static func expectRejected(_ alias: Data, label: String) throws {
        do {
            try FinderLayout.verifyPortableAlias(alias)
        } catch {
            return
        }
        throw Failure(description: "Installer metadata incorrectly accepted \(label).")
    }

    private static func appending(tag: UInt16, value: Data, to alias: Data) throws -> Data {
        guard let valueLength = UInt16(exactly: value.count) else {
            throw Failure(description: "The regression alias value is too large.")
        }
        var result = Data(alias.dropLast(4))
        result.append(contentsOf: [UInt8(tag >> 8), UInt8(truncatingIfNeeded: tag),
                                   UInt8(valueLength >> 8), UInt8(truncatingIfNeeded: valueLength)])
        result.append(value)
        if value.count % 2 != 0 { result.append(0) }
        result.append(contentsOf: [0xff, 0xff, 0, 0])
        guard let length = UInt16(exactly: result.count) else {
            throw Failure(description: "The regression alias is too large.")
        }
        result.replaceSubrange(4..<6, with: [UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
        return result
    }
}

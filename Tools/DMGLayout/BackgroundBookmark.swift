import Foundation

/// Creates Finder's modern `pBBk` background bookmark without retaining any
/// backing-image, sandbox-extension, home-directory, or build-host graph.
///
/// This original, single-TOC encoder follows the public format investigation in
/// https://github.com/dmgbuild/mac_alias/blob/main/src/mac_alias/bookmark.py.
/// The payload describes real mounted-volume identity and a volume-relative
/// path, so a renamed mountpoint does not become a dependency of the installer.
enum BackgroundBookmark {
    private static let relativePath = [".background", "installer.tiff"]
    private static let canonicalVolumePath = "/Volumes/DockShell"
    private static let headerSize: UInt32 = 48

    /// Builds a small independent bookmark rather than embedding the system's
    /// native graph, which can recursively refer to the CI scratch image.
    static func create(for backgroundURL: URL, relativeTo volumeURL: URL) throws -> Data {
        let expected = volumeURL.appendingPathComponent(relativePath.joined(separator: "/"))
        guard backgroundURL.standardizedFileURL == expected.standardizedFileURL else {
            throw BookmarkError.invalid("The installer background must be inside its own volume.")
        }
        let data = try encode(fields(for: volumeURL))
        try verify(data, volumeURL: volumeURL)
        return data
    }

    /// Recomputes the complete allowlisted representation from this mounted
    /// filesystem, then asks the native bookmark resolver to resolve it without
    /// UI, automatic mounting, or implicit security-scope access.
    static func verify(_ data: Data, volumeURL: URL) throws {
        let canonical = try encode(fields(for: volumeURL))
        guard data == canonical else {
            throw BookmarkError.invalid("The background bookmark contains unexpected or stale metadata.")
        }
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
            relativeTo: volumeURL,
            bookmarkDataIsStale: &stale
        )
        let expected = volumeURL.appendingPathComponent(relativePath.joined(separator: "/"))
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolved.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw BookmarkError.invalid("The background bookmark resolves outside this installer volume.")
        }
    }

    private struct BookmarkError: Error, CustomStringConvertible {
        let description: String
        static func invalid(_ description: String) -> Self { Self(description: description) }
    }

    private indirect enum Value {
        case string(String)
        case bytes(Data)
        case integer(UInt64)
        case date(Date)
        case boolean(Bool)
        case array([Value])
        case url(String)
    }

    private static func fields(for volume: URL) throws -> [(UInt32, Value)] {
        let resource = try volume.resourceValues(forKeys: [
            .isVolumeKey, .volumeNameKey, .volumeUUIDStringKey,
            .volumeCreationDateKey, .volumeTotalCapacityKey,
            .volumeIsLocalKey, .volumeSupportsPersistentIDsKey
        ])
        guard resource.isVolume == true, resource.volumeName == "DockShell",
              resource.volumeIsLocal == true, resource.volumeSupportsPersistentIDs == true,
              let rawUUID = resource.volumeUUIDString,
              let uuid = UUID(uuidString: rawUUID),
              uuid.uuidString != "00000000-0000-0000-0000-000000000000",
              let volumeDate = resource.volumeCreationDate,
              let capacity = resource.volumeTotalCapacity, capacity > 0 else {
            throw BookmarkError.invalid("The background bookmark needs real installer-volume identity.")
        }
        let folder = volume.appendingPathComponent(relativePath[0], isDirectory: true)
        let image = folder.appendingPathComponent(relativePath[1])
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let imageAttributes = try FileManager.default.attributesOfItem(atPath: image.path)
        guard folderAttributes[.type] as? FileAttributeType == .typeDirectory,
              imageAttributes[.type] as? FileAttributeType == .typeRegular,
              let folderID = folderAttributes[.systemFileNumber] as? NSNumber,
              let imageID = imageAttributes[.systemFileNumber] as? NSNumber,
              folderID.uint64Value > 2, imageID.uint64Value > 2,
              let imageDate = imageAttributes[.creationDate] as? Date else {
            throw BookmarkError.invalid("The background bookmark needs real image file identity.")
        }
        // Resource flags describe a regular file. Volume flags deliberately
        // assert only local storage and persistent file IDs; no backing disk
        // image or auto-mount information is included in this shipped bookmark.
        let fileProperties = words64([1, 0x0f, 0])
        let volumeFlags: UInt64 = 1 | (1 << 32)
        let volumeProperties = words64([volumeFlags, volumeFlags, 0])
        let mountURL = URL(fileURLWithPath: canonicalVolumePath, isDirectory: true).absoluteString
        return [
            (0x1004, .array(relativePath.map(Value.string))),
            (0x1005, .array([.integer(folderID.uint64Value), .integer(imageID.uint64Value)])),
            (0x1010, .bytes(fileProperties)),
            (0x1040, .date(imageDate)),
            (0x2002, .string(canonicalVolumePath)),
            (0x2005, .url(mountURL)),
            (0x2010, .string("DockShell")),
            (0x2011, .string(uuid.uuidString)),
            (0x2012, .integer(UInt64(capacity))),
            (0x2013, .date(volumeDate)),
            (0x2020, .bytes(volumeProperties)),
            (0x2030, .boolean(false)),
            (0xc001, .integer(0)),
            (0xd001, .boolean(true)),
            (0xd010, .integer(0x20000200))
        ]
    }

    private static func encode(_ fields: [(UInt32, Value)]) throws -> Data {
        var encoder = Encoder()
        var entries: [(UInt32, UInt32)] = []
        for (key, value) in fields.sorted(by: { $0.0 < $1.0 }) {
            entries.append((key, try encoder.append(value)))
        }
        let tocOffset = UInt32(encoder.body.count)
        // The TOC length field excludes its first eight bytes, following the
        // conventional bookmark encoder. All offsets are relative to the end
        // of the fixed header, and every data item starts on a 4-byte boundary.
        encoder.body.append(word(UInt32(entries.count * 12 - 8)))
        encoder.body.append(word(0xfffffffe))
        encoder.body.append(word(1))
        encoder.body.append(word(0))
        encoder.body.append(word(UInt32(entries.count)))
        for (key, offset) in entries {
            encoder.body.append(word(key))
            encoder.body.append(word(offset))
            encoder.body.append(word(0))
        }
        encoder.body.replaceSubrange(0..<4, with: word(tocOffset))
        var result = Data("book".utf8)
        result.append(word(headerSize + UInt32(encoder.body.count)))
        result.append(word(0x10040000))
        result.append(word(headerSize))
        result.append(Data(repeating: 0, count: 32))
        result.append(encoder.body)
        guard result.count < 2048 else {
            throw BookmarkError.invalid("The portable background bookmark exceeds its bounded size.")
        }
        return result
    }

    private struct Encoder {
        var body = Data(repeating: 0, count: 4)

        mutating func append(_ value: Value) throws -> UInt32 {
            let type: UInt32
            let payload: Data
            switch value {
            case .string(let string):
                type = 0x0101; payload = Data(string.utf8)
            case .bytes(let data):
                type = 0x0201; payload = data
            case .integer(let integer):
                if integer <= UInt64(Int32.max) {
                    type = 0x0303; payload = word(UInt32(integer))
                } else {
                    type = 0x0304; payload = words64([integer])
                }
            case .date(let date):
                guard date.timeIntervalSinceReferenceDate.isFinite else {
                    throw BookmarkError.invalid("The background bookmark contains an invalid date.")
                }
                // Bookmark dates uniquely use big-endian IEEE doubles since
                // 2001; item headers, integers and offsets use little endian.
                type = 0x0400
                var bits = date.timeIntervalSinceReferenceDate.bitPattern.bigEndian
                payload = withUnsafeBytes(of: &bits) { Data($0) }
            case .boolean(let boolean):
                type = boolean ? 0x0501 : 0x0500; payload = Data()
            case .array(let values):
                type = 0x0601
                var offsets = Data()
                for item in values { offsets.append(word(try append(item))) }
                payload = offsets
            case .url(let string):
                type = 0x0901; payload = Data(string.utf8)
            }
            let offset = UInt32(body.count)
            body.append(word(UInt32(payload.count)))
            body.append(word(type))
            body.append(payload)
            while body.count % 4 != 0 { body.append(0) }
            return offset
        }
    }

    private static func word(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private static func words64(_ values: [UInt64]) -> Data {
        var result = Data()
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }
}

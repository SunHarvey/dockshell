import Foundation

/// Writes the small, fixed Finder database used by DockShell's installer volume.
///
/// This is an original single-leaf implementation of the documented .DS_Store
/// record/buddy-file format, rather than a general database editor. Format notes:
/// https://metacpan.org/dist/Mac-Finder-DSStore/view/DSStoreFormat.pod
/// The background alias must be created on the mounted, writable installer volume;
/// converting that same volume to UDZO preserves the file and volume identities.
enum FinderLayout {
    static let canvasWidth = 660
    static let canvasHeight = 440
    static let appCenterX = 170
    static let applicationsCenterX = 490
    static let iconCenterY = 220
    static let iconSize = 96
    static let textSize = 14
    static let backgroundPath = ".background/installer.tiff"

    private static let windowBounds = "{{160, 160}, {660, 440}}"
    private static let pageSize = 4096
    private static let filePrefixSize = 4

    /// Creates a portable icon-view layout without launching or scripting Finder.
    static func write(to volumeURL: URL) throws {
        let background = volumeURL.appendingPathComponent(backgroundPath)
        let values = try background.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LayoutError.invalid("The installer background is missing or is a symbolic link.")
        }
        var aliasStatus: Int32 = 0
        let alias: CFData? = background.path.withCString {
            DockShellCreateFinderAlias($0, &aliasStatus)
        }
        guard aliasStatus == 0, let alias else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(aliasStatus))
        }
        let records = try makeRecords(backgroundAlias: alias as Data)
        let database = try makeDatabase(records)
        let target = volumeURL.appendingPathComponent(".DS_Store")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw LayoutError.invalid("The installer layout must not overwrite an existing Finder database.")
        }
        try database.write(to: target, options: .withoutOverwriting)
        try verify(at: volumeURL)
    }

    /// Reads back the stored layout and resolves its background with UI and volume
    /// mounting disabled. Running this after read-only remount proves that the
    /// background refers to the installer itself, including a changed mount path.
    static func verify(at volumeURL: URL) throws {
        let target = volumeURL.appendingPathComponent(".DS_Store")
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == 8196 else {
            throw LayoutError.invalid("The installer Finder database is missing or has an unexpected size.")
        }
        let records = try readDatabase(Data(contentsOf: target))
        guard records.count == 7 else {
            throw LayoutError.invalid("The installer Finder database has an unexpected record count.")
        }
        let window = try propertyList(records, filename: ".", code: "bwsp")
        guard window["WindowBounds"] as? String == windowBounds else {
            throw LayoutError.invalid("The installer window does not have the required compact dimensions.")
        }
        for key in ["ShowStatusBar", "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar", "ContainerShowSidebar", "PreviewPaneVisibility"] {
            guard window[key] as? Bool == false else {
                throw LayoutError.invalid("The installer window contains an unexpected visible Finder panel.")
            }
        }
        let view = try propertyList(records, filename: ".", code: "icvp")
        guard view["backgroundType"] as? Int == 2,
              view["arrangeBy"] as? String == "none",
              view["iconSize"] as? Int == iconSize,
              view["textSize"] as? Int == textSize,
              view["labelOnBottom"] as? Bool == true,
              view["showItemInfo"] as? Bool == false,
              view["scrollPositionX"] as? Int == 0,
              view["scrollPositionY"] as? Int == 0,
              let alias = view["backgroundImageAlias"] as? Data,
              !alias.isEmpty else {
            throw LayoutError.invalid("The installer icon-view settings do not match the branded layout.")
        }
        for code in ["icvl", "vstl"] {
            guard try record(records, filename: ".", code: code) == Record(filename: ".", code: code, type: "type", value: Data("icnv".utf8)) else {
                throw LayoutError.invalid("The installer does not select icon view by default.")
            }
        }
        guard try record(records, filename: ".", code: "vSrn").value == word(1),
              try record(records, filename: "DockShell.app", code: "Iloc").value == iconLocation(x: appCenterX),
              try record(records, filename: "Applications", code: "Iloc").value == iconLocation(x: applicationsCenterX) else {
            throw LayoutError.invalid("The installer icons are not in the required left-to-right order.")
        }
        // This conversion exists specifically for reading legacy AliasRecords.
        // Never resolve with UI or implicit mounting enabled during packaging.
        guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, alias as CFData)?.takeRetainedValue() else {
            throw LayoutError.invalid("The installer background AliasRecord cannot be decoded.")
        }
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark as Data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let expected = volumeURL.appendingPathComponent(backgroundPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolved.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw LayoutError.invalid("The installer background alias resolves outside this mounted installer.")
        }
    }

    private static func makeRecords(backgroundAlias: Data) throws -> [Record] {
        let window: [String: Any] = [
            "WindowBounds": windowBounds,
            "ShowStatusBar": false,
            "ShowTabView": false,
            "ShowToolbar": false,
            "ShowPathbar": false,
            "ShowSidebar": false,
            "ContainerShowSidebar": false,
            "PreviewPaneVisibility": false,
            "SidebarWidth": 0
        ]
        let icons: [String: Any] = [
            "viewOptionsVersion": 1,
            "backgroundType": 2,
            "backgroundImageAlias": backgroundAlias,
            "backgroundColorRed": 0.96,
            "backgroundColorGreen": 0.97,
            "backgroundColorBlue": 0.98,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "showIconPreview": false,
            "showItemInfo": false,
            "labelOnBottom": true,
            "textSize": Double(textSize),
            "iconSize": Double(iconSize),
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0
        ]
        return [
            Record(filename: ".", code: "bwsp", type: "blob", value: try binaryPlist(window)),
            Record(filename: ".", code: "icvl", type: "type", value: Data("icnv".utf8)),
            Record(filename: ".", code: "icvp", type: "blob", value: try binaryPlist(icons)),
            Record(filename: ".", code: "vSrn", type: "long", value: word(1)),
            Record(filename: ".", code: "vstl", type: "type", value: Data("icnv".utf8)),
            Record(filename: "Applications", code: "Iloc", type: "blob", value: iconLocation(x: applicationsCenterX)),
            Record(filename: "DockShell.app", code: "Iloc", type: "blob", value: iconLocation(x: appCenterX))
        ]
    }

    private static func binaryPlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func iconLocation(x: Int) -> Data {
        word(UInt32(x)) + word(UInt32(iconCenterY)) + word(UInt32.max) + word(0xffff0000)
    }

    private struct Record: Equatable {
        let filename: String
        let code: String
        let type: String
        let value: Data

        var encoded: Data {
            let utf16 = filename.utf16
            var result = word(UInt32(utf16.count))
            for character in utf16 {
                result.append(UInt8(truncatingIfNeeded: character >> 8))
                result.append(UInt8(truncatingIfNeeded: character))
            }
            result.append(contentsOf: code.utf8)
            result.append(contentsOf: type.utf8)
            if type == "blob" { result.append(word(UInt32(value.count))) }
            result.append(value)
            return result
        }
    }

    private static func makeDatabase(_ records: [Record]) throws -> Data {
        // Buddy offsets exclude the four-byte version prefix. Fixed allocations:
        // 0..31 header; 32..63 DSDB; 2048..4095 allocator; 4096..8191 leaf.
        // Every remaining range appears in the appropriate buddy free list.
        var metadata = word(3) + word(0)
        for address: UInt32 in [2048 | 11, 32 | 5, 4096 | 12] { metadata.append(word(address)) }
        metadata.append(Data(repeating: 0, count: (256 - 3) * 4))
        metadata.append(word(1))
        metadata.append(4)
        metadata.append(contentsOf: "DSDB".utf8)
        metadata.append(word(1))
        for exponent in 0..<32 {
            let free = (6...10).contains(exponent) || (13...30).contains(exponent)
            metadata.append(word(free ? 1 : 0))
            if free { metadata.append(word(UInt32(1) << exponent)) }
        }
        guard metadata.count <= 2048 else { throw LayoutError.invalid("The installer allocator exceeds its fixed block.") }

        var leaf = word(0) + word(UInt32(records.count))
        for record in records { leaf.append(record.encoded) }
        guard leaf.count <= pageSize else { throw LayoutError.invalid("The installer layout exceeds its single database page.") }

        var output = Data(repeating: 0, count: 8196)
        // Unknown header bytes are unused and deliberately zeroed.
        let header = word(1) + Data("Bud1".utf8) + word(2048) + word(2048) + word(2048)
        output.replaceSubrange(0..<header.count, with: header)
        let superblock = word(2) + word(0) + word(UInt32(records.count)) + word(1) + word(UInt32(pageSize))
        output.replaceSubrange(36..<(36 + superblock.count), with: superblock)
        output.replaceSubrange(2052..<(2052 + metadata.count), with: metadata)
        output.replaceSubrange(4100..<(4100 + leaf.count), with: leaf)
        return output
    }

    private static func readDatabase(_ data: Data) throws -> [Record] {
        var header = Reader(data: data)
        guard try header.integer() == 1, try header.ascii(4) == "Bud1" else {
            throw LayoutError.invalid("Invalid installer Finder database header.")
        }
        let allocatorOffset = Int(try header.integer())
        let allocatorSize = Int(try header.integer())
        guard try header.integer() == allocatorOffset, allocatorSize == 2048 else {
            throw LayoutError.invalid("Invalid installer Finder allocator bounds.")
        }
        var allocator = Reader(data: try data.checkedSlice(at: allocatorOffset + filePrefixSize, count: allocatorSize))
        let blockCount = Int(try allocator.integer())
        guard blockCount == 3, try allocator.integer() == 0 else {
            throw LayoutError.invalid("Invalid installer Finder allocator table.")
        }
        var addresses: [UInt32] = []
        for _ in 0..<256 { addresses.append(try allocator.integer()) }
        guard try allocator.integer() == 1,
              try allocator.byte() == 4,
              try allocator.ascii(4) == "DSDB" else {
            throw LayoutError.invalid("Missing installer Finder database directory entry.")
        }
        let masterID = Int(try allocator.integer())
        func block(_ id: Int) throws -> Data {
            guard id >= 0, id < blockCount else { throw LayoutError.invalid("Invalid installer database block reference.") }
            let address = addresses[id]
            let exponent = Int(address & 31)
            guard (5...12).contains(exponent) else { throw LayoutError.invalid("Invalid installer database block size.") }
            return try data.checkedSlice(at: Int(address & ~31) + filePrefixSize, count: 1 << exponent)
        }
        var master = Reader(data: try block(masterID))
        let leafID = Int(try master.integer())
        guard try master.integer() == 0 else { throw LayoutError.invalid("The installer database is not a single leaf.") }
        let count = Int(try master.integer())
        guard count == 7, try master.integer() == 1, try master.integer() == pageSize else {
            throw LayoutError.invalid("Invalid installer database master record.")
        }
        var leaf = Reader(data: try block(leafID))
        guard try leaf.integer() == 0, try leaf.integer() == count else {
            throw LayoutError.invalid("Invalid installer database leaf.")
        }
        var result: [Record] = []
        for _ in 0..<count {
            let nameLength = Int(try leaf.integer())
            guard nameLength > 0, nameLength <= 128,
                  let filename = String(data: try leaf.bytes(nameLength * 2), encoding: .utf16BigEndian) else {
                throw LayoutError.invalid("Invalid installer database filename.")
            }
            let code = try leaf.ascii(4)
            let type = try leaf.ascii(4)
            let length: Int
            switch type {
            case "blob": length = Int(try leaf.integer())
            case "type", "long": length = 4
            default: throw LayoutError.invalid("Unsupported installer database record type.")
            }
            result.append(Record(filename: filename, code: code, type: type, value: try leaf.bytes(length)))
        }
        return result
    }

    private static func record(_ records: [Record], filename: String, code: String) throws -> Record {
        let matches = records.filter { $0.filename == filename && $0.code == code }
        guard matches.count == 1, let match = matches.first else {
            throw LayoutError.invalid("A required installer layout record is missing or duplicated.")
        }
        return match
    }

    private static func propertyList(_ records: [Record], filename: String, code: String) throws -> [String: Any] {
        let entry = try record(records, filename: filename, code: code)
        guard entry.type == "blob",
              let value = try PropertyListSerialization.propertyList(from: entry.value, options: [], format: nil) as? [String: Any] else {
            throw LayoutError.invalid("An installer layout property list is invalid.")
        }
        return value
    }

    private struct Reader {
        let data: Data
        private(set) var position = 0

        mutating func bytes(_ count: Int) throws -> Data {
            let value = try data.checkedSlice(at: position, count: count)
            position += count
            return value
        }
        mutating func byte() throws -> UInt8 { try bytes(1)[0] }
        mutating func integer() throws -> UInt32 {
            try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        mutating func ascii(_ count: Int) throws -> String {
            guard let value = String(data: try bytes(count), encoding: .ascii) else {
                throw LayoutError.invalid("An installer database field is not ASCII.")
            }
            return value
        }
    }

    private static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private enum LayoutError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { message } else { nil } }
    }
}

private extension Data {
    func checkedSlice(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data(self[offset..<(offset + count)])
    }
}

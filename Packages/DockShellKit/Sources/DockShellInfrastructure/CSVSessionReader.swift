import Darwin
import DockShellDomain
import Foundation

/// Bounded CSV reader with quoted commas, escaped quotes, multiline fields and UTF-8 BOM support.
/// No shell, URL fetching, credential import or session writes occur here.
public actor CSVSessionReader: SessionCSVReading {
    private let home: URL
    private static let maximumBytes = 2_000_000

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func read(from url: URL) throws -> SessionImportDocument {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.contains("\0") else { throw SessionCSVError.unreadable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SessionCSVError.unreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SessionCSVError.unreadable }
        guard info.st_size <= Self.maximumBytes else { throw SessionCSVError.limitExceeded }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SessionCSVError.unreadable }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw SessionCSVError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SessionCSVError.invalidEncoding }
        return try parse(text)
    }

    public func parse(_ text: String) throws -> SessionImportDocument {
        try Task.checkCancellation()
        guard text.utf8.count <= Self.maximumBytes else { throw SessionCSVError.limitExceeded }
        guard !text.contains("\0") else { throw SessionCSVError.invalidEncoding }
        let records = try CSVRecords.decode(text)
        guard let header = records.first else { throw SessionCSVError.empty }
        let columns = header.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(columns).count == columns.count,
              Set(columns).isSubset(of: Set(SessionCSVFormat.columns)),
              SessionCSVFormat.requiredColumns.isSubset(of: Set(columns)) else { throw SessionCSVError.invalidHeaders }
        guard records.count > 1 else { throw SessionCSVError.empty }
        var result: [SessionImportRow] = []
        for record in records.dropFirst() {
            try Task.checkCancellation()
            let values = Dictionary(uniqueKeysWithValues: zip(columns, record.fields).map { ($0, $1.trimmingCharacters(in: .whitespacesAndNewlines)) })
            let authentication: AuthenticationKind?
            switch values["auth"]?.lowercased() {
            case "agent": authentication = .agent
            case "password": authentication = .password
            case "key": authentication = .privateKey
            default: authentication = nil
            }
            // A path is file identity, so do not trim a quoted filename's significant spaces.
            let originalPath = columns.firstIndex(of: "key_path").flatMap {
                $0 < record.fields.count ? record.fields[$0] : nil
            } ?? ""
            // CSV paths are explicit data, not SSH config expressions. Expand only the current user's ~/.
            let path = originalPath.hasPrefix("~/") ? home.appendingPathComponent(String(originalPath.dropFirst(2))).path : originalPath
            let port = values["port"].flatMap { $0.isEmpty ? nil : $0 } ?? "22"
            let issues: [SessionImportIssue] = columns.count == record.fields.count ? [] :
                [.csvColumns(expected: columns.count, actual: record.fields.count)]
            var row = SessionImportRow(name: values["name"] ?? "", host: values["host"] ?? "", port: port,
                username: values["username"] ?? "", authentication: authentication ?? .agent,
                keyPaths: path.isEmpty ? [] : [path], issues: issues, sourceLine: record.line)
            row.authenticationNeedsSelection = authentication == nil
            result.append(row)
        }
        return SessionImportDocument(rows: result, patternRuleCount: 0)
    }
}

private struct CSVRecords {
    let fields: [String]
    let line: Int
    private enum State { case start, unquoted, quoted, afterQuote, afterQuoteSpace }

    static func decode(_ source: String) throws -> [CSVRecords] {
        var bytes = Array(source.utf8)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var records: [CSVRecords] = [], fields: [String] = [], field: [UInt8] = []
        var state = State.start, index = 0, line = 1, startLine = 1, recordStarted = false
        func finishField() throws {
            guard fields.count < 32 else { throw SessionCSVError.limitExceeded }
            fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
            state = .start
        }
        func finishRecord() throws {
            try finishField()
            // Empty physical lines are allowed, but a row containing several empty cells is still a row to validate.
            if fields.count != 1 || !fields[0].trimmingCharacters(in: .whitespaces).isEmpty {
                guard records.count < 1001 else { throw SessionCSVError.limitExceeded }
                records.append(CSVRecords(fields: fields, line: startLine))
            }
            fields.removeAll(keepingCapacity: true); recordStarted = false
        }
        while index < bytes.count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            let newline = byte == 10 || byte == 13
            if state == .quoted {
                if byte == 34 { state = .afterQuote }
                else {
                    field.append(byte)
                    if newline {
                        if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 {
                            field.append(10); index += 1
                        }
                        line += 1
                    }
                }
            } else if state == .afterQuote && byte == 34 {
                field.append(34); state = .quoted
            } else if byte == 44 {
                try finishField(); recordStarted = true
            } else if newline {
                try finishRecord()
                if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 { index += 1 }
                line += 1; startLine = line
            } else {
                switch state {
                case .start:
                    recordStarted = true
                    if byte == 34 { state = .quoted } else { field.append(byte); state = .unquoted }
                case .unquoted:
                    guard byte != 34 else { throw SessionCSVError.malformed(line: line) }
                    field.append(byte)
                case .afterQuote, .afterQuoteSpace:
                    guard byte == 32 || byte == 9 else { throw SessionCSVError.malformed(line: line) }
                    state = .afterQuoteSpace
                case .quoted: break
                }
            }
            guard field.count <= 16_384 else { throw SessionCSVError.limitExceeded }
            index += 1
        }
        guard state != .quoted else { throw SessionCSVError.malformed(line: startLine) }
        if recordStarted || !fields.isEmpty || !field.isEmpty { try finishRecord() }
        return records
    }
}

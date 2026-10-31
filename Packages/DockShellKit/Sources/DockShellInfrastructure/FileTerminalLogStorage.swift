import Darwin
import DockShellDomain
import Foundation

/// One sleeping IO worker is shared by all connections. Paths derive from system APIs.
public final class FileTerminalLogStorage: TerminalLogStorage, Sendable {
    private let root: URL?
    private let worker = TerminalLogFileWorker()
    public init(root: URL? = nil) { self.root = root }

    public func create(connectionID: UUID, limit: Int, olderRemoved: String) async throws -> any TerminalLogStore {
        let root = root
        let files = try await worker.perform {
            guard (1_000_000...100_000_000).contains(limit) else { throw TerminalLogError.unavailable }
            let base: URL
            if let root { base = root }
            else {
                base = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Logs/DockShell", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(base.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw TerminalLogError.unsafeFile }
            let files = TerminalLogFiles(directory: base.appendingPathComponent(connectionID.uuidString),
                limit: limit, segmentBytes: 65_536, olderRemoved: olderRemoved)
            try files.prepare()
            return files
        }
        return FileTerminalLogStore(worker: worker, files: files)
    }

    public func export(_ snapshot: Data, to destination: URL) async throws {
        try await worker.perform { try TerminalLogFiles.export(snapshot, to: destination) }
    }
}

/// A single ordered consumer owns each store; mutable descriptors stay on its IO worker.
private actor FileTerminalLogStore: TerminalLogStore {
    private let worker: TerminalLogFileWorker
    private let files: TerminalLogFiles
    init(worker: TerminalLogFileWorker, files: TerminalLogFiles) { self.worker = worker; self.files = files }
    func append(_ bytes: Data) async throws {
        guard String(data: bytes, encoding: .utf8) != nil else { throw TerminalLogError.writeFailed }
        let files = files
        try await worker.perform { try files.append(bytes) }
    }
    func snapshot(tail: TerminalLogTail) async throws -> Data {
        let files = files
        return try await worker.perform { try files.snapshot(tail: tail) }
    }
    func setLimit(_ bytes: Int) async throws {
        guard (1_000_000...100_000_000).contains(bytes) else { throw TerminalLogError.unavailable }
        let files = files
        try await worker.perform { try files.setLimit(bytes) }
    }
    func close() async throws {
        let files = files
        try await worker.perform { try files.close() }
    }
    deinit {
        let files = files, worker = worker
        Task { try? await worker.perform { try? files.close(); files.dispose() } }
    }
}

/// Minimal bounded bridge for blocking filesystem operations. Only its worker thread
/// touches file descriptors; callers suspend via async/await instead of blocking MainActor.
private final class TerminalLogFileWorker: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [@Sendable () -> Void] = []
        var stopped = false

        func enqueue(_ job: @escaping @Sendable () -> Void) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard !stopped, jobs.count < 64 else { return false }
            jobs.append(job); condition.signal(); return true
        }

        func stop() {
            condition.lock(); stopped = true; condition.signal(); condition.unlock()
        }

        func loop() {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopped { condition.wait() }
                if jobs.isEmpty { condition.unlock(); return }
                let job = jobs.removeFirst()
                condition.unlock()
                autoreleasepool(invoking: job)
            }
        }
    }

    private let state = State()
    init() { let state = state; Thread.detachNewThread { state.loop() } }
    deinit { state.stop() }

    func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            guard state.enqueue({
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }) else {
                continuation.resume(throwing: TerminalLogError.queueFull)
                return
            }
        }
    }
}

/// @unchecked is limited to this worker-confined object; no actor reads its mutable state.
/// Each connection gets a new owner-only directory. Existing connection logs are never reopened.
private final class TerminalLogFiles: @unchecked Sendable {
    private struct Segment {
        let name: String
        var bytes: Int
        let inode: ino_t
        let device: dev_t
    }

    private let truncation: Data
    private let directory: URL
    private var limit: Int
    private let segmentBytes: Int
    private var directoryFD: Int32 = -1
    private var currentFD: Int32 = -1
    private var segments: [Segment] = []
    private var sequence = 0
    private var rotated = false
    private var closed = false
    private(set) var byteCount = 0

    init(directory: URL, limit: Int, segmentBytes: Int, olderRemoved: String) {
        truncation = Data(("[DockShell] " + olderRemoved + "\n").utf8)
        self.directory = directory; self.limit = limit; self.segmentBytes = segmentBytes
    }

    deinit {
        if currentFD >= 0 { Darwin.close(currentFD) }
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }

    func prepare() throws {
        guard !Thread.isMainThread else { throw fail("File IO reached the main thread") }
        guard mkdir(directory.path, 0o700) == 0 else { throw fail("Cannot create an exclusive connection log directory") }
        directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw fail("Cannot open the connection log directory") }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid() else { throw fail("Unexpected log directory owner") }
    }

    func append(_ data: Data) throws {
        guard !closed, directoryFD >= 0 else { throw fail("Log store is closed") }
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            if segments.isEmpty || segments.last!.bytes == segmentBytes { try openSegment() }
            var count = min(bytes.count - offset, segmentBytes - segments.last!.bytes)
            while count > 0 && offset + count < bytes.count && bytes[offset + count] & 0xc0 == 0x80 { count -= 1 }
            if count == 0 { try openSegment(); continue }
            let part = Data(bytes[offset..<(offset + count)])
            let previousSize = segments[segments.count - 1].bytes
            do { try Self.writeAll(part, to: currentFD) }
            catch {
                // Preserve the preceding valid UTF-8 boundary after a partial failed write.
                guard ftruncate(currentFD, off_t(previousSize)) == 0 else { throw fail("Log write failed and rollback failed") }
                throw error
            }
            segments[segments.count - 1].bytes += count
            byteCount += count
            offset += count
            try trim()
        }
    }

    private func openSegment() throws {
        if currentFD >= 0 { guard Darwin.close(currentFD) == 0 else { throw fail("Cannot close a log segment") }; currentFD = -1 }
        sequence += 1
        let name = String(format: "%08d.log", sequence)
        currentFD = openat(directoryFD, name, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard currentFD >= 0 else { throw fail("Cannot create an exclusive log segment") }
        var info = stat()
        guard fstat(currentFD, &info) == 0 else { throw fail("Cannot inspect a log segment") }
        segments.append(Segment(name: name, bytes: 0, inode: info.st_ino, device: info.st_dev))
    }

    private func trim() throws {
        if byteCount > limit { rotated = true }
        let budget = limit - (rotated ? truncation.count : 0)
        while byteCount > budget, segments.count > 1 {
            let oldest = segments[0]
            try verify(oldest)
            guard unlinkat(directoryFD, oldest.name, 0) == 0 else { throw fail("Cannot remove an old log segment") }
            byteCount -= oldest.bytes
            segments.removeFirst()
        }
        guard byteCount <= budget else { throw fail("Log capacity was exceeded") }
    }

    func setLimit(_ bytes: Int) throws {
        guard bytes >= 256, segmentBytes <= bytes / 2 else { throw fail("Invalid updated log capacity") }
        limit = bytes
        try trim()
    }

    func snapshot(tail: TerminalLogTail) throws -> Data {
        guard directoryFD >= 0 else { throw fail("Log store is not initialized") }
        guard String(data: tail.data, encoding: .utf8) != nil else { throw fail("Pending log text is not valid UTF-8") }
        var result = Data()
        result.reserveCapacity(min(limit + segmentBytes, byteCount + tail.data.count))
        for segment in segments {
            try verify(segment)
            let fd = openat(directoryFD, segment.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw fail("Cannot read a retained segment") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_ino == segment.inode, info.st_dev == segment.device,
                  info.st_size == segment.bytes else { throw fail("A retained log segment changed") }
            var remaining = segment.bytes
            while remaining > 0 {
                var buffer = [UInt8](repeating: 0, count: min(remaining, 65_536))
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw fail("Cannot read a complete retained segment") }
                result.append(contentsOf: buffer.prefix(count)); remaining -= count
            }
        }
        result.append(tail.data)
        if rotated || tail.removedBytes > 0 || result.count > limit {
            var bounded = BoundedUTF8Tail(capacity: limit - truncation.count)
            bounded.append(result)
            result = truncation + bounded.data()
        }
        guard result.count <= limit, String(data: result, encoding: .utf8) != nil else { throw fail("Invalid bounded snapshot") }
        return result
    }

    private func verify(_ segment: Segment) throws {
        var info = stat()
        guard fstatat(directoryFD, segment.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_ino == segment.inode, info.st_dev == segment.device,
              info.st_size == segment.bytes else { throw fail("A log segment was replaced or edited") }
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        if currentFD >= 0 {
            let fd = currentFD; currentFD = -1
            defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw fail("Cannot synchronize the log file") }
        }
    }

    func dispose() {
        if currentFD >= 0 { Darwin.close(currentFD); currentFD = -1 }
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
    }

    /// Same-directory temporary file + exclusive hard-link publication. An existing
    /// export or symlink is never overwritten; a failed export leaves no partial result.
    static func export(_ bytes: Data, to destination: URL) throws {
        let name = destination.lastPathComponent
        guard destination.isFileURL, !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { throw fail("Invalid export destination") }
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw fail("Cannot open the export directory") }
        defer { Darwin.close(directory) }
        let temporary = ".dockshell-export-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("Cannot create an exclusive export file") }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try writeAll(bytes, to: fd)
        guard fsync(fd) == 0 else { throw fail("Cannot synchronize the export") }
        guard linkat(directory, temporary, directory, name, 0) == 0 else {
            if errno == EEXIST { throw TerminalLogError.destinationExists }
            throw TerminalLogError.exportFailed
        }
    }

    private static func writeAll(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { raw in
            guard let start = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, start.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw fail("Log file write failed") }
                offset += count
            }
        }
    }

    private func fail(_ message: String) -> TerminalLogError { Self.fail(message) }
    private static func fail(_ message: String) -> TerminalLogError { .writeFailed }
}

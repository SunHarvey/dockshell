import Darwin
import DockShellDomain
import Foundation

/// One sleeping worker services each open local file. File syscalls never run
/// on MainActor or occupy Swift's cooperative executor, and chunks do not spawn
/// new threads. The small queue rejects unbounded callers.
private final class TransferFileWorker: Sendable {
    /// Every mutable member is protected by condition; work executes only on
    /// the worker. No owner is retained by the thread, so deinit can wake it.
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [@Sendable () -> Void] = []
        var stopped = false
        func enqueue(_ job: @escaping @Sendable () -> Void) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard !stopped, jobs.count < 8 else { return false }
            jobs.append(job); condition.signal(); return true
        }
        func stop() { condition.lock(); stopped = true; condition.signal(); condition.unlock() }
        func loop(cleanup: @Sendable () -> Void) {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopped { condition.wait() }
                if jobs.isEmpty { condition.unlock(); break }
                let job = jobs.removeFirst()
                condition.unlock()
                autoreleasepool(invoking: job)
            }
            cleanup()
        }
    }
    private let state = State()
    init(cleanup: @escaping @Sendable () -> Void) {
        let state = state
        Thread.detachNewThread { state.loop(cleanup: cleanup) }
    }
    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            guard state.enqueue({
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }) else { continuation.resume(throwing: SFTPTransferError.localIO); return }
        }
    }
    func stop() { state.stop() }
    deinit { state.stop() }
}

private enum TransferPOSIX {
    static func error(_ value: Int32 = errno) -> SFTPTransferError {
        switch value {
        case EACCES, EPERM, EROFS: .localPermission
        case ELOOP: .unsupportedFile
        case EEXIST: .destinationChanged
        default: .localIO
        }
    }
    static func metadata(_ info: stat) throws -> SFTPTransferLocalMetadata {
        guard info.st_size >= 0 else { throw SFTPTransferError.unsupportedFile }
        let fingerprint = "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return SFTPTransferLocalMetadata(size: UInt64(info.st_size), permissions: UInt32(info.st_mode) & 0o777,
            isRegular: info.st_mode & S_IFMT == S_IFREG, identity: Data(fingerprint.utf8))
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }
    static func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              validName(url.lastPathComponent) else { throw SFTPTransferError.invalidPath }
    }
    /// Resolve the user-selected directory, then walk its physical components
    /// with openat/O_NOFOLLOW. Subsequent operations use the held directory FD.
    static func openDirectory(_ url: URL) throws -> (Int32, URL) {
        guard let resolved = realpath(url.path, nil) else { throw error() }
        let path = String(cString: resolved)
        free(resolved)
        let physical = URL(fileURLWithPath: path, isDirectory: true)
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw error() }
        do {
            for part in path.split(separator: "/") {
                let next = String(part).withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { throw error() }
                Darwin.close(directory); directory = next
            }
            return (directory, physical)
        } catch { Darwin.close(directory); throw error }
    }
}

/// State is touched exclusively by its TransferFileWorker, including cleanup.
private final class TransferSourceState: @unchecked Sendable {
    var descriptor: Int32 = -1
    var offset: Int64 = 0
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
}

private actor SystemTransferSource: SFTPTransferSource {
    private let state: TransferSourceState
    private let worker: TransferFileWorker
    init(state: TransferSourceState, worker: TransferFileWorker) { self.state = state; self.worker = worker }
    func metadata() async throws -> SFTPTransferLocalMetadata {
        let state = state
        return try await worker.perform {
            guard state.descriptor >= 0 else { throw SFTPTransferError.localIO }
            var info = stat()
            guard fstat(state.descriptor, &info) == 0 else { throw TransferPOSIX.error() }
            return try TransferPOSIX.metadata(info)
        }
    }
    func read(maxBytes: Int) async throws -> Data? {
        guard (1...65_536).contains(maxBytes) else { throw SFTPTransferError.invalidPath }
        let state = state
        return try await worker.perform {
            guard state.descriptor >= 0 else { throw SFTPTransferError.localIO }
            var bytes = Data(count: maxBytes)
            let count: Int = try bytes.withUnsafeMutableBytes { buffer in
                var count: Int
                repeat { count = pread(state.descriptor, buffer.baseAddress, maxBytes, state.offset) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw TransferPOSIX.error() }
                return count
            }
            guard count > 0 else { return nil }
            guard state.offset <= Int64.max - Int64(count) else { throw SFTPTransferError.unsupportedFile }
            state.offset += Int64(count)
            bytes.count = count
            return bytes
        }
    }
    func close() async { let state = state; _ = try? await worker.perform { state.close() }; worker.stop() }
}

/// All mutable file state and descriptors are confined to the one worker thread.
/// The temporary inode is checked before unlink so a replaced name is not erased.
private final class TransferDestinationState: @unchecked Sendable {
    var directory: Int32 = -1
    var descriptor: Int32 = -1
    var parent = URL(fileURLWithPath: "/")
    var name = ""
    let temporaryName = ".dockshell-download-" + UUID().uuidString + ".part"
    var inode: ino_t = 0
    var device: dev_t = 0
    var ownsTemporary = false
    var committed = false
    var readyForCommit = false
    func inspect() throws -> SFTPTransferLocalMetadata? {
        guard directory >= 0 else { throw SFTPTransferError.localIO }
        var info = stat()
        let result = name.withCString { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result < 0, errno == ENOENT { return nil }
        guard result == 0 else { throw TransferPOSIX.error() }
        return try TransferPOSIX.metadata(info)
    }
    func discard() -> Bool {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        guard ownsTemporary, directory >= 0 else { return true }
        var info = stat()
        let result = temporaryName.withCString { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result < 0, errno == ENOENT { ownsTemporary = false; return true }
        guard result == 0, info.st_ino == inode, info.st_dev == device else { return false }
        let removed = temporaryName.withCString { unlinkat(directory, $0, 0) } == 0
        if removed { ownsTemporary = false }
        return removed
    }
    func cleanup() {
        _ = discard()
        if directory >= 0 { Darwin.close(directory); directory = -1 }
    }
}

private actor SystemTransferDestination: SFTPTransferDestination {
    private let state: TransferDestinationState
    private let worker: TransferFileWorker
    private var destination: URL
    private let temporary: URL
    private var discardTask: Task<Bool, Never>?
    init(state: TransferDestinationState, worker: TransferFileWorker, destination: URL, temporary: URL) {
        self.state = state; self.worker = worker; self.destination = destination; self.temporary = temporary
    }
    func currentURL() async -> URL { destination }
    func temporaryURL() async -> URL { temporary }
    func inspect() async throws -> SFTPTransferLocalMetadata? { let state = state; return try await worker.perform { try state.inspect() } }
    func selectName(_ name: String) async throws {
        guard TransferPOSIX.validName(name), name != state.temporaryName else { throw SFTPTransferError.invalidPath }
        let state = state
        let url = try await worker.perform { state.name = name; return state.parent.appendingPathComponent(name) }
        destination = url
    }
    func write(_ bytes: Data, offset: UInt64) async throws {
        guard !bytes.isEmpty, bytes.count <= 65_536, offset <= UInt64(Int64.max) - UInt64(bytes.count) else {
            throw SFTPTransferError.invalidPath
        }
        let state = state
        try await worker.perform {
            guard state.descriptor >= 0 else { throw SFTPTransferError.localIO }
            try bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < bytes.count {
                    let count = pwrite(state.descriptor, buffer.baseAddress!.advanced(by: written), bytes.count - written,
                                       off_t(offset) + off_t(written))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw TransferPOSIX.error() }
                    written += count
                }
            }
        }
    }
    func commit(replacing expected: SFTPTransferLocalMetadata?) async throws {
        let state = state
        try await worker.perform {
            guard state.ownsTemporary, !state.committed else { throw SFTPTransferError.localIO }
            guard state.descriptor >= 0 || state.readyForCommit else { throw SFTPTransferError.localIO }
            var staging = stat()
            let staged = state.temporaryName.withCString { fstatat(state.directory, $0, &staging, AT_SYMLINK_NOFOLLOW) }
            guard staged == 0, staging.st_dev == state.device, staging.st_ino == state.inode,
                  staging.st_mode & S_IFMT == S_IFREG else { throw SFTPTransferError.destinationChanged }
            let current = try state.inspect()
            if expected == nil, current != nil { throw SFTPTransferError.destinationExists }
            guard current == expected, current?.isRegular != false else { throw SFTPTransferError.destinationChanged }
            if state.descriptor >= 0 {
                if let expected, fchmod(state.descriptor, mode_t(expected.permissions)) != 0 { throw TransferPOSIX.error() }
                guard fsync(state.descriptor) == 0 else { throw TransferPOSIX.error() }
                let fd = state.descriptor; state.descriptor = -1
                guard Darwin.close(fd) == 0 else { throw TransferPOSIX.error() }
                state.readyForCommit = true
            }
            let latest = try state.inspect()
            if expected == nil, latest != nil { throw SFTPTransferError.destinationExists }
            guard latest == expected else { throw SFTPTransferError.destinationChanged }
            let flags = expected == nil ? UInt32(RENAME_EXCL) : 0
            let result = state.temporaryName.withCString { source in
                state.name.withCString { target in renameatx_np(state.directory, source, state.directory, target, flags) }
            }
            guard result == 0 else {
                if expected == nil, errno == EEXIST { throw SFTPTransferError.destinationExists }
                throw TransferPOSIX.error()
            }
            state.ownsTemporary = false; state.committed = true
        }
    }
    func discard() async -> Bool {
        if let discardTask { return await discardTask.value }
        let state = state, worker = worker
        let task = Task {
            let cleaned = (try? await worker.perform { let result = state.discard(); state.cleanup(); return result }) ?? false
            worker.stop()
            return cleaned
        }
        discardTask = task
        return await task.value
    }
}

/// System-only file access for transfer sources and atomic local destinations.
/// Local symlinks and special files are not opened as transfer content.
public struct SystemSFTPTransferLocalFiles: SFTPTransferLocalFiles {
    public init() {}
    public func openSource(_ url: URL) async throws -> any SFTPTransferSource {
        try TransferPOSIX.validate(url)
        let state = TransferSourceState()
        // The worker's lifetime cleanup must own the descriptor even if opening
        // is cancelled before the source object is returned.
        let ownedWorker = TransferFileWorker { state.close() }
        do {
            try await ownedWorker.perform {
                state.descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard state.descriptor >= 0 else { throw TransferPOSIX.error() }
                var info = stat()
                guard fstat(state.descriptor, &info) == 0 else { throw TransferPOSIX.error() }
                guard info.st_mode & S_IFMT == S_IFREG else { throw SFTPTransferError.unsupportedFile }
            }
            try Task.checkCancellation()
            return SystemTransferSource(state: state, worker: ownedWorker)
        } catch { _ = try? await ownedWorker.perform { state.close() }; ownedWorker.stop(); throw error }
    }
    public func prepareDestination(_ url: URL) async throws -> any SFTPTransferDestination {
        try TransferPOSIX.validate(url)
        let state = TransferDestinationState()
        let worker = TransferFileWorker { state.cleanup() }
        do {
            let pair = try await worker.perform {
                let (directory, parent) = try TransferPOSIX.openDirectory(url.deletingLastPathComponent())
                state.directory = directory; state.parent = parent; state.name = url.lastPathComponent
                state.descriptor = state.temporaryName.withCString {
                    openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                }
                guard state.descriptor >= 0 else { throw TransferPOSIX.error() }
                state.ownsTemporary = true
                var info = stat()
                guard fstat(state.descriptor, &info) == 0 else { throw TransferPOSIX.error() }
                state.device = info.st_dev; state.inode = info.st_ino; state.ownsTemporary = true
                return (parent.appendingPathComponent(state.name), parent.appendingPathComponent(state.temporaryName))
            }
            try Task.checkCancellation()
            return SystemTransferDestination(state: state, worker: worker, destination: pair.0, temporary: pair.1)
        } catch {
            let result = try? await worker.perform {
                let cleaned = state.discard()
                let path = state.parent.appendingPathComponent(state.temporaryName)
                state.cleanup()
                return (cleaned, path)
            }
            worker.stop()
            if let result, !result.0 {
                throw SFTPTransferFailure((error as? SFTPTransferError) ?? .localIO, residues: [.local(result.1)])
            }
            throw error
        }
    }
}

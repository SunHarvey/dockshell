import DockShellDomain
import Foundation

public enum TerminalChannelError: Error, Sendable {
    case invalidReadSize, concurrentRead, closed
}

public struct TerminalChannelStatistics: Sendable {
    public let capacity: Int
    public let bufferedBytes: Int
    public let highWatermark: Int
    public let totalWritten: UInt64
    public let totalRead: UInt64
    public let size: TerminalSize
}

/// A fixed-capacity, lossless byte channel for offline tests and future transport adapters.
/// Writers suspend when full; readers suspend when empty. There is no polling timer.
public actor BoundedTerminalChannel: SSHSessionChannel {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var storage: [UInt8]
    private var head = 0
    private var count = 0
    private var highWatermark = 0
    private var written: UInt64 = 0
    private var consumed: UInt64 = 0
    private var ended = false
    private var activeRead: UUID?
    private var reader: Waiter?
    private var activeWriter: UUID?
    private var writers: [Waiter] = []
    private var space: Waiter?
    private var size = TerminalSize(columns: 80, rows: 24)

    public init(capacity: Int = 65_536) {
        precondition(capacity > 0)
        storage = [UInt8](repeating: 0, count: capacity)
    }

    public func read(maxBytes: Int) async throws -> Data? {
        guard maxBytes > 0 else { throw TerminalChannelError.invalidReadSize }
        guard activeRead == nil else { throw TerminalChannelError.concurrentRead }
        let id = UUID()
        activeRead = id
        defer { activeRead = nil }
        return try await withTaskCancellationHandler { () async throws -> Data? in
            while count == 0 {
                try Task.checkCancellation()
                if ended { return nil }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { reader = Waiter(id: id, continuation: continuation) }
                }
            }
            try Task.checkCancellation()
            let length = min(maxBytes, count)
            var result = Data(count: length)
            result.withUnsafeMutableBytes { destination in
                storage.withUnsafeBytes { source in
                    let first = min(length, storage.count - head)
                    destination.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: head), byteCount: first)
                    if first < length {
                        destination.baseAddress!.advanced(by: first).copyMemory(from: source.baseAddress!, byteCount: length - first)
                    }
                }
            }
            head = (head + length) % storage.count
            count -= length
            consumed += UInt64(length)
            if let waiter = space { space = nil; waiter.continuation.resume() }
            return result
        } onCancel: {
            Task { await self.cancelReader(id) }
        }
    }

    public func write(_ bytes: Data) async throws {
        let id = UUID()
        try await withTaskCancellationHandler { () async throws -> Void in
            try Task.checkCancellation()
            guard !ended else { throw TerminalChannelError.closed }
            if activeWriter != nil {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { writers.append(Waiter(id: id, continuation: continuation)) }
                }
            } else { activeWriter = id }
            defer { releaseWriter() }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard !ended else { throw TerminalChannelError.closed }
                if count == storage.count {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { space = Waiter(id: id, continuation: continuation) }
                    }
                    continue
                }
                let length = min(bytes.count - offset, storage.count - count)
                let tail = (head + count) % storage.count
                let capacity = storage.count
                storage.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBytes { source in
                        let first = min(length, capacity - tail)
                        destination.baseAddress!.advanced(by: tail).copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: first)
                        if first < length {
                            destination.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: offset + first), byteCount: length - first)
                        }
                    }
                }
                offset += length
                count += length
                written += UInt64(length)
                highWatermark = max(highWatermark, count)
                if let waiter = reader { reader = nil; waiter.continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancelWriter(id) }
        }
    }

    public func resize(to size: TerminalSize) throws {
        guard !ended else { throw TerminalChannelError.closed }
        self.size = size
    }

    /// Ends production; all queued bytes are still readable before EOF.
    public func finish() {
        ended = true
        wakeClosedWriters()
        if let waiter = reader { reader = nil; waiter.continuation.resume() }
    }

    /// Explicit cancellation may discard queued output, as when the user closes a terminal.
    public func close() {
        count = 0
        finish()
    }

    public func statistics() -> TerminalChannelStatistics {
        TerminalChannelStatistics(capacity: storage.count, bufferedBytes: count, highWatermark: highWatermark,
                                  totalWritten: written, totalRead: consumed, size: size)
    }

    private func releaseWriter() {
        if writers.isEmpty { activeWriter = nil }
        else {
            let next = writers.removeFirst()
            activeWriter = next.id
            next.continuation.resume()
        }
    }

    private func cancelReader(_ id: UUID) {
        if let waiter = reader, waiter.id == id {
            reader = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWriter(_ id: UUID) {
        if let waiter = space, waiter.id == id {
            space = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
        if let index = writers.firstIndex(where: { $0.id == id }) {
            writers.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func wakeClosedWriters() {
        if let waiter = space { space = nil; waiter.continuation.resume(throwing: TerminalChannelError.closed) }
        let pending = writers
        writers.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: TerminalChannelError.closed) }
    }
}

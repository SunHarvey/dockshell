import DockShellApplication
import DockShellDomain
import Foundation

private struct M3ChannelFailure: Error, CustomStringConvertible {
    let description: String
}

/// Unstructured test tasks report completion here, so a broken cancellation implementation
/// fails a deadline without a structured task group waiting forever for its child to exit.
private actor M3ChannelCompletion<Value: Sendable> {
    private var result: Result<Value, any Error>?

    func resolve(_ result: Result<Value, any Error>) { self.result = result }
    func peek() -> Result<Value, any Error>? { result }
    func isCompleted() -> Bool {
        if case .some = result { return true }
        return false
    }
}

/// Losslessness, actual backpressure and cancellation checks for the production byte channel.
enum M3ChannelVerification {
    private enum ExpectedError { case cancelled, invalidReadSize, concurrentRead, closed }

    private static func require(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M3ChannelFailure(description: description) }
    }

    private static func launch<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> (Task<Void, Never>, M3ChannelCompletion<Value>) {
        let completion = M3ChannelCompletion<Value>()
        let task = Task {
            do { await completion.resolve(.success(try await operation())) }
            catch { await completion.resolve(.failure(error)) }
        }
        return (task, completion)
    }

    private static func completed<Value: Sendable>(
        _ completion: M3ChannelCompletion<Value>, timeout: Duration = .seconds(3)
    ) async throws -> Result<Value, any Error> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = await completion.peek() { return result }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw M3ChannelFailure(description: "Byte-channel operation exceeded its completion deadline")
    }

    private static func expectFailure<Value: Sendable>(
        _ completion: M3ChannelCompletion<Value>, _ expected: ExpectedError
    ) async throws {
        switch try await completed(completion) {
        case .success:
            throw M3ChannelFailure(description: "Byte-channel operation unexpectedly succeeded")
        case .failure(let error):
            if error is CancellationError {
                if case .cancelled = expected { return }
            }
            if let channelError = error as? TerminalChannelError {
                switch (channelError, expected) {
                case (.invalidReadSize, .invalidReadSize), (.concurrentRead, .concurrentRead), (.closed, .closed):
                    return
                default: break
                }
            }
            throw M3ChannelFailure(description: "Unexpected byte-channel failure: \(type(of: error))")
        }
    }

    private static func read(_ channel: BoundedTerminalChannel, maxBytes: Int) async throws -> Data? {
        let (task, result) = launch { try await channel.read(maxBytes: maxBytes) }
        defer { task.cancel() }
        return try await completed(result).get()
    }

    static func run() async throws {
        try await verifySlowConsumer()
        try await verifyFinishAndResize()
        try await verifyCancelledRead()
        try await verifyCancelledWriters()
        print("PASS M3 channel: 4 MiB ordered binary data, bounded watermark, producer backpressure, partial EOF, resize")
        print("PASS M3 channel cancellation: parked reader, full-buffer writer and queued writer complete promptly")
    }

    private static func verifySlowConsumer() async throws {
        let capacity = 65_536
        let total = 4 * 1_024 * 1_024
        let channel = BoundedTerminalChannel(capacity: capacity)
        let block = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0) })
        let (producer, produced) = launch {
            for _ in 0..<(total / block.count) { try await channel.write(block) }
            await channel.finish()
        }
        var consumer: Task<Void, Never>?
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            var full = false
            while clock.now < deadline {
                let statistics = await channel.statistics()
                if statistics.bufferedBytes == capacity { full = true; break }
                try await Task.sleep(for: .milliseconds(2))
            }
            try require(full, "Producer did not fill the fixed-capacity buffer")
            // No consumer exists yet. A successful write of all 4 MiB would prove unbounded buffering.
            try await Task.sleep(for: .milliseconds(25))
            try require(!(await produced.isCompleted()), "Producer ignored backpressure while the buffer was full")
            let paused = await channel.statistics()
            try require(paused.bufferedBytes == capacity && paused.highWatermark == capacity,
                        "Paused-consumer buffer exceeded or failed to retain its capacity")

            let started = launch {
                var offset = 0
                while let bytes = try await channel.read(maxBytes: 7_777) {
                    guard !bytes.isEmpty, bytes.count <= 7_777 else {
                        throw M3ChannelFailure(description: "Read violated its byte limit")
                    }
                    for byte in bytes {
                        guard byte == UInt8(truncatingIfNeeded: offset) else {
                            throw M3ChannelFailure(description: "Binary output was dropped, reordered or altered")
                        }
                        offset += 1
                    }
                    // Deliberately consume more slowly than the producer, without storing a second full output copy.
                    try await Task.sleep(for: .milliseconds(1))
                }
                return offset
            }
            consumer = started.0
            let consumed = try await completed(started.1, timeout: .seconds(12)).get()
            _ = try await completed(produced).get()
            let statistics = await channel.statistics()
            try require(consumed == total, "EOF arrived before the complete binary payload")
            try require(statistics.totalWritten == UInt64(total) && statistics.totalRead == UInt64(total),
                        "Byte-accounting totals do not match the validated payload")
            try require(statistics.bufferedBytes == 0 && statistics.highWatermark <= statistics.capacity,
                        "Finished channel retained output or exceeded the configured bound")
            await channel.close()
        } catch {
            producer.cancel()
            consumer?.cancel()
            await channel.close()
            throw error
        }
    }

    private static func verifyFinishAndResize() async throws {
        let channel = BoundedTerminalChannel(capacity: 16)
        let size = TerminalSize(columns: 132, rows: 43)
        try await channel.resize(to: size)
        try require(await channel.statistics().size == size, "Resize metadata was not updated")
        let payload = Data(0..<11)
        try await channel.write(payload)
        await channel.finish()
        var received = Data()
        var lengths: [Int] = []
        while let bytes = try await read(channel, maxBytes: 4) {
            received.append(bytes)
            lengths.append(bytes.count)
        }
        try require(received == payload && lengths == [4, 4, 3], "finish() discarded or duplicated the final partial read")
        let (writer, result) = launch { try await channel.write(Data([1])) }
        defer { writer.cancel() }
        try await expectFailure(result, .closed)
        await channel.close()
    }

    private static func verifyCancelledRead() async throws {
        let channel = BoundedTerminalChannel(capacity: 128)
        let (reader, result) = launch { try await channel.read(maxBytes: 16) }
        do {
            try await Task.sleep(for: .milliseconds(25))
            try require(!(await result.isCompleted()), "An empty idle channel did not suspend its reader")
            let before = await channel.statistics()
            try await Task.sleep(for: .milliseconds(25))
            let after = await channel.statistics()
            try require(before.totalRead == after.totalRead && before.totalWritten == after.totalWritten
                        && after.bufferedBytes == 0, "Idle channel changed its data counters")
            let (duplicate, duplicateResult) = launch { try await channel.read(maxBytes: 1) }
            defer { duplicate.cancel() }
            try await expectFailure(duplicateResult, .concurrentRead)
            reader.cancel()
            try await expectFailure(result, .cancelled)
            // A cancelled reader must not consume later bytes or keep the single-reader slot occupied.
            try await channel.write(Data([0xA5]))
            try require(try await read(channel, maxBytes: 1) == Data([0xA5]), "Cancelled reader retained ownership or stole output")
            let (invalid, invalidResult) = launch { try await channel.read(maxBytes: 0) }
            defer { invalid.cancel() }
            try await expectFailure(invalidResult, .invalidReadSize)
            await channel.finish()
            try require(try await read(channel, maxBytes: 1) == nil, "Finished empty channel did not return EOF")
            await channel.close()
        } catch {
            reader.cancel()
            await channel.close()
            throw error
        }
    }

    private static func verifyCancelledWriters() async throws {
        let channel = BoundedTerminalChannel(capacity: 128)
        let original = Data(0..<128)
        try await channel.write(original)
        let (writer, result) = launch { try await channel.write(Data([0xA1])) }
        let (queued, queuedResult) = launch { try await channel.write(Data([0xB2])) }
        do {
            try await Task.sleep(for: .milliseconds(25))
            let writerCompleted = await result.isCompleted()
            let queuedCompleted = await queuedResult.isCompleted()
            try require(!writerCompleted && !queuedCompleted,
                        "A writer completed despite a full buffer")
            // Either scheduled writer may be first; both must cancel without accepting a byte.
            queued.cancel()
            try await expectFailure(queuedResult, .cancelled)
            try require(!(await result.isCompleted()), "Cancelling one writer completed the other writer")
            writer.cancel()
            try await expectFailure(result, .cancelled)
            let statistics = await channel.statistics()
            try require(statistics.bufferedBytes == 128 && statistics.totalWritten == 128,
                        "Cancelled full-buffer writers changed queued bytes")
            try require(try await read(channel, maxBytes: 128) == original, "Writer cancellation altered pre-existing output")
            try await channel.write(Data([0x7F]))
            try require(try await read(channel, maxBytes: 1) == Data([0x7F]), "Writer slot was not released after cancellation")
            await channel.close()
            try require(await channel.statistics().bufferedBytes == 0, "close() retained queued bytes")
        } catch {
            writer.cancel()
            queued.cancel()
            await channel.close()
            throw error
        }
    }
}

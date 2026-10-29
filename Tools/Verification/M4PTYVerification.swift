import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M4PTYFailure: Error, CustomStringConvertible {
    let description: String
}

private actor M4PTYCompletion<Value: Sendable> {
    private var value: Result<Value, any Error>?
    func resolve(_ value: Result<Value, any Error>) { self.value = value }
    func peek() -> Result<Value, any Error>? { value }
    func isCompleted() -> Bool { if case .some = value { return true }; return false }
}

/// Exercises the production supervisor with a deterministic local helper. These
/// checks use real PTYs, genuine partial writes, and actual child-process reaping.
enum M4PTYVerification {
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M4PTYFailure(description: message) }
    }

    private static func launch<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) -> (Task<Void, Never>, M4PTYCompletion<Value>) {
        let result = M4PTYCompletion<Value>()
        let task = Task {
            do { await result.resolve(.success(try await body())) }
            catch { await result.resolve(.failure(error)) }
        }
        return (task, result)
    }

    private static func completed<Value: Sendable>(
        _ result: M4PTYCompletion<Value>, timeout: Duration = .seconds(5)
    ) async throws -> Result<Value, any Error> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let value = await result.peek() { return value }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw M4PTYFailure(description: "PTY operation exceeded its deadline")
    }

    private static func line(_ channel: PTYProcessChannel) async throws -> String {
        var result = Data()
        while result.count < 256 {
            guard let bytes = try await channel.read(maxBytes: 1) else {
                throw M4PTYFailure(description: "PTY fixture ended before its response")
            }
            result.append(bytes)
            if bytes.last == 10 { return String(decoding: result, as: UTF8.self) }
        }
        throw M4PTYFailure(description: "PTY fixture response exceeded its bound")
    }

    private static func fixture(_ helperURL: URL) async throws -> PTYProcessChannel {
        let channel = try await PTYProcessChannel.startVerification(
            helperURL: helperURL, size: TerminalSize(columns: 80, rows: 24))
        let (task, result) = launch { try await line(channel) }
        defer { task.cancel() }
        do {
            try require(try await completed(result).get() == "READY 24 80 1 1 1\n",
                        "PTY initial size, controlling session, cooked defaults, or UTF-8 erase flag were incorrect")
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }

    static func run(helperURL: URL) async throws {
        try await verifyOutputAndResize(helperURL)
        try await verifyDuplex(helperURL)
        try await verifyCancellation(helperURL)
        try await verifyReadCompletionRaces(helperURL)
        try await verifyBlockedWriters(helperURL)
        try await verifyReleaseAndSystemSSH(helperURL)
        print("PASS M4 PTY: cooked UTF-8 slave defaults, controlling terminal, SIGWINCH, 4 MiB binary output and duplex IO, bounded backpressure")
        print("PASS M4 PTY lifecycle: canceled reader/writers, bounded separate diagnostics, EOF, child reaping, system ssh launch")
    }

    private static func verifyOutputAndResize(_ helperURL: URL) async throws {
        let channel = try await fixture(helperURL)
        let (task, result) = launch {
            try await channel.resize(to: TerminalSize(columns: 132, rows: 43))
            try await channel.write(Data("s".utf8))
            try require(try await line(channel) == "SIZE 43 132 1\n", "PTY resize did not deliver SIGWINCH and the new size")

            try await channel.write(Data("b".utf8))
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            var full = false
            while clock.now < deadline {
                if await channel.statistics().incomingBytes == 65_536 { full = true; break }
                try await Task.sleep(for: .milliseconds(2))
            }
            try require(full, "The real PTY did not fill its bounded receiving ring")
            try await Task.sleep(for: .milliseconds(40))
            try require(await channel.statistics().incomingBytes == 65_536, "Paused consumer changed the full receive ring")
            let total = 4 * 1_024 * 1_024
            var received = 0
            while received < total {
                guard let data = try await channel.read(maxBytes: 7_777), !data.isEmpty, data.count <= 7_777 else {
                    throw M4PTYFailure(description: "PTY returned EOF or an invalid read length during binary output")
                }
                for byte in data {
                    try require(byte == UInt8(truncatingIfNeeded: received), "PTY output was altered, reordered, or lost")
                    received += 1
                }
                try await Task.sleep(for: .microseconds(100))
            }
            try require(received == total, "PTY binary output length was incorrect")
            try await channel.write(Data("d".utf8))
            try require(try await line(channel) == "DONE\n", "Diagnostics leaked into terminal output")
            let diagnostics = await channel.diagnosticData()
            let tail = Data("\nM5-final-diagnostic\n".utf8)
            try require(diagnostics.count == 32_768 && diagnostics.suffix(tail.count) == tail
                        && diagnostics.dropLast(tail.count).allSatisfy { $0 == 68 },
                        "PTY diagnostics lost their bounded tail or mixed with terminal output")
            try await channel.write(Data("q".utf8))
            try require(try await channel.read(maxBytes: 4) == nil, "PTY did not report EOF after fixture exit")
            try require(try await channel.exitStatus() == 0, "PTY fixture did not exit cleanly")
            let statistics = await channel.statistics()
            try require(statistics.incomingHighWatermark == 65_536 && statistics.outgoingHighWatermark <= 65_536,
                        "PTY queue exceeded its fixed capacity")
            try require(statistics.bytesReceived == statistics.bytesConsumed && statistics.finished,
                        "PTY output remained buffered after complete EOF")
        }
        do { _ = try await completed(result, timeout: .seconds(15)).get() }
        catch { task.cancel(); await channel.close(); throw error }
        await channel.close()
    }

    private static func verifyDuplex(_ helperURL: URL) async throws {
        let channel = try await fixture(helperURL)
        let count = 4 * 1_024 * 1_024
        let payload = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
        var command = Data([UInt8(ascii: "e")])
        var wireCount = UInt32(count).bigEndian
        withUnsafeBytes(of: &wireCount) { command.append(contentsOf: $0) }
        try await channel.write(command)
        let (producer, produced) = launch { try await channel.write(payload) }
        let (consumer, consumed) = launch {
            var offset = 0
            while offset < count {
                guard let data = try await channel.read(maxBytes: 4_093) else {
                    throw M4PTYFailure(description: "PTY duplex echo ended early")
                }
                for byte in data {
                    try require(byte == UInt8(truncatingIfNeeded: offset), "PTY duplex partial writes changed byte order")
                    offset += 1
                }
            }
            return offset
        }
        do {
            try require(try await completed(consumed, timeout: .seconds(15)).get() == count,
                        "PTY duplex echo length was incorrect")
            _ = try await completed(produced).get()
            try await channel.write(Data("q".utf8))
            try require(try await channel.exitStatus() == 0, "PTY duplex fixture failed")
            let stats = await channel.statistics()
            try require(stats.incomingHighWatermark <= 65_536 && stats.outgoingHighWatermark <= 65_536,
                        "PTY duplex queues grew past their bounds")
        } catch {
            producer.cancel(); consumer.cancel()
            await channel.close()
            throw error
        }
        await channel.close()
    }

    private static func verifyCancellation(_ helperURL: URL) async throws {
        let channel = try await fixture(helperURL)
        let (reader, result) = launch { try await channel.read(maxBytes: 1) }
        do {
            try await Task.sleep(for: .milliseconds(30))
            try require(!(await result.isCompleted()), "Idle PTY read did not suspend")
            do {
                _ = try await channel.read(maxBytes: 1)
                throw M4PTYFailure(description: "PTY accepted a concurrent reader")
            } catch PTYProcessError.concurrentRead {}
            reader.cancel()
            switch try await completed(result) {
            case .failure(let error): try require(error is CancellationError, "PTY read did not preserve cancellation")
            case .success: throw M4PTYFailure(description: "Canceled PTY read unexpectedly completed")
            }
            try await channel.write(Data("s".utf8))
            let (next, response) = launch { try await line(channel) }
            defer { next.cancel() }
            try require(try await completed(response).get() == "SIZE 24 80 0\n", "Canceled reader stole later output")
        } catch {
            reader.cancel(); await channel.close(); throw error
        }
        await channel.close()
        try require(await channel.statistics().finished, "close returned before child reaping")
    }

    private static func verifyBlockedWriters(_ helperURL: URL) async throws {
        let channel = try await fixture(helperURL)
        try await channel.write(Data("p".utf8))
        let (writer, written) = launch { try await channel.write(Data(repeating: 0x7F, count: 4 * 1_024 * 1_024)) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var full = false
        while clock.now < deadline {
            if await channel.statistics().outgoingBytes == 65_536 { full = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let (queued, queuedResult) = launch { try await channel.write(Data([0xA5])) }
        do {
            try require(full, "PTY input did not apply backpressure to a stopped slave")
            try await Task.sleep(for: .milliseconds(30))
            let activeCompleted = await written.isCompleted()
            let queuedCompleted = await queuedResult.isCompleted()
            try require(!activeCompleted && !queuedCompleted,
                        "A blocked PTY writer ignored backpressure")
            queued.cancel()
            switch try await completed(queuedResult) {
            case .failure(let error): try require(error is CancellationError, "Queued writer cancellation was not preserved")
            case .success: throw M4PTYFailure(description: "Canceled queued PTY writer unexpectedly completed")
            }
            writer.cancel()
            switch try await completed(written) {
            case .failure(let error): try require(error is CancellationError, "Active writer cancellation was not preserved")
            case .success: throw M4PTYFailure(description: "Canceled full PTY writer unexpectedly completed")
            }
            try require(await channel.statistics().bytesEnqueued < 4 * 1_024 * 1_024,
                        "PTY accepted a complete large write while its slave was stopped")
        } catch {
            writer.cancel(); queued.cancel(); await channel.close(); throw error
        }
        await channel.close()
        try require(await channel.statistics().finished, "Blocked PTY child was not reaped")
    }

    private static func verifyReadCompletionRaces(_ helperURL: URL) async throws {
        for iteration in 0..<24 {
            let channel = try await fixture(helperURL)
            let (reader, result) = launch { try await channel.read(maxBytes: 1) }
            if iteration % 2 == 0 {
                // Exercise data arrival racing both cancellation and explicit close.
                try await channel.write(Data("s".utf8))
            }
            reader.cancel()
            await channel.close()
            switch try await completed(result) {
            case .success(let bytes):
                try require(bytes?.count == 1, "A raced read returned an invalid completion")
            case .failure(let error):
                try require(error is CancellationError || (error as? PTYProcessError) == .closed,
                            "A raced read completed with an unexpected failure")
            }
            try require(await channel.statistics().finished, "A cancellation race leaked its child")
        }
    }

    private static func verifyReleaseAndSystemSSH(_ helperURL: URL) async throws {
        var channel: PTYProcessChannel? = try await fixture(helperURL)
        let pid = channel!.processID
        channel = nil
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try require(kill(pid, 0) < 0 && errno == ESRCH,
                    "Dropping the last channel reference leaked a child or retained the actor")

        let ssh = try await PTYProcessChannel.start(helperURL: helperURL, arguments: ["-V"],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            size: TerminalSize(columns: 80, rows: 24))
        let (monitor, result) = launch { try await ssh.exitStatus() }
        defer { monitor.cancel() }
        do {
            try require(try await completed(result).get() == 0, "Bundled helper failed to execute the fixed system ssh")
            try require(await ssh.diagnosticData().starts(with: Data("OpenSSH_".utf8)),
                        "System ssh version did not travel through the separate diagnostics pipe")
            try require(try await ssh.read(maxBytes: 1) == nil, "System ssh diagnostics were mixed with terminal output")
        } catch { await ssh.close(); throw error }
        await ssh.close()
    }
}

import DockShellInfrastructure
import Foundation

private struct M9PipeFailure: Error, CustomStringConvertible {
    let description: String
}

/// Offline checks execute only the fixed system SSH executable. Neither command
/// contains a destination, so these checks never open a network connection or
/// read personal SSH configuration. Diagnostic bytes are never printed.
enum M9PipeVerification {
    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "C"]

    static func run() async throws {
        let version = try await PipeProcessChannel.startSSH(arguments: ["-V"], environment: environment)
        do {
            do {
                _ = try await version.read(maxBytes: 0)
                throw M9PipeFailure(description: "A zero-sized pipe read was accepted")
            } catch PipeProcessError.invalidReadSize { }
            do {
                try await version.write(Data(count: 1_048_581))
                throw M9PipeFailure(description: "An oversized pipe write exceeded the declared bound")
            } catch PipeProcessError.capacityExceeded { }
            let result = try await complete(version)
            try check(result.status == 0 && result.stdout.isEmpty,
                      "The binary pipe did not preserve the version command's independent stdout and stderr")
            let diagnostics = await version.diagnosticData()
            try check(!diagnostics.isEmpty && diagnostics.count <= 32_768,
                      "Version command diagnostics were missing or exceeded the bounded tail")
            await version.close()
            await version.close()
            try await checkFinished(version)
            try await expectClosedRead(version)
            try await expectClosedWrite(version)
        } catch {
            await version.close()
            throw error
        }

        // Invalid configuration is rejected by SSH's option parser before it
        // can require a hostname, perform authentication or contact a server.
        let invalid = try await PipeProcessChannel.startSSH(
            arguments: ["-F", "none", "-o", "DockShellInvalidOption=yes"], environment: environment)
        do {
            let result = try await complete(invalid)
            try check(result.status != 0 && result.stdout.isEmpty,
                      "An invalid SSH configuration did not produce a nonzero, binary-clean exit")
            try check(await invalid.diagnosticData().count <= 32_768,
                      "Invalid-argument diagnostics exceeded the bounded tail")
            await invalid.close()
            try await checkFinished(invalid)
        } catch {
            await invalid.close()
            throw error
        }

        for (arguments, variables) in [
            (["-V\0"], environment),
            (["-V"], ["INVALID=NAME": "value"]),
            (["-V"], ["PATH": "/usr/bin\0"])
        ] {
            do {
                let unexpected = try await PipeProcessChannel.startSSH(arguments: arguments, environment: variables)
                await unexpected.close()
                throw M9PipeFailure(description: "Invalid pipe spawn input was accepted")
            } catch PipeProcessError.launchFailed { }
        }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PipeProcessChannel.startSSH(arguments: ["-V"], environment: environment)
        }
        do {
            let unexpected = try await cancelled.value
            await unexpected.close()
            throw M9PipeFailure(description: "A pre-cancelled pipe launch completed")
        } catch is CancellationError { }
        print("PASS M9 binary pipe: fixed offline SSH, separate stdout/stderr, natural EOF/exit, bounded diagnostics, repeated close and pre-launch validation/cancellation")
    }

    private struct Result: Sendable {
        let stdout: Data
        let status: Int32
    }

    private static func complete(_ process: PipeProcessChannel) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                var bytes = Data()
                while let chunk = try await process.read(maxBytes: 4_096) {
                    guard bytes.count + chunk.count <= 65_536 else {
                        throw M9PipeFailure(description: "An offline SSH command exceeded its output bound")
                    }
                    bytes.append(chunk)
                }
                return Result(stdout: bytes, status: try await process.exitStatus())
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                await process.close()
                throw M9PipeFailure(description: "An offline SSH pipe failed to reach EOF and reap its child")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw M9PipeFailure(description: "Offline pipe verification returned no result")
            }
            return result
        }
    }

    private static func checkFinished(_ process: PipeProcessChannel) async throws {
        let statistics = await process.statistics()
        try check(statistics.finished && statistics.incomingBytes == 0 && statistics.outgoingBytes == 0,
                  "Closing a pipe did not finish its child and clear queued data")
        try check(statistics.incomingHighWatermark <= 65_536 && statistics.outgoingHighWatermark <= 65_536,
                  "The shared pipe rings exceeded their declared bounds")
    }

    private static func expectClosedRead(_ process: PipeProcessChannel) async throws {
        do {
            _ = try await process.read(maxBytes: 1)
            throw M9PipeFailure(description: "A closed pipe accepted another read")
        } catch PipeProcessError.closed { }
    }

    private static func expectClosedWrite(_ process: PipeProcessChannel) async throws {
        do {
            try await process.write(Data([0, 0xff]))
            throw M9PipeFailure(description: "A closed pipe accepted another write")
        } catch PipeProcessError.closed { }
    }

    private static func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M9PipeFailure(description: description) }
    }
}

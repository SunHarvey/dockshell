import Darwin
import DockShellInfrastructure
import Foundation

private struct M5BrokerFailure: Error, CustomStringConvertible {
    let description: String
}

private struct M5BrokerHelperResult: Sendable {
    let status: Int32
    let output: Data
}

/// Exercises READY-only key/agent connections and passphrase delivery through the signed helper.
/// The verifier stands in for the parent SSH process; no personal key or live credential is read.
enum M5BrokerVerification {
    private static func require(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M5BrokerFailure(description: description) }
    }

    static func run(helperURL: URL) async throws {
        try await verifyReadyOnly(helperURL: helperURL)
        try await verifyReadyOnlyParent(helperURL: helperURL)
        try await verifyPassphrase(helperURL: helperURL)
        try await verifyReadyOnlyCancellation(helperURL: helperURL)
        print("PASS M5 broker: READY-only rejects all credential requests; nonce/path/parent checks, one-shot passphrase and cleanup")
    }

    private static func verifyReadyOnly(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: nil, helperURL: helperURL)
        let environment = broker.environment
        let directory = URL(fileURLWithPath: environment["DOCKSHELL_ASKPASS_SOCKET"]!).deletingLastPathComponent()
        do {
            try await broker.bindSSHProcess(getpid())
            try require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["s"],
                        "READY-only mode created an unexpected file")
            var wrongNonce = environment
            wrongNonce["DOCKSHELL_ASKPASS_TOKEN"] = UUID().uuidString
            let badReady = try await helper(helperURL, arguments: ["--ready"], environment: wrongNonce)
            try require(badReady.status != 0 && badReady.output.isEmpty,
                        "READY-only mode accepted a different connection nonce")

            let copied = directory.appendingPathComponent("different-helper")
            try FileManager.default.copyItem(at: helperURL, to: copied)
            let badPath = try await helper(copied, arguments: ["--ready"], environment: environment)
            try FileManager.default.removeItem(at: copied)
            try require(badPath.status != 0 && badPath.output.isEmpty,
                        "READY-only mode accepted a helper at a different path")

            // Even a correctly signed, correctly parented helper with the right nonce
            // must not receive an empty password or consume a nonexistent credential.
            for _ in 0..<2 {
                let denied = try await helper(helperURL, environment: environment)
                let delivered = await broker.wasDelivered()
                try require(denied.status != 0 && denied.output.isEmpty && !delivered,
                            "READY-only mode returned or consumed a credential")
            }
            let ready = try await helper(helperURL, arguments: ["--ready"], environment: environment)
            try require(ready.status == 0 && ready.output.isEmpty, "READY-only notification failed")
            try await broker.waitUntilAuthenticated()
            try require(await broker.wasAuthenticated(), "Verified READY was lost before process-outcome inspection")
            try require(!(await broker.wasDelivered()), "READY-only notification recorded credential delivery")
            await broker.close()
            try require(!FileManager.default.fileExists(atPath: directory.path),
                        "READY-only completion left its socket directory")
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("different-helper"))
            await broker.close()
            throw error
        }
    }

    private static func verifyReadyOnlyParent(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: nil, helperURL: helperURL)
        do {
            try await broker.bindSSHProcess(getppid())
            let ready = try await helper(helperURL, arguments: ["--ready"], environment: broker.environment)
            let delivered = await broker.wasDelivered()
            try require(ready.status != 0 && ready.output.isEmpty && !delivered,
                        "READY-only mode accepted an unrelated parent process")
            await broker.close()
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyPassphrase(helperURL: URL) async throws {
        let passphrase = Data("synthetic-only-private-passphrase-🙂".utf8)
        let broker = try await OpenSSHCredentialBroker.prepare(secret: passphrase, helperURL: helperURL)
        do {
            try await broker.bindSSHProcess(getpid())
            let first = try await helper(helperURL, environment: broker.environment)
            let delivered = await broker.wasDelivered()
            try require(first.status == 0 && first.output == passphrase + Data([10]) && delivered,
                        "The private askpass pipe changed the synthetic passphrase")
            let second = try await helper(helperURL, environment: broker.environment)
            try require(second.status != 0 && second.output.isEmpty, "The passphrase was delivered more than once")
            let ready = try await helper(helperURL, arguments: ["--ready"], environment: broker.environment)
            try require(ready.status == 0 && ready.output.isEmpty, "Passphrase authentication READY failed")
            try await broker.waitUntilAuthenticated()
            await broker.close()
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyReadyOnlyCancellation(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: nil, helperURL: helperURL)
        let directory = URL(fileURLWithPath: broker.environment["DOCKSHELL_ASKPASS_SOCKET"]!).deletingLastPathComponent()
        let waiting = Task { try await broker.waitUntilAuthenticated() }
        waiting.cancel()
        do {
            try await waiting.value
            await broker.close()
            throw M5BrokerFailure(description: "Canceled READY-only authentication completed")
        } catch is CancellationError {}
        await broker.close()
        await broker.close()
        try require(!FileManager.default.fileExists(atPath: directory.path),
                    "Canceling READY-only mode left its socket directory")
        do {
            let invalid = try await OpenSSHCredentialBroker.prepare(secret: Data(), helperURL: helperURL)
            await invalid.close()
            throw M5BrokerFailure(description: "Empty Data was confused with READY-only mode")
        } catch OpenSSHCredentialBrokerError.invalidSecret {}
    }

    private static func helper(
        _ url: URL, arguments: [String] = ["ignored-passphrase-verification-prompt"], environment: [String: String]
    ) async throws -> M5BrokerHelperResult {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    do {
                        let process = Process()
                        process.executableURL = url
                        process.arguments = arguments
                        process.environment = environment
                        process.standardInput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        try process.run()
                        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
                        process.waitUntilExit()
                        continuation.resume(returning: M5BrokerHelperResult(status: process.terminationStatus, output: output))
                    } catch {
                        continuation.resume(throwing: M5BrokerFailure(description: "Could not execute the signed M5 verification helper"))
                    }
                }
            }
        }
    }
}

import Darwin
import DockShellInfrastructure
import Foundation

private struct M4CredentialFailure: Error, CustomStringConvertible {
    let description: String
}

private struct M4HelperResult: Sendable {
    let status: Int32
    let output: Data
}

/// Exercises the real signed helper and production rendezvous, using a synthetic secret.
/// The verifier is the expected parent in this fixture; production supplies its spawned SSH PID.
enum M4CredentialVerification {
    private static func require(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M4CredentialFailure(description: description) }
    }

    static func run(helperURL: URL) async throws {
        for invalid in [Data(), Data(repeating: 65, count: 1024), Data([65, 0, 66]),
                        Data([65, 10, 66]), Data([65, 13, 66])] {
            do {
                let broker = try await OpenSSHCredentialBroker.prepare(secret: invalid, helperURL: helperURL)
                await broker.close()
                throw M4CredentialFailure(description: "An unrepresentable askpass secret was accepted")
            } catch OpenSSHCredentialBrokerError.invalidSecret {}
        }
        try await verifyIdentityAndOneShot(helperURL: helperURL)
        try await verifyReplacedSignature(helperURL: helperURL)
        try await verifyBindingRace(helperURL: helperURL)
        try await verifyWrongParent(helperURL: helperURL)
        try await verifyReadyWithoutPassword(helperURL: helperURL)
        try await verifyCancellation(helperURL: helperURL)
        print("PASS M4 credentials: signed helper, wrong nonce/path/parent/signature rejection, one-shot secret, READY and cleanup")
        print("PASS M4 credential cancellation: parked listener wakes; empty/multiline/NUL/oversized passwords rejected explicitly")
    }

    private static func verifyReplacedSignature(helperURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockShell-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = directory.appendingPathComponent("helper")
        try FileManager.default.copyItem(at: helperURL, to: copied)
        let broker = try await OpenSSHCredentialBroker.prepare(secret: Data("signature-fixture".utf8), helperURL: copied)
        do {
            try await broker.bindSSHProcess(getpid())
            // A validly signed replacement at the SAME path must not satisfy the original
            // ad-hoc helper's code requirement. No application helper is modified here.
            let signed = try await runHelper(URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", "--identifier", "dev.dockshell.verification.replaced", copied.path],
                environment: [:])
            try require(signed.status == 0, "Could not sign a temporary replacement helper")
            let rejected = try await runHelper(copied, environment: broker.environment)
            let delivered = await broker.wasDelivered()
            try require(rejected.status != 0 && rejected.output.isEmpty && !delivered,
                        "A differently signed helper at the original path received a password")
            await broker.close()
            // The replacement itself is executable and validly signed. A fresh broker
            // may explicitly pin that new identity, proving the previous failure was identity.
            let repinned = try await OpenSSHCredentialBroker.prepare(secret: Data("new-identity-fixture".utf8), helperURL: copied)
            do {
                try await repinned.bindSSHProcess(getpid())
                let response = try await runHelper(copied, environment: repinned.environment)
                try require(response.status == 0 && response.output == Data("new-identity-fixture\n".utf8),
                            "The newly pinned signed helper could not authenticate")
                await repinned.close()
            } catch {
                await repinned.close()
                throw error
            }
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyIdentityAndOneShot(helperURL: URL) async throws {
        let secret = Data("仅供验证-$'`🙂".utf8)
        let broker = try await OpenSSHCredentialBroker.prepare(secret: secret, helperURL: helperURL)
        let environment = broker.environment
        let socketPath = environment["DOCKSHELL_ASKPASS_SOCKET"]!
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            let socketMode = try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber
            try require(directoryMode?.intValue == 0o700 && socketMode?.intValue == 0o600,
                        "Credential rendezvous permissions are not private")
            try require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["s"],
                        "Credential rendezvous wrote an unexpected disk artifact")
            try require(!environment.values.contains(String(decoding: secret, as: UTF8.self)),
                        "A credential entered the child environment")
            try await broker.bindSSHProcess(getpid())

            var wrongNonce = environment
            wrongNonce["DOCKSHELL_ASKPASS_TOKEN"] = UUID().uuidString
            let rejectedNonce = try await runHelper(helperURL, environment: wrongNonce)
            try require(rejectedNonce.status != 0 && rejectedNonce.output.isEmpty,
                        "An incorrect nonce received a credential")

            let copied = directory.appendingPathComponent("copied-helper")
            try FileManager.default.copyItem(at: helperURL, to: copied)
            do {
                let rejectedPath = try await runHelper(copied, environment: environment)
                try require(rejectedPath.status != 0 && rejectedPath.output.isEmpty,
                            "An executable at a different path received a credential")
            } catch {
                try? FileManager.default.removeItem(at: copied)
                throw error
            }
            try FileManager.default.removeItem(at: copied)

            var confirmation = environment
            confirmation["SSH_ASKPASS_PROMPT"] = "confirm"
            let rejectedConfirmation = try await runHelper(helperURL, environment: confirmation)
            try require(rejectedConfirmation.status != 0 && rejectedConfirmation.output.isEmpty,
                        "A confirmation prompt received the password")

            let accepted = try await runHelper(helperURL, environment: environment)
            try require(accepted.status == 0 && accepted.output == secret + Data([10]),
                        "The askpass private pipe did not preserve the exact password bytes")
            try require(await broker.wasDelivered(), "The credential delivery was not recorded")

            let repeated = try await runHelper(helperURL, environment: environment)
            try require(repeated.status != 0 && repeated.output.isEmpty,
                        "A second helper request reused a consumed credential")

            let ready = try await runHelper(helperURL, arguments: ["--ready"], environment: environment)
            try require(ready.status == 0 && ready.output.isEmpty, "READY printed output or failed")
            try await broker.waitUntilAuthenticated()
            await broker.close()
            try require(!FileManager.default.fileExists(atPath: directory.path),
                        "The completed credential rendezvous left its temporary directory")
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyBindingRace(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: Data("binding-fixture".utf8), helperURL: helperURL)
        let pending = Task { try await runHelper(helperURL, environment: broker.environment) }
        do {
            try await Task.sleep(for: .milliseconds(30))
            try require(!(await broker.wasDelivered()), "Credential escaped before the SSH PID was bound")
            try await broker.bindSSHProcess(getpid())
            let response = try await pending.value
            try require(response.status == 0 && response.output == Data("binding-fixture\n".utf8),
                        "A helper arriving before PID binding did not resume safely")
            await broker.close()
        } catch {
            await broker.close()
            _ = try? await pending.value
            throw error
        }
    }

    private static func verifyWrongParent(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: Data("parent-fixture".utf8), helperURL: helperURL)
        do {
            try await broker.bindSSHProcess(getppid())
            let response = try await runHelper(helperURL, environment: broker.environment)
            let delivered = await broker.wasDelivered()
            try require(response.status != 0 && response.output.isEmpty && !delivered,
                        "A helper outside the expected SSH process received a credential")
            await broker.close()
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyReadyWithoutPassword(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: Data("unused-fixture".utf8), helperURL: helperURL)
        do {
            try await broker.bindSSHProcess(getpid())
            let ready = try await runHelper(helperURL, arguments: ["--ready"], environment: broker.environment)
            try require(ready.status == 0 && ready.output.isEmpty, "Passwordless READY was not acknowledged")
            try await broker.waitUntilAuthenticated()
            try require(!(await broker.wasDelivered()), "READY incorrectly exposed an unused password")
            await broker.close()
        } catch {
            await broker.close()
            throw error
        }
    }

    private static func verifyCancellation(helperURL: URL) async throws {
        let broker = try await OpenSSHCredentialBroker.prepare(secret: Data("cancel-fixture".utf8), helperURL: helperURL)
        let directory = URL(fileURLWithPath: broker.environment["DOCKSHELL_ASKPASS_SOCKET"]!).deletingLastPathComponent()
        let waiting = Task { try await broker.waitUntilAuthenticated() }
        waiting.cancel()
        do {
            try await waiting.value
            await broker.close()
            throw M4CredentialFailure(description: "Canceling authentication unexpectedly succeeded")
        } catch is CancellationError {}
        await broker.close()
        await broker.close()
        try require(!FileManager.default.fileExists(atPath: directory.path),
                    "Canceling authentication left its temporary directory")
    }

    private static func runHelper(
        _ url: URL, arguments: [String] = ["ignored-verification-prompt"], environment: [String: String]
    ) async throws -> M4HelperResult {
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
                        continuation.resume(returning: M4HelperResult(status: process.terminationStatus, output: output))
                    } catch {
                        continuation.resume(throwing: M4CredentialFailure(description: "Could not execute the credential verification helper"))
                    }
                }
            }
        }
    }
}

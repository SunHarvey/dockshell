import CryptoKit
import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M4HostTrustFailure: Error, CustomStringConvertible {
    let description: String
}

/// Exercises a temporary trust database only; no real server or user's SSH files are consulted.
enum M4HostTrustVerification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M4HostTrustFailure(description: message) }
    }

    private static func expecting(
        _ expected: HostTrustError, _ operation: () async throws -> Void
    ) async throws {
        do { try await operation() }
        catch let actual as HostTrustError {
            try check(actual == expected, "Unexpected host trust error: \(actual)")
            return
        }
        throw M4HostTrustFailure(description: "Expected host trust error was not raised: \(expected)")
    }

    static func run() async throws {
        let canonical = try SSHHostEndpoint(host: "EXAMPLE.COM.", port: 22)
        try check(canonical.host == "example.com" && canonical.knownHostsName == "example.com",
                  "DNS known_hosts canonicalization failed")
        let ipv6 = try SSHHostEndpoint(host: "[0:0:0:0:0:0:0:1]", port: 2222)
        try check(ipv6.host == "::1" && ipv6.knownHostsName == "[::1]:2222", "IPv6 endpoint canonicalization failed")
        for host in ["-oProxyCommand=evil", "host,other", "host\nother", "[host]:22", "h*st", "a..b", "a/b", "::bad::", "localhost%en0"] {
            try await expecting(.invalidEndpoint) { _ = try SSHHostEndpoint(host: host, port: 22) }
        }
        try await expecting(.invalidEndpoint) { _ = try SSHHostEndpoint(host: "localhost", port: 0) }

        // These are public-key test fixtures. The ephemeral signing key never leaves memory.
        let keyA = try makeEd25519()
        let keyB = try makeEd25519()
        let ecdsa = P256.Signing.PrivateKey().publicKey.x963Representation
        let ecdsaBlob = wire(Data("ecdsa-sha2-nistp256".utf8)) + wire(Data("nistp256".utf8)) + wire(ecdsa)
        let keyC = try SSHHostKey(algorithm: "ecdsa-sha2-nistp256", publicKey: ecdsaBlob)
        try check(keyA.sha256Fingerprint.hasPrefix("SHA256:") && !keyA.sha256Fingerprint.contains("="),
                  "Fingerprints must use unpadded SHA-256 base64")
        try check(keyA.hostKeyAlgorithms == ["ssh-ed25519"], "Unexpected host-key negotiation algorithm")
        try await expecting(.invalidKey) { _ = try SSHHostKey(algorithm: "ssh-rsa", publicKey: keyA.publicKey) }
        try await expecting(.invalidKey) { _ = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: keyA.publicKey + Data([0])) }
        try await expecting(.invalidKey) { _ = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: Data([255, 255, 255, 255])) }
        try await expecting(.invalidKey) {
            let short = wire(Data("ssh-ed25519".utf8)) + wire(Data(repeating: 1, count: 31))
            _ = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: short)
        }
        try await expecting(.invalidKey) {
            let invalid = wire(Data("ecdsa-sha2-nistp256".utf8)) + wire(Data("nistp256".utf8)) + wire(Data(repeating: 0, count: 65))
            _ = try SSHHostKey(algorithm: "ecdsa-sha2-nistp256", publicKey: invalid)
        }

        try check(try HostTrustAssessment.assess(known: [], offered: [keyA]) == .unknown([keyA]),
                  "Discovery must remain untrusted until explicit approval")
        try check(try HostTrustAssessment.assess(known: [keyA], offered: [keyA, keyB]) == .trusted([keyA]),
                  "An additional untrusted key was accepted")
        try check(try HostTrustAssessment.assess(known: [keyA], offered: [keyB]) == .changed(known: [keyA], offered: [keyB]),
                  "A changed host identity was not detected")
        try await expecting(.scanFailed) { _ = try HostTrustAssessment.assess(known: [keyA], offered: []) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m4-trust-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("known_hosts")
        let store = OpenSSHHostKeyStore(url: url)
        try check(try await store.knownKeys(for: canonical).isEmpty, "A fresh endpoint was already trusted")
        try check(!FileManager.default.fileExists(atPath: url.path), "Reading candidate trust wrote known_hosts prematurely")
        _ = try await store.knownHostsFileURL()
        try await store.approve([keyC, keyA], for: canonical)
        let known = try await OpenSSHHostKeyStore(url: url).knownKeys(for: canonical)
        try check(known == [keyA, keyC], "Approved full keys did not persist in deterministic preference order")
        let before = try Data(contentsOf: url)
        try await store.approve([keyA, keyC], for: canonical)
        try check(try Data(contentsOf: url) == before, "Idempotent approval rewrote the trust file")
        try await expecting(.hostKeyChanged) { try await store.approve([keyB], for: canonical) }
        try check(try Data(contentsOf: url) == before, "A changed key overwrote the previous trust anchor")
        let otherPort = try SSHHostEndpoint(host: "example.com", port: 2222)
        try check(try await store.knownKeys(for: otherPort).isEmpty, "Different ports shared host trust")
        try await store.approve([keyB], for: otherPort)
        try await store.approve([keyB], for: ipv6)
        let reloaded = OpenSSHHostKeyStore(url: url)
        try check(try await reloaded.knownKeys(for: canonical) == known, "Adding another endpoint changed previous trust")
        try check(try await reloaded.knownKeys(for: otherPort) == [keyB], "Port-specific trust was not reloaded")
        try check(try await reloaded.knownKeys(for: ipv6) == [keyB], "IPv6 trust was not reloaded")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "known_hosts permissions must be 0600")

        let lock = open(url.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
        guard lock >= 0 else { throw M4HostTrustFailure(description: "Unable to open the isolated trust lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw M4HostTrustFailure(description: "Unable to acquire the isolated trust lock")
        }
        do {
            try await expecting(.storageUnavailable) { _ = try await reloaded.knownKeys(for: canonical) }
        } catch {
            flock(lock, LOCK_UN)
            close(lock)
            throw error
        }
        flock(lock, LOCK_UN)
        close(lock)

        let valid = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try await expecting(.storageUnavailable) { _ = try await reloaded.knownKeys(for: canonical) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        // The parser refuses corrupt or future-format records, preserving the original bytes on approval.
        for bad in ["# DockShell known_hosts v2\n", "# DockShell known_hosts v1\nexample.com ssh-ed25519 not-base64\n"] {
            let bytes = Data(bad.utf8)
            try bytes.write(to: url)
            try await expecting(.storageCorrupt) { _ = try await reloaded.knownKeys(for: canonical) }
            try await expecting(.storageCorrupt) { try await reloaded.approve([keyA], for: canonical) }
            try check(try Data(contentsOf: url) == bytes, "A malformed trust file was silently overwritten")
        }

        try FileManager.default.removeItem(at: url)
        let sentinel = directory.appendingPathComponent("unrelated-file")
        let sentinelBytes = Data("Unrelated file must remain untouched".utf8)
        try sentinelBytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sentinel)
        try await expecting(.storageUnavailable) { _ = try await reloaded.knownKeys(for: canonical) }
        try await expecting(.storageUnavailable) { try await reloaded.approve([keyA], for: canonical) }
        try check(try Data(contentsOf: sentinel) == sentinelBytes, "A trust-file symlink changed an unrelated file")
        try FileManager.default.removeItem(at: url)
        try valid.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        // An already-cancelled scan never creates a worker subprocess.
        let cancelled = Task { () throws -> [SSHHostKey] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenSSHHostKeyScanner().scan(canonical)
        }
        do {
            _ = try await cancelled.value
            throw M4HostTrustFailure(description: "A cancelled host-key scan unexpectedly completed")
        } catch is CancellationError {}

        print("PASS M4 host trust: endpoint/key validation, explicit approval, full-key persistence, port isolation, mismatch/corrupt/symlink preservation, permissions/lock, cancellation")
    }

    private static func makeEd25519() throws -> SSHHostKey {
        let bytes = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return try SSHHostKey(algorithm: "ssh-ed25519", publicKey: wire(Data("ssh-ed25519".utf8)) + wire(bytes))
    }

    private static func wire(_ bytes: Data) -> Data {
        let count = UInt32(bytes.count)
        return Data([UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                     UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]) + bytes
    }
}

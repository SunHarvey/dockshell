import CDockShellPTY
import Darwin
import Foundation

/// Sanitized failures. Neither credentials nor an SSH prompt are associated with an error.
public enum OpenSSHCredentialBrokerError: Error, Equatable, Sendable {
    /// The system askpass protocol cannot represent empty, multiline, NUL or >1023-byte secrets.
    case invalidSecret
    case unavailable
    case authenticationNotConfirmed
}

/// One SSH process's optional secret rendezvous and authenticated LocalCommand notification.
///
/// Only the nonce and socket path enter the child environment. The memory-only password
/// is released once to a helper whose signature, UID, executable path, parent PID and
/// parent birth time match this connection. A separate READY confirms authentication.
public actor OpenSSHCredentialBroker {
    /// Non-secret child environment, safe to pass without exposing a credential.
    public nonisolated let environment: [String: String]
    private let handle: UInt
    private var result: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    private struct Prepared: Sendable {
        let handle: UInt
        let environment: [String: String]
    }

    /// Creates socket files on a dedicated thread; no filesystem work runs on the UI actor.
    /// A nil secret permits only READY, for an unencrypted private key or ssh-agent.
    /// Empty Data is an invalid secret, not a request to enable an empty askpass reply.
    public static func prepare(
        secret: Data?, helperURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> OpenSSHCredentialBroker {
        if let secret {
            guard !secret.isEmpty, secret.count <= 1023,
                  !secret.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
                throw OpenSSHCredentialBrokerError.invalidSecret
            }
        }
        guard helperURL.isFileURL, temporaryDirectory.isFileURL else {
            throw OpenSSHCredentialBrokerError.unavailable
        }
        let token = UUID().uuidString
        let prepared: Prepared = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    var pointer: OpaquePointer?
                    let error: Int32
                    if let secret {
                        error = secret.withUnsafeBytes { bytes in
                            ds_credential_create(temporaryDirectory.path, helperURL.path, token,
                                                 bytes.baseAddress, bytes.count, &pointer)
                        }
                    } else {
                        error = ds_credential_create(temporaryDirectory.path, helperURL.path, token,
                                                     nil, 0, &pointer)
                    }
                    guard error == 0, let pointer else {
                        continuation.resume(throwing: OpenSSHCredentialBrokerError.unavailable)
                        return
                    }
                    let path = String(cString: ds_credential_socket_path(pointer))
                    continuation.resume(returning: Prepared(
                        handle: UInt(bitPattern: pointer), environment: [
                            "DOCKSHELL_ASKPASS_SOCKET": path,
                            "DOCKSHELL_ASKPASS_TOKEN": token,
                            "SSH_ASKPASS": helperURL.path,
                            "SSH_ASKPASS_REQUIRE": "force",
                        ]))
                }
            }
        }
        if Task.isCancelled {
            let pointer = OpaquePointer(bitPattern: prepared.handle)!
            ds_credential_release(pointer)
            throw CancellationError()
        }
        return OpenSSHCredentialBroker(prepared: prepared)
    }

    private init(prepared: Prepared) {
        environment = prepared.environment
        handle = prepared.handle
        // C owns the mutable state and synchronizes it with a mutex. The integer handle
        // crosses the Thread boundary with an explicit retained C reference; Swift never
        // transfers an unsynchronized mutable object or an actor-owned pointer.
        let retainedHandle = prepared.handle
        ds_credential_retain(OpaquePointer(bitPattern: retainedHandle)!)
        Thread.detachNewThread { [weak self] in
            let pointer = OpaquePointer(bitPattern: retainedHandle)!
            let code = ds_credential_serve(pointer)
            ds_credential_retire(pointer)
            ds_credential_release(pointer)
            Task { await self?.finished(code: code) }
        }
    }

    /// Must receive the PID returned by the app's own posix_spawn, never a discovered PID.
    public func bindSSHProcess(_ pid: Int32) throws {
        guard ds_credential_bind_ssh(pointer, pid) == 0 else {
            throw OpenSSHCredentialBrokerError.unavailable
        }
    }

    /// Suspends without polling until the fixed LocalCommand helper reports successful auth.
    /// Canceling this wait also cancels the connection's credential rendezvous.
    public func waitUntilAuthenticated() async throws {
        let code = await withTaskCancellationHandler {
            await completion()
        } onCancel: {
            Task { await self.cancel() }
        }
        try Task.checkCancellation()
        guard code == 0, ds_credential_is_ready(pointer) != 0 else {
            if code == ECANCELED { throw CancellationError() }
            throw OpenSSHCredentialBrokerError.authenticationNotConfirmed
        }
    }

    public func wasDelivered() -> Bool { ds_credential_was_delivered(pointer) != 0 }

    /// An authenticated READY remains observable even if the short remote command has already exited.
    public func wasAuthenticated() -> Bool { ds_credential_is_ready(pointer) != 0 }

    /// Wakes both accept and partial-request waits, then waits for the dedicated worker to exit.
    public func close() async {
        cancel()
        _ = await completion()
    }

    private var pointer: OpaquePointer { OpaquePointer(bitPattern: handle)! }

    private func cancel() { ds_credential_cancel(pointer) }

    private func completion() async -> Int32 {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finished(code: Int32) {
        result = code
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(returning: code) }
    }

    deinit {
        let pointer = OpaquePointer(bitPattern: handle)!
        ds_credential_cancel(pointer)
        ds_credential_release(pointer)
    }
}

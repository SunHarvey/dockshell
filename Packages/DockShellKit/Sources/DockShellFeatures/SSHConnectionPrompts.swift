import Combine
import DockShellDomain
import Foundation

public struct SSHPasswordRequest: Identifiable, Sendable {
    public let id: UUID
    public let profile: SessionProfile
}

/// Presents one connection's user decisions. Continuations are resumed exactly once, including cancellation.
@MainActor
public final class SSHConnectionPrompts: ObservableObject, SSHInteraction {
    @Published public private(set) var hostRequest: SSHHostTrustRequest?
    @Published public private(set) var passwordRequest: SSHPasswordRequest?
    private var hostContinuation: CheckedContinuation<Bool, any Error>?
    private var passwordContinuation: CheckedContinuation<Data, any Error>?

    public init() {}

    public func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard hostContinuation == nil, passwordContinuation == nil else {
                    continuation.resume(throwing: SSHConnectionError.connectionFailed); return
                }
                hostContinuation = continuation
                hostRequest = request
                if Task.isCancelled { cancelHost(id: request.id) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelHost(id: request.id) }
        }
    }

    public func password(for profile: SessionProfile) async throws -> Data {
        try await secret(for: profile)
    }

    public func passphrase(for profile: SessionProfile) async throws -> Data {
        try await secret(for: profile)
    }

    private func secret(for profile: SessionProfile) async throws -> Data {
        try Task.checkCancellation()
        let request = SSHPasswordRequest(id: UUID(), profile: profile)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard hostContinuation == nil, passwordContinuation == nil else {
                    continuation.resume(throwing: SSHConnectionError.connectionFailed); return
                }
                passwordContinuation = continuation
                passwordRequest = request
                if Task.isCancelled { cancelPassword(id: request.id) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPassword(id: request.id) }
        }
    }

    public func answerHost(id: UUID, trust: Bool) {
        guard hostRequest?.id == id, let continuation = hostContinuation else { return }
        hostContinuation = nil; hostRequest = nil
        continuation.resume(returning: trust)
    }

    public func answerPassword(id: UUID, bytes: Data) {
        guard passwordRequest?.id == id, let continuation = passwordContinuation else { return }
        passwordContinuation = nil; passwordRequest = nil
        continuation.resume(returning: bytes)
    }

    public func cancelAll() {
        if let id = hostRequest?.id { cancelHost(id: id) }
        if let id = passwordRequest?.id { cancelPassword(id: id) }
    }

    private func cancelHost(id: UUID) {
        guard hostRequest?.id == id else { return }
        let continuation = hostContinuation
        hostContinuation = nil; hostRequest = nil
        continuation?.resume(throwing: CancellationError())
    }

    public func cancelPassword(id: UUID) {
        guard passwordRequest?.id == id else { return }
        let continuation = passwordContinuation
        passwordContinuation = nil; passwordRequest = nil
        continuation?.resume(throwing: CancellationError())
    }
}

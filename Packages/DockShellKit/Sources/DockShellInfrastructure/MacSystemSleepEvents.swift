import AppKit
import DockShellDomain
import Foundation
import os

/// Converts workspace power notifications to values without timers or a main-thread IO operation.
public struct MacSystemSleepEvents: SystemSleepEventSource {
    public init() {}

    public func events() async -> AsyncStream<SystemSleepEvent> {
        await Self.stream(center: NSWorkspace.shared.notificationCenter)
    }

    /// A separate notification center makes registration and cancellation verifiable without sleeping the Mac.
    @MainActor
    public static func stream(center: NotificationCenter) -> AsyncStream<SystemSleepEvent> {
        let pair = AsyncStream<SystemSleepEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let observations = SleepNotificationObservations(center: center)
        pair.continuation.onTermination = { _ in observations.cancel() }
        observations.register(name: NSWorkspace.willSleepNotification) { pair.continuation.yield(.willSleep) }
        observations.register(name: NSWorkspace.didWakeNotification) { pair.continuation.yield(.didWake) }
        return pair.stream
    }
}

/// NotificationCenter's opaque observer handles stay behind this lock. Its removal API is thread-safe.
/// No unsafe Swift object crosses an actor boundary; only immutable events and the stream continuation do.
private final class SleepNotificationObservations: Sendable {
    private struct State {
        var cancelled = false
        var tokens: [any NSObjectProtocol] = []
    }
    private let center: NotificationCenter
    // Tokens have no Sendable conformance; access is exclusively serialized and never escapes the lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(center: NotificationCenter) { self.center = center }

    func register(name: Notification.Name, action: @escaping @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in action() }
        state.withLockUnchecked { state in
            if state.cancelled { center.removeObserver(token) }
            else { state.tokens.append(token) }
        }
    }

    func cancel() {
        state.withLockUnchecked { state in
            guard !state.cancelled else { return }
            state.cancelled = true
            for token in state.tokens { center.removeObserver(token) }
            state.tokens.removeAll()
        }
    }

    deinit { cancel() }
}

import Foundation

/// System power transitions are independent of any SSH backend or AppKit notification type.
public enum SystemSleepEvent: Sendable, Equatable {
    case willSleep
    case didWake
}

/// A wake event does not prove that a retained TCP/SSH connection is still usable.
public enum ConnectionRecoveryNotice: Sendable, Equatable {
    case checkingAfterWake
}

/// Supplies system power events until its consuming task is cancelled.
/// A bounded newest-event buffer is sufficient: a wake event also identifies an interrupted interval.
public protocol SystemSleepEventSource: Sendable {
    func events() async -> AsyncStream<SystemSleepEvent>
}

import DockShellDomain
import Foundation

/// Captures the workspace's existing targets. No transport is created or reconnected.
@MainActor
public struct BatchCommandRecipient {
    public let id: UUID
    public let name: String
    public let ordinal: Int
    public let authenticationPending: Bool
    public let input: any BatchCommandTarget
    public init(id: UUID, name: String, ordinal: Int, authenticationPending: Bool, input: any BatchCommandTarget) {
        self.id = id; self.name = name; self.ordinal = ordinal
        self.authenticationPending = authenticationPending; self.input = input
    }
}

/// Synchronously admits one identical payload to each target's own ordered queue.
/// UI changes cannot alter the recipient set halfway through a submission.
@MainActor
public struct BatchCommandDispatcher {
    public init() {}
    public func send(_ command: BatchCommand, to recipients: [BatchCommandRecipient]) -> BatchCommandReport {
        let outcomes = recipients.map { recipient in
            let delivery: BatchCommandDelivery
            if recipient.authenticationPending { delivery = .skippedAuthentication }
            else {
                switch recipient.input.enqueueBatchCommand(command) {
                case .queued: delivery = .queued
                case .notConnected: delivery = .skippedNotConnected
                case .queueFull: delivery = .queueFull
                }
            }
            return BatchCommandOutcome(id: recipient.id, name: recipient.name, ordinal: recipient.ordinal, delivery: delivery)
        }
        return BatchCommandReport(outcomes: outcomes)
    }
}

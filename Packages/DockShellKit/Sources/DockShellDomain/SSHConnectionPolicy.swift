import Foundation

/// Protocol-level heartbeats, independent of TCP keepalive and terminal activity.
/// Standard settings bound silent network failures without a UI polling timer.
public struct SSHKeepalivePolicy: Equatable, Sendable {
    public let intervalSeconds: Int
    public let unansweredLimit: Int
    public static let standard = SSHKeepalivePolicy(interval: 15, limit: 3)

    public init(intervalSeconds: Int, unansweredLimit: Int) throws {
        guard (1...300).contains(intervalSeconds), (1...10).contains(unansweredLimit) else {
            throw SSHConnectionError.invalidConfiguration
        }
        self.intervalSeconds = intervalSeconds; self.unansweredLimit = unansweredLimit
    }

    private init(interval: Int, limit: Int) {
        intervalSeconds = interval; unansweredLimit = limit
    }
}

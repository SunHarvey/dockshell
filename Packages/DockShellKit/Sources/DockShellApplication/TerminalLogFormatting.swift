import DockShellDomain
import Foundation

/// Formats display events only. Authentication material and raw keyboard input have no entry point.
public struct TerminalLogFormatting: Sendable {
    public let labels: TerminalLogLabels
    public init(labels: TerminalLogLabels) { self.labels = labels }

    public func marker(_ text: String, at date: Date = Date()) -> Data {
        Data(("[DockShell " + date.ISO8601Format() + "] " + text + "\n").utf8)
    }

    public func encode(_ events: [TerminalLogEvent]) -> Data {
        var result = Data()
        for event in events {
            switch event {
            case let .text(bytes): result.append(bytes)
            case let .alternateScreen(entered, date):
                result.append(marker(entered ? labels.alternateEntered : labels.alternateExited, at: date))
            case .omittedPartialLine: result.append(marker(labels.omittedPartial))
            case .truncatedLongLine: result.append(marker(labels.truncatedLine))
            case .discontinuity: result.append(marker(labels.incomplete))
            }
        }
        return result
    }
}

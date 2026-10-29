import DockShellDomain
import Foundation

/// Pulls one bounded chunk, awaits rendering, then requests the next one.
/// Main-actor work is limited to small parser feeds; upstream backpressure remains intact.
public actor TerminalIOPump {
    public init() {}

    public func run(channel: any TerminalByteChannel,
                    render: @escaping @MainActor @Sendable (Data) -> Void) async throws -> UInt64 {
        var total: UInt64 = 0
        while let bytes = try await channel.read(maxBytes: 4_096) {
            try Task.checkCancellation()
            await render(bytes)
            total += UInt64(bytes.count)
            await Task.yield()
        }
        return total
    }
}

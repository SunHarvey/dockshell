@preconcurrency import Citadel

/// A negative compilation fixture: macOS 14 cannot call the original public PTY API unguarded.
/// This target must fail with “withPTY ... is only available in macOS 15.0 or newer”.
@main
enum MacOS14AvailabilityFailure {
    static func main() {}

    static func exercise(_ client: SSHClient) async throws {
        try await client.withPTY(.init(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )) { _, outbound in
            try await outbound.changeSize(cols: 120, rows: 40, pixelWidth: 0, pixelHeight: 0)
        }
    }
}

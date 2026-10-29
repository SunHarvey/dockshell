import Foundation

/// All visible prose is supplied by the application's String Catalog.
public struct TerminalDemoContent: Sendable {
    public let title: String
    public let explanation: String
    public let colors: String
    public let unicode: String
    public let sample: String
    public let prompt: String
    public let stress: String

    public init(title: String, explanation: String, colors: String, unicode: String,
                sample: String, prompt: String, stress: String) {
        self.title = title; self.explanation = explanation; self.colors = colors
        self.unicode = unicode; self.sample = sample; self.prompt = prompt; self.stress = stress
    }
}

/// Generates small chunks on an actor and awaits every write; never constructs a large file in RAM.
public actor OfflineTerminalDemo {
    public init() {}

    public func produce(into channel: BoundedTerminalChannel, content: TerminalDemoContent,
                        stress: Bool = false) async throws {
        try await channel.write(Data((content.title + "\r\n" + content.explanation + "\r\n\r\n").utf8))
        if stress {
            var chunk = Data()
            for line in 1...20_000 {
                try Task.checkCancellation()
                chunk.append(contentsOf: (String(line) + "  " + content.stress + "\r\n").utf8)
                if chunk.count >= 12_288 {
                    try await channel.write(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try await channel.write(chunk) }
        } else {
            try await channel.write(Data((content.colors + "\r\n").utf8))
            for row in 0..<16 {
                var line = ""
                for column in 0..<16 {
                    let index = row * 16 + column
                    line += "\u{1b}[48;5;\(index)m\u{1b}[38;5;\(index < 8 ? 15 : 0)m "
                        + String(format: "%02X", index) + "\u{1b}[0m"
                }
                try await channel.write(Data((line + "\r\n").utf8))
            }
            var gradient = ""
            for step in 0..<48 {
                gradient += "\u{1b}[48;2;\(step * 5);\(210 - step * 3);\(240 - step * 2)m \u{1b}[0m"
            }
            try await channel.write(Data((gradient + "\r\n\r\n" + content.unicode + "\r\n").utf8))
            // Deliberately split UTF-8 scalar boundaries; the parser must retain its decoder state.
            let bytes = Array((content.sample + "\r\n").utf8)
            for offset in stride(from: 0, to: bytes.count, by: 3) {
                try await channel.write(Data(bytes[offset..<min(offset + 3, bytes.count)]))
            }
        }
        try await channel.write(Data(("\r\n" + content.prompt).utf8))
        // Keep the channel open for local echo. With no input, the reader sleeps on a continuation.
    }
}

/// Local echo is not a shell. CR gets a display newline; all UTF-8 bytes remain unchanged.
public actor OfflineTerminalEcho {
    public init() {}
    public func echo(_ bytes: Data, into channel: BoundedTerminalChannel) async throws {
        var chunk = Data()
        for byte in bytes {
            chunk.append(byte)
            if byte == 13 { chunk.append(10) }
            if chunk.count >= 4_096 {
                try await channel.write(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await channel.write(chunk) }
    }
}

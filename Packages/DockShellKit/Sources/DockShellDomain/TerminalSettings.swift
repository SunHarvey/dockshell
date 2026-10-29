import Foundation

/// Original DockShell color schemes. Concrete renderer colors stay in the terminal UI adapter.
public enum TerminalTheme: String, CaseIterable, Codable, Sendable {
    case graphite
    case ocean
    case paper
}

/// Structured settings failures contain no filesystem paths or persisted record contents.
public enum TerminalSettingsError: Error, Equatable, Sendable {
    case invalidFont
    case invalidFontSize
    case invalidScrollback
    case storageUnavailable
    case unsupportedVersion
}

/// Non-secret terminal preferences, independent of AppKit, SwiftTerm, and persistence.
public struct TerminalSettings: Equatable, Codable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 8...40
    public static let scrollbackRange: ClosedRange<Int> = 1_000...100_000
    public static let defaults = TerminalSettings()

    public var fontName: String
    public var fontSize: Double
    public var scrollbackLines: Int
    public var theme: TerminalTheme

    public init(
        fontName: String = "Menlo",
        fontSize: Double = 14,
        scrollbackLines: Int = 10_000,
        theme: TerminalTheme = .graphite
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.theme = theme
    }

    /// Validates stored and edited values; font availability is checked by the AppKit adapter.
    /// The finite scrollback bound limits retained lines, not the bytes delivered to the parser.
    public func validated() throws -> TerminalSettings {
        let normalizedName = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the scalar receiver explicit; a bound CharacterSet method regresses under Swift 6.4 -O.
        guard !normalizedName.isEmpty,
              !normalizedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TerminalSettingsError.invalidFont
        }
        guard fontSize.isFinite, Self.fontSizeRange.contains(fontSize) else {
            throw TerminalSettingsError.invalidFontSize
        }
        guard Self.scrollbackRange.contains(scrollbackLines) else {
            throw TerminalSettingsError.invalidScrollback
        }
        return TerminalSettings(fontName: normalizedName, fontSize: fontSize,
                                scrollbackLines: scrollbackLines, theme: theme)
    }
}

/// Stores non-secret preferences. Implementations must validate records before returning them.
public protocol SettingsRepository: Sendable {
    func load() async throws -> TerminalSettings
    func save(_ settings: TerminalSettings) async throws
}

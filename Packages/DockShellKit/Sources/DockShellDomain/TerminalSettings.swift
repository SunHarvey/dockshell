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
    case invalidLogLimit
    case storageUnavailable
    case unsupportedVersion
}

/// Non-secret terminal preferences, independent of AppKit, SwiftTerm, and persistence.
public struct TerminalSettings: Equatable, Codable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 8...40
    public static let scrollbackRange: ClosedRange<Int> = 1_000...100_000
    public static let defaults = TerminalSettings()
    public static let logLimitRange = 1...100

    public var fontName: String
    public var fontSize: Double
    public var scrollbackLines: Int
    public var theme: TerminalTheme
    public var logEnabled: Bool
    public var logLimitMB: Int
    public var logLimitBytes: Int { min(max(logLimitMB, 1), 100) * 1_000_000 }

    public init(
        fontName: String = "Menlo",
        fontSize: Double = 14,
        scrollbackLines: Int = 10_000,
        theme: TerminalTheme = .graphite,
        logEnabled: Bool = true,
        logLimitMB: Int = 5
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.theme = theme
        self.logEnabled = logEnabled
        self.logLimitMB = logLimitMB
    }

    private enum CodingKeys: String, CodingKey { case fontName, fontSize, scrollbackLines, theme, logEnabled, logLimitMB }

    /// Version-one records predate logging. Preserve their existing appearance settings.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decode(String.self, forKey: .fontName)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        scrollbackLines = try values.decode(Int.self, forKey: .scrollbackLines)
        theme = try values.decode(TerminalTheme.self, forKey: .theme)
        logEnabled = try values.decodeIfPresent(Bool.self, forKey: .logEnabled) ?? true
        logLimitMB = try values.decodeIfPresent(Int.self, forKey: .logLimitMB) ?? 5
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
        guard Self.logLimitRange.contains(logLimitMB) else { throw TerminalSettingsError.invalidLogLimit }
        return TerminalSettings(fontName: normalizedName, fontSize: fontSize,
                                scrollbackLines: scrollbackLines, theme: theme,
                                logEnabled: logEnabled, logLimitMB: logLimitMB)
    }
}

/// Stores non-secret preferences. Implementations must validate records before returning them.
public protocol SettingsRepository: Sendable {
    func load() async throws -> TerminalSettings
    func save(_ settings: TerminalSettings) async throws
}

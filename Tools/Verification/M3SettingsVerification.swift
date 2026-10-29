import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M3SettingsFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses an isolated preference domain; it never reads or changes the app's actual settings.
enum M3SettingsVerification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M3SettingsFailure(description: message) }
    }

    private static func expecting(
        _ expected: TerminalSettingsError,
        _ operation: () async throws -> Void
    ) async throws {
        do { try await operation() }
        catch let error as TerminalSettingsError {
            try check(error == expected, "Unexpected settings error: \(error)")
            return
        }
        throw M3SettingsFailure(description: "Expected settings failure was not raised: \(expected)")
    }

    static func run() async throws {
        let suiteName = "dev.dockshell.verification.settings.\(UUID())"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            throw M3SettingsFailure(description: "Unable to create the isolated settings suite")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let repository = UserDefaultsSettingsRepository(suiteName: suiteName)
        let initial = try await repository.load()
        try check(initial == .defaults && initial.scrollbackLines == 10_000,
                  "Missing preferences did not use the approved defaults")

        let edited = TerminalSettings(fontName: "  Menlo  ", fontSize: 17,
                                      scrollbackLines: 20_000, theme: .ocean)
        let expected = TerminalSettings(fontName: "Menlo", fontSize: 17,
                                        scrollbackLines: 20_000, theme: .ocean)
        try check(try edited.validated() == expected, "Font-name normalization changed unrelated settings")
        try await repository.save(edited)
        let reopened = UserDefaultsSettingsRepository(suiteName: suiteName)
        try check(try await reopened.load() == expected, "An independent repository failed to reload settings")

        for size in [7.0, 41.0, Double.nan, Double.infinity] {
            let invalid = TerminalSettings(fontSize: size)
            try await expecting(.invalidFontSize) { try await repository.save(invalid) }
        }
        for lines in [999, 100_001] {
            let invalid = TerminalSettings(scrollbackLines: lines)
            try await expecting(.invalidScrollback) { try await repository.save(invalid) }
        }
        try await expecting(.invalidFont) {
            try await repository.save(TerminalSettings(fontName: " \n\t "))
        }
        try check(try await repository.load() == expected, "Rejected edits changed previously saved preferences")

        // Inject raw data only into this random domain to verify preservation on downgrade/corruption.
        let key = "dev.dockshell.terminalSettings"
        let future = Data(#"{"version":2,"settings":{"futureLayout":true}}"#.utf8)
        preferences.set(future, forKey: key)
        try await expecting(.unsupportedVersion) { _ = try await repository.load() }
        try await expecting(.unsupportedVersion) { try await repository.save(.defaults) }
        try check(preferences.data(forKey: key) == future, "A future-version record was overwritten")

        let malformed = Data("not a settings JSON record".utf8)
        preferences.set(malformed, forKey: key)
        try await expecting(.storageUnavailable) { _ = try await repository.load() }
        try await expecting(.storageUnavailable) { try await repository.save(.defaults) }
        try check(preferences.data(forKey: key) == malformed, "A malformed record was silently replaced")

        print("PASS M3 settings: defaults/normalization, isolated reload, bounds/NaN, future/corrupt record preservation")
    }
}

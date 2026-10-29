import DockShellDomain
import Foundation

/// Actor-confined preferences IO. A single versioned Data value avoids partially updated fields.
/// Missing preferences use defaults; malformed or unsupported records are reported to the caller.
public actor UserDefaultsSettingsRepository: SettingsRepository {
    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct Record: Codable {
        let version: Int
        let settings: TerminalSettings
    }

    private let suiteName: String?
    private let storageKey = "dev.dockshell.terminalSettings"
    private var cachedDefaults: UserDefaults?

    /// A separate suite isolates verification from the user's application preferences.
    /// UserDefaults is created lazily on this actor so construction performs no main-actor IO.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public func load() throws -> TerminalSettings {
        let defaults = try storage()
        guard let value = defaults.object(forKey: storageKey) else { return .defaults }
        guard let data = value as? Data else { throw TerminalSettingsError.storageUnavailable }
        return try decode(data)
    }

    public func save(_ settings: TerminalSettings) throws {
        let validated = try settings.validated()
        let defaults = try storage()
        // Never overwrite a record from a future schema version during a downgrade.
        if let current = defaults.object(forKey: storageKey) {
            guard let data = current as? Data else { throw TerminalSettingsError.storageUnavailable }
            _ = try decode(data)
        }
        let data: Data
        do { data = try JSONEncoder().encode(Record(version: 1, settings: validated)) }
        catch { throw TerminalSettingsError.storageUnavailable }
        defaults.set(data, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == data else {
            throw TerminalSettingsError.storageUnavailable
        }
        // UserDefaults persists asynchronously. Its API does not report disk-flush failures;
        // read-back verifies the domain value without claiming a synchronous durable commit.
    }

    private func decode(_ data: Data) throws -> TerminalSettings {
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(VersionHeader.self, from: data)
            guard header.version == 1 else { throw TerminalSettingsError.unsupportedVersion }
            return try decoder.decode(Record.self, from: data).settings.validated()
        } catch let error as TerminalSettingsError {
            throw error
        } catch {
            throw TerminalSettingsError.storageUnavailable
        }
    }

    private func storage() throws -> UserDefaults {
        if let cachedDefaults { return cachedDefaults }
        let defaults: UserDefaults
        if let suiteName {
            guard !suiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let suite = UserDefaults(suiteName: suiteName) else {
                throw TerminalSettingsError.storageUnavailable
            }
            defaults = suite
        } else {
            defaults = .standard
        }
        cachedDefaults = defaults
        return defaults
    }
}

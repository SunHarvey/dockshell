import DockShellDomain

/// Owns settings validation without depending on AppKit, UserDefaults, or terminal libraries.
public actor SettingsService {
    private let repository: any SettingsRepository
    public init(repository: any SettingsRepository) { self.repository = repository }
    public func load() async throws -> TerminalSettings { try await repository.load() }
    public func save(_ settings: TerminalSettings) async throws {
        try await repository.save(settings.validated())
    }
}

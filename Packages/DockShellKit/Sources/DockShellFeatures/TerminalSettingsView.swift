import Combine
import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import SwiftUI

/// Preferences remain value types; AppKit validates availability before they reach a renderer.
@MainActor
public final class TerminalSettingsViewModel: ObservableObject {
    @Published public private(set) var settings = TerminalSettings.defaults
    @Published public private(set) var problem: TerminalSettingsError?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoaded = false
    private let service: SettingsService

    public init(service: SettingsService) { self.service = service }

    public func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false; isLoaded = true }
        do {
            let settings = try await service.load()
            try TerminalFonts.validate(settings)
            self.settings = settings
            problem = nil
        } catch {
            // Visible warning accompanies temporary defaults; the original record is not overwritten.
            problem = (error as? TerminalSettingsError) ?? .storageUnavailable
        }
    }

    public func save(_ settings: TerminalSettings) async throws {
        let validated = try settings.validated()
        try TerminalFonts.validate(validated)
        try await service.save(validated)
        self.settings = validated
        problem = nil
    }
}

/// Native preferences window shared by local and SSH terminals through its view model.
public struct TerminalSettingsView: View {
    @ObservedObject private var model: TerminalSettingsViewModel
    private let l10n: L10n
    @ViewState<TerminalSettings> private var draft = TerminalSettings.defaults
    @ViewState<String> private var history = "10000"
    @ViewState<L10nKey?> private var errorKey: L10nKey?
    @ViewState<Bool> private var isSaving = false
    @ViewState<Bool> private var saved = false

    public init(model: TerminalSettingsViewModel, l10n: L10n) { self.model = model; self.l10n = l10n }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: l10n.string(.settingsTitle)).font(.title2.weight(.semibold))
            Form {
                Picker(l10n.string(.settingsFont), selection: $draft.fontName) {
                    ForEach(fontNames, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                Stepper(value: $draft.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    HStack {
                        Text(verbatim: l10n.string(.settingsFontSize))
                        Spacer()
                        Text(draft.fontSize, format: .number)
                    }
                }
                Picker(l10n.string(.settingsTheme), selection: $draft.theme) {
                    ForEach(TerminalTheme.allCases, id: \.self) {
                        Text(verbatim: l10n.theme($0)).tag($0)
                    }
                }.pickerStyle(.segmented)
                TextField(l10n.string(.settingsScrollback), text: $history)
                Text(verbatim: l10n.string(.settingsScrollbackHelp))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped).disabled(model.isLoading || isSaving)
            if let key = errorKey ?? model.problem.map({ l10n.settingsErrorKey($0) }) {
                Text(verbatim: l10n.string(key)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if saved {
                Text(verbatim: l10n.string(.settingsSaved)).foregroundStyle(.secondary)
            }
            HStack {
                Button(l10n.string(.settingsDefaults)) { draft = .defaults; history = "10000"; saved = false }
                    .disabled(isSaving)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(l10n.string(.save)) {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do {
                            guard let count = Int(history) else { throw TerminalSettingsError.invalidScrollback }
                            draft.scrollbackLines = count
                            try await model.save(draft)
                            errorKey = nil
                            saved = true
                        } catch { errorKey = l10n.settingsErrorKey(error); saved = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(model.isLoading || isSaving)
            }
        }
        .padding(24).frame(width: 500)
        .task { await model.load(); draft = model.settings; history = String(model.settings.scrollbackLines) }
        .onChange(of: draft) { _, _ in saved = false }
        .onChange(of: history) { _, _ in saved = false }
        .onChange(of: model.settings) { _, value in draft = value; history = String(value.scrollbackLines) }
    }

    private var fontNames: [String] {
        // Retain a valid saved styled face even if a metadata query returns only regular faces.
        Array(Set(TerminalFonts.availableNames + [draft.fontName])).sorted()
    }
}

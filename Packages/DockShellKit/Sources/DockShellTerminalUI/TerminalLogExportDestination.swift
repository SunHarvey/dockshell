import AppKit
import DockShellDomain
import UniformTypeIdentifiers

/// The native destination picker is separate from capture/export so a save dialog
/// never holds up terminal output. Verification can choose a disposable path without
/// driving another process's file-panel buttons.
@MainActor
public protocol TerminalLogExportDestinationChoosing: AnyObject {
    func choose(proposedName: String, labels: TerminalLogMenuLabels, window: NSWindow) async throws -> URL?
    func cancel()
}

@MainActor
final class NativeTerminalLogExportDestination: TerminalLogExportDestinationChoosing {
    private var panel: NSSavePanel?
    func choose(proposedName: String, labels: TerminalLogMenuLabels, window: NSWindow) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = labels.title; panel.prompt = labels.save
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = proposedName
        self.panel = panel
        defer { self.panel = nil; panel.orderOut(nil) }
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if response == .cancel { return nil }
        guard response == .OK, let url = panel.url else { throw TerminalLogError.exportFailed }
        return url
    }
    func cancel() { panel?.cancel(nil) }
}

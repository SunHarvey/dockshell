import AppKit
import DockShellDomain
import SwiftUI

/// File panels capture both endpoints before asynchronous user selection. A
/// disappearing or closed browser invalidates the picker before its callback.
@MainActor
struct SFTPTransferSelectionControls: View {
    @ObservedObject var browser: SFTPBrowserViewModel
    @ObservedObject var transfers: SFTPTransfersViewModel
    @Binding var selection: Set<Data>
    let l10n: L10n
    @ViewState<NSOpenPanel?> private var picker: NSOpenPanel?
    @ViewState<UUID?> private var pickerID: UUID?
    @ViewState<SFTPTransferError?> private var selectionError: SFTPTransferError?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: chooseUpload) {
                Label(l10n.string(.transferUpload), systemImage: "arrow.up")
            }
            .help(l10n.string(.transferUploadPrompt))
            .accessibilityIdentifier("dockshell.sftp.upload")
            .disabled(!browser.canNavigate || browser.currentPath == nil || !transfers.acceptsNewJobs || picker != nil)
            Button(action: chooseDownload) {
                Label(l10n.string(.transferDownload), systemImage: "arrow.down")
            }
            .help(l10n.string(.transferFileOnly))
            .accessibilityIdentifier("dockshell.sftp.download")
            .disabled(!browser.canNavigate || !transfers.acceptsNewJobs || selectedFiles.isEmpty || selectedFiles.count != selection.count || picker != nil)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).controlSize(.small).buttonStyle(.bordered)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .alert(l10n.string(.operationErrorTitle), isPresented: Binding(
            get: { selectionError != nil }, set: { if !$0 { selectionError = nil } }
        )) {
            Button(l10n.string(.ok), role: .cancel) { selectionError = nil }
        } message: {
            if let selectionError { Text(verbatim: l10n.string(l10n.transferErrorKey(selectionError))) }
        }
        .onDisappear {
            pickerID = nil
            picker?.cancel(nil)
            picker = nil
        }
    }

    private var selectedFiles: [SFTPBrowserEntry] {
        browser.visibleEntries.filter { selection.contains($0.id) && $0.kind == .file }
    }

    private func chooseUpload() {
        guard picker == nil, browser.canNavigate, transfers.acceptsNewJobs, let profile = browser.profile,
              let directory = browser.currentPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = l10n.string(.transferUploadPrompt)
        panel.prompt = l10n.string(.transferUpload)
        present(panel) { urls in
            guard browser.phase != .idle, browser.profile == profile, transfers.acceptsNewJobs else { return }
            guard urls.count <= 100 else { selectionError = .queueLimit; return }
            do {
                let requests = try urls.map { url in
                    let name = url.lastPathComponent
                    guard Self.validComponent(name), url.isFileURL else { throw SFTPTransferError.invalidPath }
                    return SFTPTransferRequest(direction: .upload, localURL: url,
                                               remotePath: try directory.appending(name))
                }
                transfers.enqueue(requests, profile: profile)
            } catch { selectionError = .invalidPath }
        }
    }

    private func chooseDownload() {
        let files = selectedFiles
        guard picker == nil, browser.canNavigate, transfers.acceptsNewJobs, !files.isEmpty, files.count == selection.count,
              let profile = browser.profile, let directory = browser.currentPath else { return }
        guard files.count <= 100 else { selectionError = .queueLimit; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.message = l10n.string(.transferDownloadPrompt)
        panel.prompt = l10n.string(.transferDownload)
        present(panel) { urls in
            guard browser.phase != .idle, browser.profile == profile, transfers.acceptsNewJobs,
                  let localDirectory = urls.first else { return }
            do {
                let requests = try files.map { entry in
                    let localName = Self.downloadName(entry.nameBytes)
                    guard Self.validComponent(localName) else { throw SFTPTransferError.invalidPath }
                    return SFTPTransferRequest(direction: .download,
                        localURL: localDirectory.appendingPathComponent(localName),
                        remotePath: try directory.appending(bytes: entry.nameBytes))
                }
                transfers.enqueue(requests, profile: profile)
            } catch { selectionError = .invalidPath }
        }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping @MainActor ([URL]) -> Void) {
        let id = UUID()
        pickerID = id; picker = panel
        let reply: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard pickerID == id else { return }
            pickerID = nil; picker = nil
            if response == .OK { completion(panel.urls) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: reply) }
        else { panel.begin(completionHandler: reply) }
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0") && name.utf8.count <= 255
    }

    private static func downloadName(_ raw: Data) -> String {
        // A remote name never becomes a local path. Non-UTF-8/control bytes use
        // the same escaped one-line representation as the directory list.
        let display = SFTPBrowserText.display(raw)
        if validComponent(display) { return display }
        return "download-" + UUID().uuidString
    }
}

import DockShellDomain
import SwiftUI

/// A bounded per-tab transfer list. Decisions stay with their own transfer
/// connection and remain available after the surrounding file panel is hidden.
@MainActor
public struct SFTPTransfersPane: View {
    @ObservedObject private var model: SFTPTransfersViewModel
    @ObservedObject private var prompts: SSHConnectionPrompts
    private let l10n: L10n
    @ViewState<Bool> private var expanded = true

    public init(model: SFTPTransfersViewModel, l10n: L10n) {
        self.model = model; self.prompts = model.prompts; self.l10n = l10n
    }

    private var needsDecision: Bool {
        model.conflict != nil || prompts.hostRequest != nil || prompts.passwordRequest != nil
    }

    public var body: some View {
        if !model.jobs.isEmpty || model.enqueueError != nil {
            VStack(spacing: 0) {
                Divider()
                header
                if expanded || needsDecision {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let error = model.enqueueError {
                                HStack(alignment: .top) {
                                    Text(verbatim: l10n.string(l10n.transferErrorKey(error)))
                                        .font(.caption).foregroundStyle(.orange)
                                    Spacer(minLength: 0)
                                    Button { model.dismissEnqueueError() } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless).help(l10n.string(.ok)).accessibilityLabel(l10n.string(.ok))
                                }.padding(10)
                            }
                            if let request = prompts.hostRequest {
                                Text(verbatim: l10n.string(.transferAuthentication)).font(.caption).padding(.horizontal, 10)
                                HostTrustPrompt(request: request, prompts: prompts, l10n: l10n).id(request.id)
                            } else if let request = prompts.passwordRequest {
                                Text(verbatim: l10n.string(.transferAuthentication)).font(.caption).padding(.horizontal, 10)
                                ConnectionPasswordPrompt(request: request, prompts: prompts, l10n: l10n).id(request.id)
                            } else if let conflict = model.conflict {
                                TransferConflictForm(conflict: conflict, model: model, l10n: l10n).id(conflict.id)
                            }
                            ForEach(model.jobs) { job in
                                jobRow(job)
                                Divider().padding(.leading, 10)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 70, idealHeight: needsDecision ? 230 : 150, maxHeight: needsDecision ? 230 : 170)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityIdentifier("dockshell.sftp.transfers")
            .onChange(of: model.jobs.count) { old, new in if new > old { expanded = true } }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded || needsDecision ? "chevron.down" : "chevron.right")
                    Text(verbatim: l10n.string(.transferTitle))
                    Text(verbatim: String(model.jobs.count)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.borderless).disabled(needsDecision)
            .accessibilityLabel(l10n.string(.transferTitle))
            .accessibilityIdentifier("dockshell.sftp.transfers.disclosure")
            Spacer(minLength: 0)
            if model.isPaused && model.hasUnfinished {
                Button(l10n.string(.transferResume)) { model.resume() }
                    .disabled(model.isActive)
                    .accessibilityIdentifier("dockshell.sftp.transfers.resume")
            }
            if model.hasUnfinished {
                Button(l10n.string(.transferCancelAll)) { model.cancelAll() }
                    .accessibilityIdentifier("dockshell.sftp.transfers.cancel-all")
            }
            Button(l10n.string(.transferClear)) { model.clearFinished() }
                .accessibilityIdentifier("dockshell.sftp.transfers.clear")
        }
        .font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func jobRow(_ job: SFTPTransferJob) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: job.request.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text(verbatim: jobName(job)).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(jobName(job))
                Spacer(minLength: 0)
                if canCancel(job) {
                    Button { model.cancel(id: job.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help(l10n.string(.cancel)).accessibilityLabel(l10n.string(.cancel))
                        .disabled(job.phase == .cancelling)
                        .accessibilityIdentifier("dockshell.sftp.transfer.cancel." + job.id.uuidString)
                }
            }
            HStack {
                Text(verbatim: l10n.string(phaseKey(job)))
                Spacer(minLength: 0)
                if let value = job.progress {
                    Text(verbatim: formattedBytes(value.bytes) + " / " + formattedBytes(value.totalBytes)).monospacedDigit()
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if let value = job.progress, job.phase == .running || job.phase == .cancelling {
                ProgressView(value: value.totalBytes == 0 ? (value.stage == .transferring ? 0 : 1)
                    : min(1, Double(value.bytes) / Double(value.totalBytes)))
                    .controlSize(.small)
            }
            if let error = job.connectionError {
                Text(verbatim: l10n.string(l10n.sshErrorKey(error))).font(.caption).foregroundStyle(.orange)
            }
            if job.phase == .completed, let destination = job.resolvedDestination { locationText(destination) }
            if let failure = job.failure {
                if failure.reason != .cancelled {
                    Text(verbatim: l10n.string(l10n.transferErrorKey(failure.reason)))
                        .font(.caption).foregroundStyle(.orange)
                }
                if let destination = failure.uncertainDestination {
                    Text(verbatim: l10n.string(.transferUncertainHelp)).font(.caption).foregroundStyle(.orange)
                    locationText(destination)
                }
                if !failure.residues.isEmpty {
                    Text(verbatim: l10n.string(.transferResidueHelp)).font(.caption).foregroundStyle(.orange)
                    ForEach(Array(failure.residues.enumerated()), id: \.offset) { _, location in locationText(location) }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dockshell.sftp.transfer." + job.id.uuidString)
    }

    private func locationText(_ location: SFTPTransferLocation) -> some View {
        let prefix: L10nKey
        let bytes: Data
        switch location {
        case .local(let url): prefix = .transferLocal; bytes = Data(url.path.utf8)
        case .remote(let path): prefix = .transferRemote; bytes = path.bytes
        }
        return Text(verbatim: l10n.string(prefix) + ": " + SFTPBrowserText.display(bytes))
            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func jobName(_ job: SFTPTransferJob) -> String {
        switch job.request.direction {
        case .upload: SFTPBrowserText.display(Data(job.request.localURL.lastPathComponent.utf8))
        case .download: SFTPBrowserText.display(job.request.remotePath.bytes.split(separator: 47).last.map { Data($0) } ?? Data())
        }
    }

    private func canCancel(_ job: SFTPTransferJob) -> Bool {
        switch job.phase {
        case .queued, .connecting, .running, .waitingConflict, .cancelling: true
        case .completed, .skipped, .cancelled, .failed: false
        }
    }

    private func phaseKey(_ job: SFTPTransferJob) -> L10nKey {
        switch job.phase {
        case .queued: return .transferQueued
        case .connecting: return .sshConnecting
        case .waitingConflict: return .transferWaitingConflict
        case .cancelling: return .transferCancelling
        case .completed: return .transferCompleted
        case .skipped: return .transferSkipped
        case .cancelled: return .transferCancelled
        case .failed: return .transferFailed
        case .running:
            switch job.progress?.stage {
            case .committing: return .transferCommitting
            case .cleaning: return .transferCleaning
            case .transferring, nil: return .transferRunning
            }
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        let units: [L10nKey] = [.sftpUnitBytes, .sftpUnitKiB, .sftpUnitMiB, .sftpUnitGiB, .sftpUnitTiB, .sftpUnitPiB, .sftpUnitEiB]
        var value = Double(bytes), index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return value.formatted(.number.precision(.fractionLength(0...(index == 0 ? 0 : 1)))
            .locale(Locale(identifier: l10n.language))) + " " + l10n.string(units[index])
    }
}

@MainActor
private struct TransferConflictForm: View {
    let conflict: SFTPTransferConflict
    @ObservedObject var model: SFTPTransfersViewModel
    let l10n: L10n
    @ViewState<String> private var renamed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(l10n.string(.transferConflictTitle), systemImage: "doc.on.doc").font(.headline)
            Text(verbatim: SFTPBrowserText.display(conflict.destinationName)).font(.callout).textSelection(.enabled)
            Text(verbatim: l10n.string(conflict.canReplace ? .transferConflictHelp : .transferNoReplace))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if conflict.direction == .upload {
                Text(verbatim: l10n.string(.transferUploadPermissions))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField(l10n.string(.transferNewName), text: $renamed).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("dockshell.sftp.transfer.conflict.name")
                Button(l10n.string(.transferSaveAs)) { answer(.rename(renamed)) }.disabled(!validName)
                    .accessibilityIdentifier("dockshell.sftp.transfer.conflict.rename")
            }
            HStack {
                Button(l10n.string(.transferSkip)) { answer(.skip) }
                    .accessibilityIdentifier("dockshell.sftp.transfer.conflict.skip")
                Spacer()
                if conflict.canReplace {
                    Button(l10n.string(.transferReplace), role: .destructive) { answer(.replace) }
                        .accessibilityIdentifier("dockshell.sftp.transfer.conflict.replace")
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06))
        .accessibilityIdentifier("dockshell.sftp.transfer.conflict")
    }

    private var validName: Bool {
        !renamed.isEmpty && renamed != "." && renamed != ".." && !renamed.contains("/")
            && !renamed.contains("\0") && renamed.utf8.count <= 255
    }
    private func answer(_ decision: SFTPTransferDecision) { model.answerConflict(id: conflict.id, decision: decision) }
}

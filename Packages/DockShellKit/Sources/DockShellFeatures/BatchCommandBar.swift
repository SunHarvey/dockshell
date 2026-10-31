import DockShellDomain
import Foundation
import SwiftUI

/// A transient single-line composer. It never intercepts a terminal's normal
/// keyboard/IME path and does not store a history of potentially private commands.
public struct BatchCommandBar: View {
    @ObservedObject private var model: TerminalTabsViewModel
    private let l10n: L10n
    @ViewState<String> private var command = ""
    @ViewState<Bool> private var showsDetails = false
    @FocusState private var focused: Bool

    public init(model: TerminalTabsViewModel, l10n: L10n) { self.model = model; self.l10n = l10n }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(l10n.string(.batchTitle), systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text(verbatim: l10n.string(.batchTargets)
                    .replacingOccurrences(of: "{connected}", with: String(model.batchConnectedCount))
                    .replacingOccurrences(of: "{open}", with: String(model.tabs.count)))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dockshell.batch.targets")
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(l10n.string(.batchClose))
                    .accessibilityLabel(Text(verbatim: l10n.string(.batchClose)))
                    .accessibilityIdentifier("dockshell.batch.close")
            }
            HStack(spacing: 8) {
                TextField(l10n.string(.batchPlaceholder), text: $command)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit(send).onExitCommand(perform: close)
                    .accessibilityLabel(Text(verbatim: l10n.string(.batchTitle)))
                    .accessibilityIdentifier("dockshell.batch.command")
                Button(l10n.string(.batchExecute), action: send)
                    .disabled(model.batchConnectedCount == 0 || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(l10n.string(.batchExecuteHelp))
                    .accessibilityIdentifier("dockshell.batch.execute")
            }
            if let error = model.batchCommandError {
                Text(verbatim: l10n.string(errorKey(error))).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dockshell.batch.error")
            } else if let report = model.batchCommandReport {
                DisclosureGroup(isExpanded: $showsDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(report.outcomes) { outcome in
                                HStack(spacing: 8) {
                                    Text(outcome.ordinal, format: .number.grouping(.never)).monospacedDigit()
                                        .foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                                    Text(verbatim: outcome.name).lineLimit(1).help(outcome.name)
                                    Spacer(minLength: 4)
                                    Text(verbatim: l10n.string(deliveryKey(outcome.delivery)))
                                        .foregroundStyle(outcome.delivery == .queueFull ? Color.red : Color.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }.frame(maxHeight: 100)
                } label: {
                    Text(verbatim: l10n.string(.batchSummary)
                        .replacingOccurrences(of: "{queued}", with: String(report.queuedCount))
                        .replacingOccurrences(of: "{skipped}", with: String(report.skippedCount))
                        .replacingOccurrences(of: "{full}", with: String(report.rejectedCount)))
                }
                .font(.caption).accessibilityLabel(Text(verbatim: l10n.string(.batchDetails)))
                .accessibilityIdentifier("dockshell.batch.result")
            }
            Text(verbatim: l10n.string(model.batchConnectedCount == 0 ? .batchNone : .batchHelp))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("dockshell.batch.bar")
        .task { focused = true }
        .onDisappear { command = "" }
    }

    private func send() {
        if model.sendBatchCommand(command) { command = ""; showsDetails = false }
        focused = true
    }
    private func close() { command = ""; model.hideBatchCommands() }
    private func errorKey(_ error: BatchCommandValidationError) -> L10nKey {
        switch error {
        case .empty: .batchErrorEmpty
        case .multiline: .batchErrorMultiline
        case .controlCharacters: .batchErrorControls
        case .tooLarge: .batchErrorLarge
        }
    }
    private func deliveryKey(_ delivery: BatchCommandDelivery) -> L10nKey {
        switch delivery {
        case .queued: .batchQueued
        case .skippedNotConnected: .batchDisconnected
        case .skippedAuthentication: .batchAuthentication
        case .queueFull: .batchQueueFull
        }
    }
}

import DockShellDomain
import DockShellTerminalUI
import SwiftUI

public extension L10n {
    var terminalLogLabels: TerminalLogLabels {
        TerminalLogLabels(started: string(.logStarted), ended: string(.logEnded),
            alternateEntered: string(.logAlternateEntered), alternateExited: string(.logAlternateExited),
            omittedPartial: string(.logOmitted), truncatedLine: string(.logTruncated),
            incomplete: string(.logIncomplete), olderRemoved: string(.logOlderRemoved))
    }
    var terminalMenuLabels: TerminalMenuLabels {
        TerminalMenuLabels(copy: string(.terminalCopy), paste: string(.terminalPaste),
            selectAll: string(.terminalSelectAll), accessibilityLabel: string(.terminalAccessibility),
            unavailable: string(.terminalUnavailable), logging: TerminalLogMenuLabels(
                export: string(.logExport), title: string(.logExportTitle), save: string(.save), start: string(.logStart), pause: string(.logPause),
                states: [.off: string(.logStatusOff), .starting: string(.logStatusStarting),
                    .recording: string(.logStatusRecording), .retained: string(.logStatusRetained),
                    .failed: string(.logStatusFailed)]))
    }
    func logErrorKey(_ error: TerminalLogError) -> L10nKey {
        switch error {
        case .unavailable: .logErrorUnavailable
        case .queueFull: .logErrorQueue
        case .captureIncomplete: .logErrorCapture
        case .destinationExists: .logErrorExists
        case .exportFailed: .logErrorExport
        case .writeFailed, .unsafeFile: .logErrorWrite
        }
    }
}

/// Actual log failures remain visible without introducing a permanent terminal footer.
struct TerminalLogNotice: View {
    @ObservedObject var log: TerminalLogController
    let l10n: L10n
    var body: some View {
        if let problem = log.problem {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(verbatim: l10n.string(l10n.logErrorKey(problem))).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(l10n.string(.ok)) { log.dismissProblem() }
            }.padding(10).background(.orange.opacity(0.1))
        }
    }
}

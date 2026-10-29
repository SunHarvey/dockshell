import DockShellTerminalDiagnostics
import Foundation

/// Opt-in, standalone measurements. Reports contain synthetic workload digests and resource counters only.
enum M6PerformanceVerification {
    static func run(reportURL: URL? = nil) async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try TerminalPerformanceConfiguration(
            bodyMiB: Int(environment["DOCKSHELL_PERFORMANCE_MIB"] ?? "64") ?? -1,
            rounds: Int(environment["DOCKSHELL_PERFORMANCE_ROUNDS"] ?? "3") ?? -1,
            idleSeconds: Int(environment["DOCKSHELL_PERFORMANCE_IDLE_SECONDS"] ?? "10") ?? -1)
        let report = try await TerminalPerformanceVerification.run(configuration: configuration)
        if let reportURL {
            try await Task.detached {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: reportURL, options: .atomic)
            }.value
        }
        for round in report.rounds {
            print(String(format: "M6 PERFORMANCE round %d: %.2f MiB/s, main-actor lag p95 %.2f ms / max %.2f ms, footprint %.1f MiB / sampled peak %.1f MiB, SHA-256 %@",
                round.round, round.deliveredMiBPerSecond, round.mainActorLagP95Milliseconds,
                round.mainActorLagMaxMilliseconds, Double(round.physicalFootprintAfterBytes) / 1_048_576,
                Double(round.sampledPeakPhysicalFootprintBytes) / 1_048_576, round.sha256))
        }
        print(String(format: "M6 IDLE %.2f seconds: %.3f%% process CPU, parked reads %d, delivered bytes %llu",
            report.idle.elapsedSeconds, report.idle.processCPUPercent, report.idle.parkedReadCalls, report.idle.deliveredBytes))
        print("PASS M6 rendering: exact synthetic bytes/hash, 4 KiB feed, 64 KiB channel, bounded history and main-actor progress")
        print("M6 terminal teardown released view: \(report.terminalViewReleased)")
    }
}

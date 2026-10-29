import DockShellApplication
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M4ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

/// Regression coverage for scalar validation in both optimized and unoptimized builds.
/// In Swift 6.4, bound CharacterSet method references incorrectly rejected valid values
/// when the domain module was built with its complete M4 source set and -O.
enum M4ValidationVerification {
    static func run() async throws {
        try verifyDomainValues()
        try await verifyGroupNames()
        print("PASS validation: ASCII/Chinese metadata, invalid controls/host syntax, endpoint normalization, font names and group validation")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M4ValidationFailure(description: message) }
    }

    private static func draft() -> SessionDraft {
        var result = SessionDraft()
        result.name = "fixture"; result.host = "example.invalid"; result.username = "tester"
        return result
    }

    private static func expect(_ error: DockShellError, _ value: SessionDraft) throws {
        do {
            _ = try value.validated(credentialID: nil)
            throw M4ValidationFailure(description: "Invalid session metadata unexpectedly passed validation")
        } catch let actual as DockShellError {
            try require(actual == error, "Scalar validation rejected the wrong session field")
        }
    }

    private static func verifyDomainValues() throws {
        for name in ["ASCII fixture", "生产中文🙂", "组合 e\u{301}", "  trimmed  "] {
            var value = draft(); value.name = name
            let profile = try value.validated(credentialID: nil)
            try require(profile.name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                        "Valid session name was changed or rejected")
        }
        for host in ["example.invalid", "127.0.0.1", "host-name", "host_name", "主机.example", "[::1]", "fe80::1%en0"] {
            var value = draft(); value.host = host
            try require(try value.validated(credentialID: nil).host == host,
                        "Valid session host was changed or rejected")
        }
        for name in ["", "  ", "bad\nname", "bad\tname", "bad\u{0}name", "bad\u{7}name"] {
            var value = draft(); value.name = name
            try expect(.invalidName, value)
        }
        for host in ["", "-option", "bad host", "bad/host", "bad@host", "bad,host", "bad;host", "bad\nhost", "bad\u{0}host"] {
            var value = draft(); value.host = host
            try expect(.invalidHost, value)
        }
        for username in ["", "-option", "bad name", "bad\nname", "bad\u{0}name"] {
            var value = draft(); value.username = username
            try expect(.invalidUsername, value)
        }

        let endpoint = try SSHHostEndpoint(host: "Example.INVALID.", port: 22)
        try require(endpoint.host == "example.invalid" && endpoint.knownHostsName == "example.invalid",
                    "Host endpoint normalization regressed")
        let ipv6 = try SSHHostEndpoint(host: "[2001:db8::1]", port: 2200)
        try require(ipv6.host == "2001:db8::1" && ipv6.knownHostsName == "[2001:db8::1]:2200",
                    "IPv6 endpoint normalization regressed")
        _ = try SSHHostEndpoint(host: "主机.example", port: 22)
        for host in ["", "-option", "bad host", "bad,host", "*", ".", "bad..host", "[::bad::]", "bad\u{0}host"] {
            do {
                _ = try SSHHostEndpoint(host: host, port: 22)
                throw M4ValidationFailure(description: "Invalid known_hosts endpoint passed validation")
            } catch HostTrustError.invalidEndpoint {}
        }

        for fontName in ["Menlo", "等宽字体🙂", "  Monaco  "] {
            let value = try TerminalSettings(fontName: fontName).validated()
            try require(value.fontName == fontName.trimmingCharacters(in: .whitespacesAndNewlines),
                        "Valid terminal font name was changed or rejected")
        }
        for fontName in ["", "  ", "bad\nfont", "bad\tfont", "bad\u{0}font"] {
            do {
                _ = try TerminalSettings(fontName: fontName).validated()
                throw M4ValidationFailure(description: "Invalid terminal font name passed validation")
            } catch TerminalSettingsError.invalidFont {}
        }
    }

    private static func verifyGroupNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockShell-validation-\(UUID().uuidString)")
        let repository = SQLiteSessionRepository(url: directory.appendingPathComponent("sessions.sqlite"))
        let service = WorkspaceService(repository: repository, credentials: TestCredentialStore(), privateKeys: PrivateKeyBookmarks())
        do {
            for name in ["ASCII group", "生产中文🙂", "  trimmed group  "] {
                let id = UUID()
                let state = try await service.saveGroup(id: id, name: name)
                try require(state.snapshot.groups.contains {
                    $0.id == id && $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
                }, "Valid group metadata was changed or rejected")
            }
            let before = try await service.load().snapshot.groups
            for name in ["", "  ", "bad\ngroup", "bad\tgroup", "bad\u{0}group"] {
                do {
                    _ = try await service.saveGroup(name: name)
                    throw M4ValidationFailure(description: "Invalid group metadata passed validation")
                } catch DockShellError.invalidGroupName {}
            }
            try require(try await service.load().snapshot.groups == before,
                        "Rejecting invalid group names changed saved groups")
            await repository.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

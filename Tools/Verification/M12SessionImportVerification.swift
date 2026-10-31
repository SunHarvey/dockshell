import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import Foundation
import SwiftUI

struct M12Failure: Error, CustomStringConvertible { let description: String }

/// Every file, key and database is disposable; personal configuration is never read.
enum M12SessionImportVerification {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M12Failure(description: message) }
    }

    static func run() async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("test key")
        try check(try await M5AuthenticationVerification.runKeyTool(arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path]) == 0,
            "Disposable key generation failed")
        let reader = OpenSSHConfigurationReader(home: home, localUser: "fixture-local")
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
        let config = ssh.appendingPathComponent("config")
        try write("Host included\n HostName included.invalid\n User first\n", ssh.appendingPathComponent("conf.d/01.conf"))
        try write("Host included\n User second\n", ssh.appendingPathComponent("conf.d/02.conf"))
        try write("""
        Include conf.d/*.conf
        Host api api-alt
          HostName = 192.0.2.10 # inline comment
          PORT=2222
          IdentityFile "~/.ssh/test key"
          IdentitiesOnly yes
        Host api
          Port 3333
        Host app* !app-prod
          User deploy
        Host app-dev app-prod
          HostName %h.example.invalid
        Host *
          User fallback
        """, config)
        let document = try await reader.read(from: nil)
        try check(document.rows.count == 5 && document.patternRuleCount == 2, "Concrete aliases or pattern count incorrect")
        let api = document.rows.first { $0.name == "api" }!
        try check(api.host == "192.0.2.10" && api.port == "2222" && api.username == "fallback" && api.keyPath == key.path,
            "Quotes, equals, comments, defaults or first-value semantics failed")
        try check(document.rows.first { $0.name == "included" }?.username == "first", "Include glob order failed")
        try check(document.rows.first { $0.name == "app-dev" }?.username == "deploy" &&
            document.rows.first { $0.name == "app-prod" }?.username == "fallback", "Wildcard or negation failed")
        try check(document.rows.first { $0.name == "app-prod" }?.host == "app-prod.example.invalid", "Hostname token expansion failed")
        // ssh -G is used ONLY as an oracle for this authored, command-free fixture.
        // The production reader never invokes it, and the Match fixture below never reaches it.
        let reference = ssh.appendingPathComponent("reference")
        let referenceText = try String(contentsOf: config, encoding: .utf8)
            .replacingOccurrences(of: "Include conf.d/", with: "Include " + ssh.path + "/conf.d/")
            .replacingOccurrences(of: "~/.ssh/test key", with: key.path)
        try write(referenceText, reference)
        for row in document.rows {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", reference.path, "-G", row.name]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try check(process.terminationStatus == 0 && bytes.count < 64_000, "Controlled SSH config oracle failed")
            let fields = String(decoding: bytes, as: UTF8.self).split(separator: "\n").reduce(into: [String: String]()) { values, line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 && values[parts[0]] == nil { values[parts[0]] = parts[1] }
            }
            try check(fields["hostname"] == row.host && fields["port"] == row.port && fields["user"] == row.username,
                "Static import differs from system SSH for a supported fixture")
        }
        print("PASS SSH config parser: concrete/multiple/repeated aliases, defaults, quotes, comments, case, equals, wildcard/negation, tokens, lexical Include")

        try write("Host UPPER\nUser upper-user\nHost upper\nUser lower-user\nHost *\nPort 22\n", config)
        let cases = try await reader.read(from: nil)
        try check(cases.rows.count == 2 && cases.rows[0].username == "upper-user" && cases.rows[1].username == "lower-user",
            "Host arguments must remain case-sensitive even though keywords are not")

        let child = ssh.appendingPathComponent("conditional.conf")
        try write("User nested\nHost child-only\n HostName child.invalid\n", child)
        try write("Host parent\n Include conditional.conf\n Port 2200\nHost other\n User other-user\n", config)
        let conditional = try await reader.read(from: nil)
        try check(conditional.rows.map(\.name) == ["parent", "other"] && conditional.rows[0].username == "nested" &&
            conditional.rows[0].port == "2200" && conditional.rows[1].username == "other-user", "Conditional Include or parent-state restoration failed")
        try write("Include missing-*.conf\nHost plain\n", config)
        let missing = try await reader.read(from: nil)
        try check(missing.rows.count == 1 && missing.rows[0].username == "fixture-local", "Absent Include or local-user default failed")
        try write("Host two\nIdentityFile \"\(key.path)\"\nIdentityFile \"\(key.path).other\"\n", config)
        let multiple = try await reader.read(from: nil)
        try check(multiple.rows[0].keyPaths.count == 2 && multiple.rows[0].keyPath.isEmpty &&
            multiple.rows[0].validationError == .privateKeyRequired, "Multiple identities silently reduced to the first")
        let marker = root.appendingPathComponent("MUST-NOT-EXECUTE")
        try write("Host route\nProxyJump gateway\nHost direct\nMatch exec \"touch \(marker.path)\"\n User unsafe\n", config)
        let unsafe = try await reader.read(from: nil)
        try check(!FileManager.default.fileExists(atPath: marker.path) && unsafe.rows.allSatisfy { $0.issues.contains(.matchUnsupported) && !$0.selected },
            "Match executed or its effects were discarded")
        try check(unsafe.rows[0].issues.contains(.unsupported("proxyjump")), "Jump host silently converted to direct SSH")
        try write("Host crypto\nCiphers aes128-cbc\nHost safe\nProxyJump none\n", config)
        let crypto = try await reader.read(from: nil)
        try check(!crypto.rows[0].issues.isEmpty && crypto.rows[1].issues.isEmpty, "Unsupported options affected unrelated hosts")
        try write("Include config\n", config)
        try await expecting(.includeCycle) { _ = try await reader.read(from: nil) }
        try write("Host \"unclosed\n", config)
        try await expecting(.invalidText) { _ = try await reader.read(from: nil) }
        try write("Include ${UNSAFE}/config\n", config)
        try await expecting(.invalidPath) { _ = try await reader.read(from: nil) }
        try write(String(repeating: "#", count: 2_000_001), config)
        try await expecting(.limitExceeded) { _ = try await reader.read(from: nil) }
        try write("Host cancellation\n", config)
        let cancelled = Task { try Task.checkCancellation(); return try await reader.read(from: nil) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw M12Failure(description: "Cancelled parse completed") }
        catch is CancellationError { }
        print("PASS SSH config safety: conditional Include, absent glob, cycles, limits, cancellation, multiple keys, Match/ProxyJump/crypto diagnostics, zero command execution")

        let repo = SQLiteSessionRepository(url: root.appendingPathComponent("database/sessions.sqlite"))
        let credentials = TestCredentialStore()
        let service = WorkspaceService(repository: repo, credentials: credentials, privateKeys: PrivateKeyBookmarks())
        let rows = try await service.prepareImportRows(document.rows)
        try check(rows.allSatisfy { $0.validationError == nil }, "Valid key did not preflight")
        var chosen = multiple.rows[0]; chosen.keyPath = key.path
        let chosenRows = try await service.prepareImportRows([chosen])
        try check(chosenRows[0].validationError == nil && chosenRows[0].keyBookmark != nil, "Explicit identity selection did not validate")
        let before = try await repo.snapshot()
        try check(before.groups.isEmpty && before.profiles.isEmpty, "Preview changed the database")
        let (state, first) = try await service.importSessions(rows, into: .named("local-ssh-config"))
        try check(first.insertedIDs.count == 5 && state.snapshot.groups.count == 1 && state.snapshot.profiles.count == 5,
            "Atomic group/session creation failed")
        let storedSecrets = await credentials.identifiers()
        try check(state.snapshot.profiles.allSatisfy { $0.authentication.credentialID == nil } && storedSecrets.isEmpty,
            "Import wrote authentication secrets")
        let (_, repeated) = try await service.importSessions(rows, into: .named("LOCAL-SSH-CONFIG"))
        try check(repeated.insertedIDs.isEmpty && repeated.skippedNames.count == 5 && repeated.groupID == first.groupID,
            "Duplicate skips or group reuse failed")
        let fresh = SessionImportRow(name: "renamed-entry", host: "192.0.2.10", username: "fixture")
        let (_, renamed) = try await service.importSessions([fresh], into: .existing(first.groupID!))
        try check(renamed.insertedIDs.count == 1, "Rename did not allow import")
        let snapshot = try await repo.snapshot()
        let a = SessionProfile(name: "rollback-a", host: "192.0.2.1", username: "fixture", authentication: .agent)
        let b = SessionProfile(id: a.id, name: "rollback-b", host: "192.0.2.2", username: "fixture", authentication: .agent)
        do { _ = try await repo.importProfiles([a, b], into: .named("must-rollback")); throw M12Failure(description: "Expected UUID collision") }
        catch let error as DockShellError { try check(error == .storageUnavailable, "Unexpected transactional failure") }
        try check(try await repo.snapshot() == snapshot, "Partial sessions or orphan group survived rollback")
        do { _ = try await repo.importProfiles([a], into: .existing(UUID())); throw M12Failure(description: "Missing group accepted") }
        catch let error as DockShellError { try check(error == .missingGroup, "Incorrect group failure") }
        var bad = SessionImportRow(name: "bad-key", host: "bad.invalid", username: "fixture", authentication: .privateKey,
            keyPaths: [key.path + ".missing"])
        bad = try await service.prepareImportRows([bad])[0]
        try check(bad.validationError == .privateKeyUnavailable, "Missing key did not produce a preview error")
        let ppk = ssh.appendingPathComponent("unsupported.ppk"); try write("PuTTY-User-Key-File-3: ssh-ed25519", ppk)
        let ppkRow = SessionImportRow(name: "ppk", host: "ppk.invalid", username: "fixture", authentication: .privateKey, keyPaths: [ppk.path])
        try check(try await service.prepareImportRows([ppkRow])[0].validationError == .unsupportedPrivateKey, "PPK silently accepted")
        let metadata = SessionProfile(name: "bad-name", host: "-invalid", username: "fixture", authentication: .agent)
        do { _ = try await repo.importProfiles([metadata], into: .named("invalid-group")); throw M12Failure(description: "Invalid metadata accepted") }
        catch let error as DockShellError { try check(error == .invalidHost, "Invalid metadata error changed") }
        try check(try await repo.snapshot() == snapshot, "Rejected metadata created an empty group")
        var stale = rows.first { $0.authentication == .privateKey }!
        stale.keyPath += ".removed-after-preview"
        do {
            _ = try await service.importSessions([stale], into: .named("stale-must-not-create"))
            throw M12Failure(description: "Stale key preflight was reused on commit")
        } catch let error as DockShellError { try check(error == .privateKeyUnavailable, "Stale key did not fail explicitly") }
        try check(try await repo.snapshot() == snapshot, "Failed final key validation changed storage")
        await repo.close()
        let reopened = SQLiteSessionRepository(url: root.appendingPathComponent("database/sessions.sqlite"))
        try check(try await reopened.snapshot() == snapshot, "Import did not persist after reopen")
        await reopened.close()
        print("PASS import persistence: atomic group reuse, duplicates, rename, mid-batch rollback, missing group, key preflight, zero credential writes, restart")
    }

    private static func expecting(_ expected: SessionImportError, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch let error as SessionImportError { try check(error == expected, "Unexpected config error"); return }
        throw M12Failure(description: "Expected config error did not occur")
    }

    @MainActor
    static func runUI(l10n: L10n) async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("fixture-config")
        try Data("Host ui-host ui-alt\n HostName 192.0.2.5\n User fixture\n".utf8).write(to: config)
        let repo = SQLiteSessionRepository(url: root.appendingPathComponent("db/sessions.sqlite"))
        let service = WorkspaceService(repository: repo, credentials: TestCredentialStore(), privateKeys: PrivateKeyBookmarks())
        let workspace = WorkspaceViewModel(service: service, configurationReader: OpenSSHConfigurationReader(home: root, localUser: "fixture"))
        await workspace.load()
        let model = SessionImportViewModel(workspace: workspace)
        await model.load(from: config)
        try check(model.canSave && model.readyCount == 2 && model.groupName == "local-ssh-config", "Import defaults incorrect")
        let hosting = NSHostingView(rootView: SessionImportView(model: model, l10n: l10n, automaticallyLoad: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields($0) }
        }
        guard let field = fields(hosting).first(where: { $0.isEditable && $0.stringValue == "local-ssh-config" }),
              window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            throw M12Failure(description: "Native group input did not mount")
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("导入测试🙂", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(40))
        try check(model.groupName == "导入测试🙂", "Native Unicode group edit failed")
        window.makeFirstResponder(nil)
        // Click only this test process's confirm button, using the fixed sheet's content bounds.
        let point = hosting.convert(NSPoint(x: hosting.bounds.maxX - 65,
            y: hosting.isFlipped ? hosting.bounds.maxY - 34 : hosting.bounds.minY + 34), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 120_001, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw M12Failure(description: "Cannot create native confirm event")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await M11BatchCommandVerification.wait("Native import confirmation did not save") { model.receipt != nil }
        try check(model.receipt?.insertedIDs.count == 2 && workspace.groups.first?.name == "导入测试🙂" && workspace.profiles.count == 2,
            "Confirm did not refresh sidebar")
        let again = SessionImportViewModel(workspace: workspace); again.groupName = "导入测试🙂"
        await again.load(from: config)
        try check(again.duplicateIDs.count == 2 && again.readyCount == 0, "Duplicate preview missing")
        again.rows[0].name = "改名后的服务器"
        try check(again.duplicateIDs.count == 1 && again.readyCount == 1, "Rename did not clear conflict")
        again.rows[1].selected = false
        await again.save()
        try check(again.receipt?.insertedIDs.count == 1 && workspace.profiles.count == 3, "Selection/rename failed")
        let cancelled = SessionImportViewModel(workspace: workspace)
        let previous = try await repo.snapshot()
        await cancelled.load(from: config)
        try check(try await repo.snapshot() == previous, "Preview/cancel mutated storage")
        await repo.close()
        print("PASS import UI (\(l10n.language)): native preview, Unicode group editing, defaults, confirmation, duplicates, rename, selection, catalog refresh, cancel without writes")
    }
}

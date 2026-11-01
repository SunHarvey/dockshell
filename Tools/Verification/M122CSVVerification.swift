import AppKit
import Darwin
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import Foundation
import SwiftUI

/// CSV coverage uses generated keys and private temporary files; it never reads personal configuration.
enum M122CSVVerification {
    private static func check(_ value: Bool, _ message: String) throws {
        try M12ServerImportVerification.check(value, "CSV: " + message)
    }

    static func run() async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CSVServerReader(home: root)
        let header = ServerCSVFormat.header
        let text = "\u{feff}" + header + "\r\n\"生产,一号🙂\",192.0.2.1,,root,AGENT,\r\n\"say \"\"hello\"\"\",2001:db8::1,2222,admin,password,\r\n"
        let document = try await reader.parse(text)
        try check(document.rows.count == 2 && document.rows[0].name == "生产,一号🙂" && document.rows[0].port == "22" &&
            document.rows[1].name == "say \"hello\"" && document.rows[1].authentication == .password,
            "BOM/CRLF/Unicode, comma or escaped quote decoding failed")
        try check(document.rows.map(\.sourceLine) == [2, 3] && document.rows.allSatisfy(\.isValidForImport), "Source lines or row validation failed")
        let reordered = try await reader.parse(" AUTH ,USERNAME,HOST,NAME\nagent,root,192.0.2.2,reordered")
        try check(reordered.rows[0].name == "reordered" && reordered.rows[0].port == "22", "Reordered/optional/case-insensitive headers failed")
        let multiline = try await reader.parse(header + "\n\"two\nlines\",192.0.2.1,22,root,agent,\nnext,192.0.2.2,22,root,agent,")
        try check(multiline.rows[0].name == "two\nlines" && multiline.rows[0].validationError == .invalidName &&
            multiline.rows[1].sourceLine == 4, "Multiline field parsing or physical source line tracking failed")
        let blank = try await reader.parse("\r\n\t\r\n" + header + "\r\n\r\nplain,host.invalid,22,root,agent,\r\n\r\n")
        try check(blank.rows.count == 1 && blank.rows[0].sourceLine == 5, "Blank lines changed row boundaries")
        let short = try await reader.parse(header + "\nshort,192.0.2.1,22,root,agent\nlong,192.0.2.2,22,root,agent,,extra")
        try check(short.rows[0].issues == [.csvColumns(expected: 6, actual: 5)] &&
            short.rows[1].issues == [.csvColumns(expected: 6, actual: 7)] && short.rows.allSatisfy { !$0.selected && !$0.isValidForImport },
            "Row column mismatches were silently accepted")
        let invalid = try await reader.parse(header + "\ninvalid,-bad,70000,,mystery,\nkey,192.0.2.1,22,root,key,relative.key")
        try check(invalid.rows[0].authenticationNeedsSelection && !invalid.rows[0].isValidForImport &&
            invalid.rows[1].keyPath == "relative.key", "Invalid authentication or relative path was silently rewritten")
        // A separate writer serves as an oracle for valid quoted fields, including comma and quote combinations.
        let names = (0..<200).map { "节点,\($0) \"quoted\" 🙂" }
        let encoded = header + "\n" + names.map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\",192.0.2.5,22,root,agent,"
        }.joined(separator: "\n")
        try check(try await reader.parse(encoded).rows.map(\.name) == names, "Generated quoted records did not round-trip")
        print("PASS CSV parser: UTF-8 BOM, Unicode/emoji, CRLF, commas/escaped quotes, multiline source lines, reordered optional headers, defaults, 200 generated records, explicit row diagnostics")

        for source in ["", "\u{feff}\r\n", header, header + "\n\n"] {
            try await expecting(.empty) { _ = try await reader.parse(source) }
        }
        for source in ["name,host,username\na,b,c", "name,host,username,auth,auth\na,b,c,agent,agent",
                       "name,host,username,auth,password\na,b,c,password,synthetic-do-not-echo",
                       "name;host;username;auth\na;b;c;agent"] {
            try await expecting(.invalidHeaders) { _ = try await reader.parse(source) }
        }
        for source in [header + "\n\"open,192.0.2.1,22,root,agent,", header + "\nbad\"quote,host,22,root,agent,",
                       header + "\n\"closed\"x,host,22,root,agent,", header + "\n\"closed\" \"wrong\",host,22,root,agent,"] {
            try await expecting(.malformed(line: 2)) { _ = try await reader.parse(source) }
        }
        try await expecting(.invalidEncoding) { _ = try await reader.parse(header + "\n\0") }
        try await expecting(.limitExceeded) { _ = try await reader.parse(String(repeating: "x", count: 2_000_001)) }
        try await expecting(.limitExceeded) { _ = try await reader.parse(header + "\n" + String(repeating: "x", count: 16_385) + ",host,22,root,agent,") }
        let thousand = header + "\n" + (0..<1000).map { "host-\($0),192.0.2.1,22,root,agent," }.joined(separator: "\n")
        try check(try await reader.parse(thousand).rows.count == 1000, "Exact row ceiling rejected")
        try await expecting(.limitExceeded) { _ = try await reader.parse(thousand + "\none-more,192.0.2.1,22,root,agent,") }
        let file = root.appendingPathComponent("servers.csv")
        try Data(text.utf8).write(to: file)
        try check(try await reader.read(from: file).rows.map(\.name) == document.rows.map(\.name), "File and pasted input differ")
        let invalidEncoding = root.appendingPathComponent("not-utf8.csv")
        try Data([0xff, 0xfe, 0x00]).write(to: invalidEncoding)
        try await expecting(.invalidEncoding) { _ = try await reader.read(from: invalidEncoding) }
        try await expecting(.unreadable) { _ = try await reader.read(from: root) }
        let fifo = root.appendingPathComponent("not-a-regular-file")
        try check(mkfifo(fifo.path, 0o600) == 0, "Cannot create FIFO fixture")
        try await expecting(.unreadable) { _ = try await reader.read(from: fifo) }
        try await checkCancellation(reader)
        print("PASS CSV boundaries: missing/duplicate/secret headers, malformed quoting, empty input, invalid encoding, 2 MB/16 KB/1000-row limits, file parity, nonblocking FIFO rejection and cancellation")

        let key = root.appendingPathComponent("test key")
        try check(try await M5AuthenticationVerification.runKeyTool(arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path]) == 0,
            "Generated key failed")
        let credentials = TestCredentialStore()
        let repo = SQLiteServerRepository(url: root.appendingPathComponent("db/sessions.sqlite"))
        let service = WorkspaceService(repository: repo, credentials: credentials, privateKeys: PrivateKeyBookmarks())
        let spacedKey = root.appendingPathComponent("test key ")
        try FileManager.default.copyItem(at: key, to: spacedKey)
        let spacedSource = header + "\nspaces,192.0.2.4,22,root,key,\"" + spacedKey.path + "\""
        let spacedRows = try await service.prepareImportRows(try await reader.parse(spacedSource).rows)
        try check(spacedRows[0].keyPath == spacedKey.path && spacedRows[0].isValidForImport, "Significant key filename spaces were stripped")
        let rows = try await service.prepareImportRows(try await reader.parse(header +
            "\nagent,192.0.2.1,22,root,agent,\npassword,192.0.2.2,22,root,password,\nkey,192.0.2.3,22,root,key,~/test key").rows)
        try check(rows.allSatisfy(\.isValidForImport) && rows[2].keyPath == key.path, "Tilde path/key preflight failed")
        let (state, receipt) = try await service.importServers(rows, into: .named("CSV batch"))
        try check(receipt.insertedIDs.count == 3 && state.snapshot.profiles.allSatisfy { $0.authentication.credentialID == nil },
            "CSV metadata or authentication persistence failed")
        let (_, repeatReceipt) = try await service.importServers(rows, into: .named("csv BATCH"))
        try check(repeatReceipt.skippedNames.count == 3 && repeatReceipt.insertedIDs.isEmpty, "Repeated batch overwrote existing sessions")
        let duplicateRows = try await reader.parse(header + "\nsame,192.0.2.1,22,root,agent,\nSAME,192.0.2.2,22,root,agent,").rows
        let (_, duplicateReceipt) = try await service.importServers(duplicateRows, into: .existing(receipt.groupID!))
        try check(duplicateReceipt.insertedIDs.count == 1 && duplicateReceipt.skippedNames == ["SAME"], "In-batch duplicates failed")
        let previous = try await repo.snapshot()
        var unresolved = try await reader.parse(header + "\nunresolved,192.0.2.1,22,root,typo,").rows[0]
        do { _ = try await service.importServers([unresolved], into: .named("must-not-create")); throw M12Failure(description: "CSV unresolved auth reached storage") }
        catch let error as ServerImportError { try check(error == .invalidText, "Wrong unresolved-auth error") }
        try check(try await repo.snapshot() == previous, "Rejected CSV import created an empty group")
        unresolved.authenticationNeedsSelection = false; unresolved.authentication = .agent
        _ = try await service.importServers([unresolved], into: .existing(receipt.groupID!))
        let secrets = await credentials.identifiers()
        try check(secrets.isEmpty, "CSV import wrote a credential")
        let final = try await repo.snapshot()
        await repo.close()
        let reopened = SQLiteServerRepository(url: root.appendingPathComponent("db/sessions.sqlite"))
        try check(try await reopened.snapshot() == final, "CSV profiles did not survive reopen")
        await reopened.close()
        print("PASS CSV persistence: agent/password/key metadata, external ~/ key, group reuse, same-group and in-batch skips, explicit auth correction, zero Keychain writes and restart")
    }

    @MainActor
    private static func checkCancellation(_ reader: CSVServerReader) async throws {
        let task = Task { try await reader.parse(ServerCSVFormat.example) }
        task.cancel()
        do { _ = try await task.value; throw M12Failure(description: "CSV cancelled parse completed") }
        catch is CancellationError { }
    }

    private static func expecting(_ expected: ServerCSVError, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch let error as ServerCSVError { try check(error == expected, "Incorrect sanitized CSV error"); return }
        throw M12Failure(description: "CSV expected error not raised")
    }

    @MainActor
    static func runUI(l10n: L10n) async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = SQLiteServerRepository(url: root.appendingPathComponent("db/sessions.sqlite"))
        let service = WorkspaceService(repository: repo, credentials: TestCredentialStore(), privateKeys: PrivateKeyBookmarks())
        let workspace = WorkspaceViewModel(service: service, csvReader: CSVServerReader(home: root))
        await workspace.load()
        let group = ServerGroup(name: "Existing group")
        try await workspace.saveGroup(id: group.id, name: group.name)
        var existing = ServerDraft(); existing.name = "existing"; existing.host = "192.0.2.9"; existing.username = "fixture"
        existing.authentication = .agent; existing.groupID = group.id
        try await workspace.save(existing)
        let model = ServerImportViewModel(workspace: workspace, kind: .csv)
        try check(model.showsCSVInput && !model.canSave && model.groupName == "csv-import", "CSV input defaults incorrect")
        let hosting = NSHostingView(rootView: ServerImportView(model: model, l10n: l10n))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        func views<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, type: type) }
        }
        guard let editor = views(hosting, type: NSTextView.self).first(where: { $0.isEditable && $0.isRichText == false }),
              window.makeFirstResponder(editor) else { throw M12Failure(description: "CSV native source editor did not mount") }
        let source = ServerCSVFormat.header + "\nexisting,192.0.2.1,22,root,agent,\n\"中文,🙂\",192.0.2.2,22,root,password,\nbroken,-bad,70000,,typo,"
        editor.insertText(source, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await M11BatchCommandVerification.wait("CSV text editor did not bind") { model.csvText == source }
        window.makeFirstResponder(nil)
        try await clickFooter(hosting, window: window)
        try await M11BatchCommandVerification.wait("CSV native preview button failed") { !model.showsCSVInput }
        model.existingGroupID = group.id
        try check(model.duplicateIDs.count == 1 && model.readyCount == 1 && !model.rows[2].isValidForImport, "Group duplicate or invalid-row preview failed")
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
        guard let nameField = views(hosting, type: NSTextField.self).first(where: { $0.isEditable && $0.stringValue == "existing" }),
              window.makeFirstResponder(nameField), let nameEditor = nameField.currentEditor() as? NSTextView else {
            throw M12Failure(description: "CSV editable name field did not mount")
        }
        nameEditor.setSelectedRange(NSRange(location: 0, length: nameEditor.string.utf16.count))
        nameEditor.insertText("Renamed 中文🙂", replacementRange: nameEditor.selectedRange())
        try await M11BatchCommandVerification.wait("CSV rename did not clear duplicate") { model.duplicateIDs.isEmpty && model.readyCount == 2 }
        window.makeFirstResponder(nil)
        model.rows[0].selected = false
        model.rows[2].host = "192.0.2.3"; model.rows[2].port = "22"; model.rows[2].username = "fixture"
        model.rows[2].authentication = .agent; model.rows[2].authenticationNeedsSelection = false
        try check(model.readyCount == 2, "CSV edits did not make metadata importable")
        try await clickFooter(hosting, window: window)
        try await M11BatchCommandVerification.wait("CSV native confirmation failed") { model.receipt != nil }
        try check(model.receipt?.insertedIDs.count == 2 && workspace.profiles.count == 3 && model.csvText.isEmpty,
            "CSV confirm did not refresh workspace or clear raw draft")
        let before = try await repo.snapshot()
        let changed = ServerImportViewModel(workspace: workspace, kind: .csv)
        changed.csvText = source; await changed.previewCSV(); changed.changeCSVSource()
        try check(changed.rows.isEmpty && !changed.canSave && changed.csvText == source && changed.showsCSVInput,
            "Changing CSV source retained a stale saveable preview")
        try check(try await repo.snapshot() == before, "CSV preview/cancel wrote to storage")
        changed.csvText = ServerCSVFormat.header + "\n\"broken"
        await changed.previewCSV()
        try check(changed.error == .csvErrorMalformed && changed.errorLine == 2 && !changed.canSave && changed.showsCSVInput,
            "CSV malformed input did not surface a localized line error")
        let file = root.appendingPathComponent("selected.csv")
        try Data((ServerCSVFormat.header + "\nfrom-file,192.0.2.8,22,root,agent,").utf8).write(to: file)
        await changed.load(from: file)
        try check(changed.rows.first?.name == "from-file" && changed.sourceURL == file && changed.csvText.isEmpty && changed.canSave,
            "CSV file preview retained stale pasted input")
        changed.groupName = "新分组🙂"; await changed.save()
        try check(workspace.groups.contains(where: { $0.name == "新分组🙂" }), "CSV new destination group failed")
        await repo.close()
        print("PASS CSV UI (\(l10n.language)): native multiline Unicode editing, Preview and Confirm clicks, existing/new groups, live duplicate/rename/selection, invalid-row correction, localized source errors, file input, draft clearing and cancellation")
    }

    @MainActor
    private static func clickFooter(_ hosting: NSView, window: NSWindow) async throws {
        // Published text edits enable the button on SwiftUI's next render, not inside NSTextView's callback.
        try await Task.sleep(for: .milliseconds(70)); hosting.layoutSubtreeIfNeeded()
        let point = hosting.convert(NSPoint(x: hosting.bounds.maxX - 65,
            y: hosting.isFlipped ? hosting.bounds.maxY - 34 : hosting.bounds.minY + 34), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 122_000, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw M12Failure(description: "CSV cannot construct test-scoped pointer event")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }
}

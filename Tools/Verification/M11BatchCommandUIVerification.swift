import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation
import SwiftUI

private actor M11UISettings: SettingsRepository {
    func load() -> TerminalSettings { .defaults }
    func save(_ settings: TerminalSettings) {}
}

/// Uses public native editing/accessibility paths, with all events confined to
/// this test process's own window. No clipboard, preferences or live servers.
@MainActor
enum M11BatchCommandUIVerification {
    static func run(l10n: L10n) async throws {
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let factory = M11Factory()
        let tabs = TerminalTabsViewModel(factory: factory)
        let profile = SessionProfile(name: "UI 中文", host: "ui-batch.invalid", username: "fixture", authentication: .agent)
        _ = tabs.open(profile: profile, settings: .defaults)
        _ = tabs.open(profile: profile, settings: .defaults)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: M11UISettings()))
        await settings.load()
        let root = NSHostingView(rootView: TerminalTabsPane(model: tabs, settings: settings, l10n: l10n))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.makeKeyAndOrderFront(nil)
        defer { tabs.closeAll(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await M11BatchCommandVerification.wait("Native terminal tabs did not connect") { tabs.batchConnectedCount == 2 }
        try M11BatchCommandVerification.check(!tabs.showsBatchCommands, "Batch bar was not hidden by default")
        tabs.toggleBatchCommands()
        try await M11BatchCommandVerification.wait("Batch command input did not mount") {
            root.layoutSubtreeIfNeeded(); return editableField(root) != nil
        }
        guard let field = editableField(root), let a = await factory.entries[0].transport.channel() else { throw M11BatchCommandVerification.failure("Native UI fixtures missing") }
        try insert("printf '界面🙂'", into: field, window: window)
        guard let inputResponder = window.firstResponder else { throw M11BatchCommandVerification.failure("Command field lost its editor") }
        factory.entries[1].session.controller.connect(to: profile, settings: settings.settings)
        try await M11BatchCommandVerification.wait("Selected SSH fixture did not reconnect while drafting") {
            factory.entries[1].session.controller.phase == .connected
        }
        try M11BatchCommandVerification.check(window.firstResponder === inputResponder && field.stringValue == "printf '界面🙂'",
            "SSH connection completion stole focus or changed the batch draft")
        guard let b = await factory.entries[1].transport.channel() else { throw M11BatchCommandVerification.failure("Reconnected UI fixture missing") }
        // SwiftUI's virtual AX buttons are not exposed by every command-line
        // runner. Derive a scoped pointer target from the public native input frame.
        try await Task.sleep(for: .milliseconds(80)); root.layoutSubtreeIfNeeded()
        let inputFrame = field.convert(field.bounds, to: nil)
        let contentFrame = root.convert(root.bounds, to: nil)
        try click(NSPoint(x: (inputFrame.maxX + contentFrame.maxX - 12) / 2, y: inputFrame.midY), window: window)
        let first = Data("printf '界面🙂'\r".utf8)
        try await M11BatchCommandVerification.waitAsync("Native button did not send exactly once to both tabs") {
            let x = await a.input(), y = await b.input(); return x == first && y == first
        }
        try await M11BatchCommandVerification.wait("Successful submission did not clear the command field") { field.stringValue.isEmpty }
        try insert("echo return-key", into: field, window: window)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw M11BatchCommandVerification.failure("Cannot construct scoped Return event")
        }
        window.sendEvent(event)
        let both = first + Data("echo return-key\r".utf8)
        try await M11BatchCommandVerification.waitAsync("Native Return did not send one command to every tab") {
            let x = await a.input(), y = await b.input(); return x == both && y == both
        }
        for width in [360, 220, 180] {
            window.setContentSize(NSSize(width: width, height: 360)); root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let frame = field.convert(field.bounds, to: root)
            try M11BatchCommandVerification.check(frame.width > 40 && root.bounds.insetBy(dx: -2, dy: -2).contains(frame),
                "Command field overflowed the narrow workspace")
        }
        window.setContentSize(NSSize(width: 360, height: 360)); root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let compactInput = field.convert(field.bounds, to: nil)
        let compactContent = root.convert(root.bounds, to: nil)
        try click(NSPoint(x: compactContent.maxX - 18, y: compactInput.maxY + 15), window: window)
        try await M11BatchCommandVerification.wait("Command bar did not close") { !tabs.showsBatchCommands }
        tabs.toggleBatchCommands()
        try await M11BatchCommandVerification.wait("Reopened command bar did not mount") { editableField(root) != nil }
        try M11BatchCommandVerification.check(editableField(root)?.stringValue == "", "Reopening restored private command history")
        print("PASS batch UI (\(l10n.language)): native CJK/emoji editing, Send and Return each fan out once, reconnect cannot steal draft focus, narrow layout, close and no command history")
    }

    private static func insert(_ value: String, into field: NSTextField, window: NSWindow) throws {
        guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            throw M11BatchCommandVerification.failure("Batch field did not become first responder")
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(value, replacementRange: editor.selectedRange())
    }
    private static func editableField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { return field }
        return view.subviews.lazy.compactMap { editableField($0) }.first
    }
    private static func click(_ point: NSPoint, window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 115_000, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw M11BatchCommandVerification.failure("Cannot construct scoped pointer event")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }
}

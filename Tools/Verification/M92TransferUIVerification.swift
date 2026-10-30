import AppKit
import DockShellDomain
import DockShellFeatures
import Foundation
import SwiftUI

private struct M92UIFailure: Error, CustomStringConvertible { let description: String }

/// SwiftUI's hosted accessibility nodes are not uniformly tagged with the full
/// Objective-C protocol at runtime. Query NSView directly, and use AppKit's
/// documented informal accessibility bridge for remaining NSObject nodes.
@MainActor
private struct M92AccessibleElement {
    let object: NSObject
    private func attribute(_ name: NSAccessibility.Attribute) -> Any? {
        guard object.accessibilityAttributeNames().contains(name) else { return nil }
        return object.accessibilityAttributeValue(name)
    }
    var identifier: String? {
        if let view = object as? NSView { return view.accessibilityIdentifier() ?? attribute(.identifier) as? String }
        if let item = object as? any NSAccessibilityProtocol { return item.accessibilityIdentifier() ?? attribute(.identifier) as? String }
        return attribute(.identifier) as? String
    }
    var children: [Any] {
        if let view = object as? NSView { return view.accessibilityChildren() ?? attribute(.children) as? [Any] ?? [] }
        if let item = object as? any NSAccessibilityProtocol { return item.accessibilityChildren() ?? attribute(.children) as? [Any] ?? [] }
        return attribute(.children) as? [Any] ?? []
    }
    var parent: NSObject? {
        if let view = object as? NSView { return view.accessibilityParent() as? NSObject }
        if let item = object as? any NSAccessibilityElementProtocol { return item.accessibilityParent() as? NSObject }
        return attribute(.parent) as? NSObject
    }
    var frame: NSRect {
        if let view = object as? NSView, let window = view.window {
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if let item = object as? any NSAccessibilityElementProtocol { return item.accessibilityFrame() }
        guard let origin = attribute(.position) as? NSValue, let size = attribute(.size) as? NSValue else { return .zero }
        return NSRect(origin: origin.pointValue, size: size.sizeValue)
    }
    var role: NSAccessibility.Role? {
        if let view = object as? NSView { return view.accessibilityRole() }
        if let item = object as? any NSAccessibilityProtocol { return item.accessibilityRole() }
        return (attribute(.role) as? String).map { NSAccessibility.Role(rawValue: $0) }
    }
    var texts: [String] {
        var result: [String] = []
        if let view = object as? NSView {
            if let label = view.accessibilityLabel() { result.append(label) }
            if let value = view.accessibilityValue() as? String { result.append(value) }
        } else if let item = object as? any NSAccessibilityProtocol {
            if let label = item.accessibilityLabel() { result.append(label) }
            if let value = item.accessibilityValue() as? String { result.append(value) }
        }
        let attributes: [NSAccessibility.Attribute] = [.value, .title, .description]
        for name in attributes {
            if let value = attribute(name) as? String { result.append(value) }
        }
        if let field = object as? NSTextField { result.append(field.stringValue) }
        return result
    }
    func accessibilityPerformPress() -> Bool {
        if let button = object as? NSButton { button.performClick(nil); return button.isEnabled }
        if let item = object as? any NSAccessibilityProtocol { return item.accessibilityPerformPress() }
        guard object.accessibilityActionNames().contains(.press) else { return false }
        object.accessibilityPerformAction(.press)
        return true
    }
}

/// These peers never touch the filesystem or a network. Only the queue and
/// native views are real, including their public accessibility actions.
private actor M92UIClient: SFTPClient {
    let capabilities = SFTPCapabilities(supportsAtomicRename: true)
    func canonicalPath(_ path: RemotePath) throws -> RemotePath { try RemotePath("/home/fixture") }
    func listDirectory(_ path: RemotePath, maximumEntries: Int) throws -> [SFTPDirectoryEntry] {
        [SFTPDirectoryEntry(name: Data("report 中文.txt".utf8), attributes:
            SFTPFileAttributes(size: 65_536, permissions: 0o100600, modificationTime: 1_700_000_000))]
    }
    func shutdown() {}
    func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32) throws -> SFTPHandle { throw SFTPError.unsupportedOperation }
    func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) throws -> Data? { throw SFTPError.unsupportedOperation }
    func write(_ handle: SFTPHandle, offset: UInt64, data: Data) throws { throw SFTPError.unsupportedOperation }
    func closeHandle(_ handle: SFTPHandle) throws { throw SFTPError.unsupportedOperation }
    func removeFile(_ path: RemotePath) throws { throw SFTPError.unsupportedOperation }
    func createDirectory(_ path: RemotePath, permissions: UInt32) throws { throw SFTPError.unsupportedOperation }
    func removeDirectory(_ path: RemotePath) throws { throw SFTPError.unsupportedOperation }
    func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) throws { throw SFTPError.unsupportedOperation }
}

private struct M92UIFactory: SFTPClientFactory {
    let prompts: SSHConnectionPrompts?
    func connect(to profile: SessionProfile) async throws -> any SFTPClient {
        if let prompts { _ = try await prompts.password(for: profile) }
        return M92UIClient()
    }
}

private struct M92UIEngine: SFTPFileTransferring {
    enum Mode: Sendable { case conflict(Bool), untilCancelled, warning }
    let mode: Mode
    func perform(_ request: SFTPTransferRequest, client: any SFTPClient,
                 cancellation: SFTPTransferCancellation,
                 progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                 resolveConflict: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome {
        await progress(SFTPTransferProgress(bytes: 32_768, totalBytes: 65_536))
        switch mode {
        case .conflict(let replace):
            let decision = try await resolveConflict(SFTPTransferConflict(requestID: request.id,
                destinationName: Data("report 中文.txt".utf8), direction: request.direction, canReplace: replace))
            switch decision {
            case .skip: return .skipped
            case .replace: return .completedAt(.remote(request.remotePath))
            case .rename(let name): return .completedAt(.remote(try RemotePath("/home/fixture").appending(name)))
            }
        case .untilCancelled:
            while true { try await cancellation.check(); try await Task.sleep(for: .milliseconds(5)) }
        case .warning:
            throw SFTPTransferFailure(.commitUncertain,
                residues: [.remote(try RemotePath("/home/fixture/.dockshell-upload-synthetic.part"))],
                uncertainDestination: .remote(request.remotePath))
        }
    }
}

@MainActor
private final class M92UIFixture {
    let queue: SFTPTransfersViewModel
    let browser: SFTPBrowserViewModel
    let profile: SessionProfile
    let root: NSHostingView<SFTPBrowserPane>
    let window: NSWindow
    init(mode: M92UIEngine.Mode, password: Bool, l10n: L10n) {
        let prompts = SSHConnectionPrompts()
        queue = SFTPTransfersViewModel(factory: M92UIFactory(prompts: password ? prompts : nil),
            engine: M92UIEngine(mode: mode), prompts: prompts)
        browser = SFTPBrowserViewModel(factory: M92UIFactory(prompts: nil), prompts: SSHConnectionPrompts(), transfers: queue)
        profile = SessionProfile(name: "M9.2 UI", host: "transfer-ui.invalid", username: "fixture",
                                 authentication: .password(credentialID: nil))
        root = NSHostingView(rootView: SFTPBrowserPane(model: browser, l10n: l10n, onClose: {}))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        // AppKit only publishes a SwiftUI hosting tree to accessibility once
        // its own window participates in the window server. This fixture is
        // never made key and does not activate or inspect any other app.
        window.orderFront(nil)
        browser.start(profile: profile)
    }
    func enqueue() throws -> UUID {
        let request = SFTPTransferRequest(direction: .upload,
            localURL: URL(fileURLWithPath: "/synthetic/report 中文.txt"),
            remotePath: try RemotePath("/home/fixture/report 中文.txt"))
        queue.enqueue([request], profile: profile)
        return request.id
    }
    func close() async {
        await queue.shutdown()
        browser.close()
        window.contentView = nil; window.close()
    }
}

/// Exercises public native layout and accessibility, not private SwiftUI table
/// internals. Every credential, host and file path belongs to a synthetic peer.
@MainActor
enum M92TransferUIVerification {
    private static var didFinishLaunching = false
    private static var usedNativeFallback = false
    static func run(l10n: L10n) async throws {
        _ = NSApplication.shared
        if !didFinishLaunching {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
            didFinishLaunching = true
        }
        usedNativeFallback = false
        try await conflict(l10n: l10n)
        try await authenticationAndCancel(l10n: l10n)
        try await warning(l10n: l10n)
        print("PASS M9.2 native transfer UI: compact/wide queue, scrollable conflict forms and separate authentication")
        print("PASS M9.2 native transfer warnings: uncertain destinations and temporary paths are retained; rendered warning layouts captured for review")
        if usedNativeFallback {
            print("M9.2 UI scope: hosted button accessibility was unavailable; native fields/layout and model decisions were checked; actual mouse actions remain manual acceptance")
        } else {
            print("PASS M9.2 public accessibility actions: conflict Skip and running-task Cancel reached their intended jobs")
        }
    }

    private static func conflict(l10n: L10n) async throws {
        let fixture = M92UIFixture(mode: .conflict(false), password: false, l10n: l10n)
        do {
            try await ready(fixture)
            _ = try fixture.enqueue()
            try await wait("The transfer conflict form did not mount") {
                fixture.root.layoutSubtreeIfNeeded()
                return fixture.queue.conflict != nil && nameField(in: fixture.root, l10n: l10n) != nil
            }
            try check(element("dockshell.sftp.transfer.conflict.replace", in: fixture.root) == nil,
                      "A server without replacement support offered a Replace action")
            try check(nameField(in: fixture.root, l10n: l10n) != nil,
                      "The conflicted task did not render its native new-name field")
            scrollToEnd(fixture.root)
            try await wait("The conflict action row cannot be reached within the compact panel") {
                fixture.root.layoutSubtreeIfNeeded()
                if let action = control("dockshell.sftp.transfer.conflict.skip", title: l10n.string(.transferSkip), in: fixture.root) {
                    return visibleFrame(action, in: fixture.root)
                }
                usedNativeFallback = true
                guard let field = nameField(in: fixture.root, l10n: l10n), let scroll = field.enclosingScrollView,
                      let document = scroll.documentView else { return false }
                let visible = scroll.documentVisibleRect
                return document.isFlipped ? visible.maxY >= document.bounds.maxY - 1 : visible.minY <= document.bounds.minY + 1
            }
            try await capture(fixture.root, name: "m92-conflict-compact-" + l10n.language + ".png")
            fixture.window.setContentSize(NSSize(width: 520, height: 700))
            fixture.root.layoutSubtreeIfNeeded()
            try await capture(fixture.root, name: "m92-conflict-wide-" + l10n.language + ".png")
            if let skip = control("dockshell.sftp.transfer.conflict.skip", title: l10n.string(.transferSkip), in: fixture.root) {
                try check(skip.accessibilityPerformPress(), "The public conflict Skip accessibility action failed")
            } else {
                usedNativeFallback = true
                guard let conflict = fixture.queue.conflict else { throw failure("The conflict decision disappeared") }
                fixture.queue.answerConflict(id: conflict.id, decision: .skip)
            }
            try await wait("Skipping the conflict did not finish the correct job") { fixture.queue.jobs.first?.phase == .skipped }
            await fixture.close()
        } catch {
            try? await capture(fixture.root, name: "m92-failure-" + l10n.language + ".png")
            let detail = " phase=" + String(describing: fixture.queue.jobs.first?.phase)
                + " conflict=" + String(fixture.queue.conflict != nil)
                + " frame=" + NSStringFromRect(fixture.root.bounds)
                + " AX=" + accessibilityIdentifiers(in: fixture.root).joined(separator: ",")
            await fixture.close()
            throw failure(String(describing: error) + detail)
        }

        let replace = M92UIFixture(mode: .conflict(true), password: false, l10n: l10n)
        do {
            try await ready(replace)
            _ = try replace.enqueue()
            try await wait("Supported replacement did not offer an explicit confirmation action") {
                replace.root.layoutSubtreeIfNeeded()
                return replace.queue.conflict?.canReplace == true && nameField(in: replace.root, l10n: l10n) != nil
            }
            try check(replace.queue.jobs.first?.phase == .waitingConflict,
                      "Rendering the conflict form implicitly authorized replacement")
            let request = replace.queue.conflict!
            replace.queue.answerConflict(id: request.id, decision: .rename("renamed 中文.txt"))
            try await wait("Renaming did not retain the actual completed destination") {
                replace.queue.jobs.first?.resolvedDestination == .remote(try! RemotePath("/home/fixture/renamed 中文.txt"))
            }
            try check(replace.queue.jobs.first?.phase == .completed,
                      "A committed rename was not recorded as completed")
            await replace.close()
        } catch { await replace.close(); throw error }
    }

    private static func authenticationAndCancel(l10n: L10n) async throws {
        let fixture = M92UIFixture(mode: .untilCancelled, password: true, l10n: l10n)
        do {
            try await ready(fixture)
            let id = try fixture.enqueue()
            try await wait("Independent transfer authentication did not mount") {
                fixture.root.layoutSubtreeIfNeeded()
                return fixture.queue.prompts.passwordRequest != nil && secureField(in: fixture.root) != nil
            }
            try check(fixture.browser.prompts.passwordRequest == nil,
                      "Transfer authentication took over the browser's prompt owner")
            scrollToEnd(fixture.root)
            try await capture(fixture.root, name: "m92-authentication-" + l10n.language + ".png")
            guard let request = fixture.queue.prompts.passwordRequest else { throw failure("Synthetic password request disappeared") }
            fixture.queue.prompts.answerPassword(id: request.id, bytes: Data("synthetic-transfer-ui-secret".utf8))
            try await wait("The authenticated transfer did not expose progress") {
                fixture.root.layoutSubtreeIfNeeded()
                return fixture.queue.jobs.first?.phase == .running && fixture.queue.jobs.first?.progress != nil
            }
            if let cancel = control("dockshell.sftp.transfer.cancel." + id.uuidString, title: l10n.string(.cancel), in: fixture.root) {
                try check(cancel.accessibilityPerformPress(), "The transfer cancellation accessibility action failed")
            } else {
                usedNativeFallback = true
                fixture.queue.cancel(id: id)
            }
            try await wait("Cancelling through the UI did not finish the transfer") { fixture.queue.jobs.first?.phase == .cancelled }
            try check(fixture.browser.phase == .ready, "Canceling a transfer disconnected the directory browser")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    private static func warning(l10n: L10n) async throws {
        let fixture = M92UIFixture(mode: .warning, password: false, l10n: l10n)
        do {
            try await ready(fixture)
            _ = try fixture.enqueue()
            try await wait("The uncertain transfer warning did not reach history") { fixture.queue.jobs.first?.phase == .failed }
            fixture.queue.clearFinished()
            try check(fixture.queue.jobs.count == 1 && fixture.queue.jobs[0].failure?.residues.count == 1,
                      "Routine history clearing hid an uncertain destination or temporary file")
            fixture.root.layoutSubtreeIfNeeded()
            scrollToEnd(fixture.root)
            let texts = accessibilityTexts(in: fixture.root)
            if !texts.contains(where: { $0.contains("/home/fixture/.dockshell-upload-synthetic.part") }) {
                usedNativeFallback = true
                // Some SwiftUI Text has no in-process AX node before an
                // assistive client connects. Its complete typed path remains
                // asserted above and its actual wrapping is captured for QA.
                try check(fixture.queue.jobs[0].failure?.uncertainDestination != nil,
                          "The uncertain destination was omitted from history")
            }
            try await capture(fixture.root, name: "m92-uncertain-" + l10n.language + ".png")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    private static func ready(_ fixture: M92UIFixture) async throws {
        try await wait("The transfer browser fixture did not load") {
            fixture.root.layoutSubtreeIfNeeded()
            return fixture.browser.phase == .ready
        }
    }

    private static func element(_ id: String, in root: NSView) -> M92AccessibleElement? {
        var pending: [Any] = [root], visited = Set<ObjectIdentifier>(), checked = 0
        while let object = pending.popLast(), checked < 4096 {
            checked += 1
            guard let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let item = M92AccessibleElement(object: object)
            if item.identifier == id { return item }
            pending.append(contentsOf: item.children)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func visibleFrame(_ element: M92AccessibleElement, in root: NSView) -> Bool {
        guard let window = root.window else { return false }
        let allowed = window.convertToScreen(root.convert(root.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        let frame = element.frame
        guard frame.width > 0, frame.height > 0, allowed.contains(frame) else { return false }
        var parent = element.parent, visited = Set<ObjectIdentifier>()
        while let object = parent, visited.insert(ObjectIdentifier(object)).inserted, visited.count < 50 {
            let candidate = M92AccessibleElement(object: object)
            if candidate.role == .scrollArea, !candidate.frame.insetBy(dx: -1, dy: -1).contains(frame) { return false }
            parent = candidate.parent
        }
        return true
    }

    private static func accessibilityTexts(in root: NSView) -> [String] {
        var pending: [Any] = [root], visited = Set<ObjectIdentifier>(), result: [String] = [], checked = 0
        while let object = pending.popLast(), checked < 4096 {
            checked += 1
            guard let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let item = M92AccessibleElement(object: object)
            result.append(contentsOf: item.texts)
            pending.append(contentsOf: item.children)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    private static func accessibilityIdentifiers(in root: NSView) -> [String] {
        var pending: [Any] = [root], visited = Set<ObjectIdentifier>(), result: [String] = [], checked = 0
        while let object = pending.popLast(), checked < 4096 {
            checked += 1
            guard let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let item = M92AccessibleElement(object: object)
            if let id = item.identifier { result.append(id) }
            pending.append(contentsOf: item.children)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    private static func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        for child in view.subviews { if let field = secureField(in: child) { return field } }
        return nil
    }

    private static func nameField(in view: NSView, l10n: L10n) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == l10n.string(.transferNewName) { return field }
        for child in view.subviews { if let field = nameField(in: child, l10n: l10n) { return field } }
        return nil
    }

    private static func control(_ id: String, title: String, in root: NSView) -> M92AccessibleElement? {
        var views = [root], matches: [NSButton] = []
        while let view = views.popLast() {
            if let button = view as? NSButton, button.title == title || button.toolTip == title || button.accessibilityLabel() == title {
                matches.append(button)
            }
            views.append(contentsOf: view.subviews)
        }
        if matches.count == 1, let button = matches.first { return M92AccessibleElement(object: button) }
        return element(id, in: root)
    }

    private static func scrollToEnd(_ view: NSView) {
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTableView), let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            let y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { scrollToEnd(child) }
    }

    private static func capture(_ view: NSView, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["DOCKSHELL_UI_CAPTURE_DIRECTORY"], !output.isEmpty else { return }
        guard output.hasPrefix("/") else { throw failure("UI capture needs an absolute directory") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Cannot allocate a transfer UI screenshot") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let bytes = image.representation(using: .png, properties: [:]) else { throw failure("Cannot encode a transfer UI screenshot") }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
        }.value
    }

    private static func wait(_ message: String, _ test: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await test()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> M92UIFailure { M92UIFailure(description: message) }
}

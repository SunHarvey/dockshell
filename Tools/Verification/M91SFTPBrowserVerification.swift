import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation
import SwiftUI

private struct M91BrowserFailure: Error, CustomStringConvertible { let description: String }

/// A controllable directory-only peer. Mutating or file-content calls are
/// counted independently, so the browser cannot silently grow transfer behavior.
private actor M91DirectoryClient: SFTPClient {
    let capabilities = SFTPCapabilities(supportsAtomicRename: false)
    private let home: RemotePath
    private var directories: [Data: [SFTPDirectoryEntry]]
    private var aliases: [Data: RemotePath] = [:]
    private var failures: [Data: SFTPError] = [:]
    private var gatedPath: Data?
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false
    private var canonicalCalls: [Data] = []
    private var listingCalls: [Data] = []
    private var cancelledListings = 0
    private var unwantedCalls = 0
    private var closed = false

    init(home: RemotePath, directories: [Data: [SFTPDirectoryEntry]]) {
        self.home = home; self.directories = directories
    }

    func canonicalPath(_ path: RemotePath) throws -> RemotePath {
        guard !closed else { throw SFTPError.connectionClosed }
        canonicalCalls.append(path.bytes)
        if path.bytes == Data(".".utf8) { return home }
        if let alias = aliases[path.bytes] { return alias }
        return try RemotePath(bytes: normalize(path.bytes))
    }

    func listDirectory(_ path: RemotePath, maximumEntries: Int) async throws -> [SFTPDirectoryEntry] {
        guard !closed else { throw SFTPError.connectionClosed }
        listingCalls.append(path.bytes)
        if path.bytes == gatedPath {
            held = true
            await withCheckedContinuation { gate = $0 }
            held = false; gatedPath = nil
        }
        if Task.isCancelled { cancelledListings += 1 }
        guard !closed else { throw SFTPError.connectionClosed }
        if let failure = failures[path.bytes] { throw failure }
        guard let result = directories[path.bytes] else { throw SFTPError.status(2) }
        guard result.count <= maximumEntries else { throw SFTPError.directoryLimit }
        return result
    }

    private func normalize(_ path: Data) -> Data {
        let base = path.first == 47 ? Data() : home.bytes + Data([47])
        var components: [Data] = []
        for part in (base + path).split(separator: 47, omittingEmptySubsequences: true) {
            let value = Data(part)
            if value == Data(".".utf8) { continue }
            if value == Data("..".utf8) { if !components.isEmpty { components.removeLast() } }
            else { components.append(value) }
        }
        return Data([47]) + components.reduce(into: Data()) { result, component in
            if !result.isEmpty { result.append(47) }; result.append(component)
        }
    }

    func setDirectory(_ path: RemotePath, entries: [SFTPDirectoryEntry]) { directories[path.bytes] = entries }
    func setFailure(_ path: RemotePath, error: SFTPError?) { failures[path.bytes] = error }
    func setAlias(_ path: RemotePath, target: RemotePath) { aliases[path.bytes] = target }
    func holdListing(_ path: RemotePath) { gatedPath = path.bytes }
    func releaseListing() { let saved = gate; gate = nil; saved?.resume() }
    func isHolding() -> Bool { held }
    func isClosed() -> Bool { closed }
    func counts() -> (canonical: [Data], listings: [Data], cancelled: Int, unwanted: Int) {
        (canonicalCalls, listingCalls, cancelledListings, unwantedCalls)
    }
    func shutdown() { closed = true; releaseListing() }

    func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32) throws -> SFTPHandle {
        unwantedCalls += 1; throw SFTPError.unsupportedOperation
    }
    func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) throws -> Data? {
        unwantedCalls += 1; throw SFTPError.unsupportedOperation
    }
    func write(_ handle: SFTPHandle, offset: UInt64, data: Data) throws {
        unwantedCalls += 1; throw SFTPError.unsupportedOperation
    }
    func closeHandle(_ handle: SFTPHandle) throws { unwantedCalls += 1; throw SFTPError.unsupportedOperation }
    func removeFile(_ path: RemotePath) throws { unwantedCalls += 1; throw SFTPError.unsupportedOperation }
    func createDirectory(_ path: RemotePath, permissions: UInt32) throws { unwantedCalls += 1; throw SFTPError.unsupportedOperation }
    func removeDirectory(_ path: RemotePath) throws { unwantedCalls += 1; throw SFTPError.unsupportedOperation }
    func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) throws {
        unwantedCalls += 1; throw SFTPError.unsupportedOperation
    }
}

/// A late connect deliberately ignores cancellation until explicitly released.
/// Product cleanup must still retire the returned client before reconnecting.
private actor M91DirectoryFactory: SFTPClientFactory {
    private let clients: [M91DirectoryClient]
    private var calls = 0
    private var holdFirst: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var connectedAfterUnclosedPrevious = false
    init(_ clients: [M91DirectoryClient], holdFirst: Bool = false) {
        self.clients = clients; self.holdFirst = holdFirst
    }
    func connect(to profile: SessionProfile) async throws -> any SFTPClient {
        let index = calls; calls += 1
        guard clients.indices.contains(index) else { throw SFTPError.connectionClosed }
        if index > 0, !(await clients[index - 1].isClosed()) { connectedAfterUnclosedPrevious = true }
        if holdFirst && index == 0 { await withCheckedContinuation { gate = $0 } }
        return clients[index]
    }
    func releaseConnect() { holdFirst = false; let saved = gate; gate = nil; saved?.resume() }
    func state() -> (calls: Int, overlap: Bool) { (calls, connectedAfterUnclosedPrevious) }
}

private actor M91PromptFactory: SFTPClientFactory {
    let prompts: SSHConnectionPrompts
    let client: M91DirectoryClient
    private var attempts = 0, accepted = 0, cancellations = 0
    init(prompts: SSHConnectionPrompts, client: M91DirectoryClient) { self.prompts = prompts; self.client = client }
    func connect(to profile: SessionProfile) async throws -> any SFTPClient {
        attempts += 1
        do {
            let value = try await prompts.password(for: profile)
            try Task.checkCancellation()
            if !value.isEmpty { accepted += 1 }
            return client
        } catch { if error is CancellationError { cancellations += 1 }; throw error }
    }
    func state() -> (attempts: Int, accepted: Int, cancellations: Int) { (attempts, accepted, cancellations) }
}

@MainActor
private final class M91WeakBrowser {
    weak var value: SFTPBrowserViewModel?
    init(_ value: SFTPBrowserViewModel) { self.value = value }
}

private struct M91NeverTerminalTransport: SSHTransport {
    func connect(to profile: SessionProfile) async throws -> any SSHConnection { throw SSHConnectionError.connectionFailed }
}

@MainActor
private final class M91TabFactory: TerminalSessionFactory {
    struct Record { let browser: SFTPBrowserViewModel; let peer: M91DirectoryClient; let factory: M91DirectoryFactory }
    private(set) var records: [Record] = []
    func makeSession() -> TerminalTabSession {
        let home = try! RemotePath("/home/tab-\(records.count)")
        let peer = M91DirectoryClient(home: home, directories: [home.bytes: []])
        let factory = M91DirectoryFactory([peer])
        let browser = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        records.append(Record(browser: browser, peer: peer, factory: factory))
        return TerminalTabSession(controller: SSHSessionController(transport: M91NeverTerminalTransport()),
                                  prompts: SSHConnectionPrompts(), files: browser)
    }
}

/// Browser verification exercises the real presentation model against controllable
/// protocol peers, without network, Keychain or changes to the user's files.
@MainActor
enum M91SFTPBrowserVerification {
    private static let profile = SessionProfile(name: "M9.1 fixture", host: "browser.invalid", username: "fixture",
                                                authentication: .password(credentialID: nil))

    static func run() async throws {
        try await verifyReadOnlyNavigationAndNames()
        try await verifyLatestIntentAndFailureRetention()
        try await verifyFailureKindsAndHomeRecovery()
        try await verifyCloseAndLateConnection()
        try await verifyPromptLifetime()
        try await verifyOwnerLifetime()
        try await verifyTabOwnership()
        print("PASS M9.1 browser: lazy independent connection, raw-byte names, directory-first filtering, read-only navigation and failure retention")
        print("PASS M9.1 browser lifecycle: latest navigation without RPC cancellation, stale authentication rejected, late connection retirement and owner cleanup")
        print("PASS M9.1 tab ownership: per-tab directory and visibility, hide/reorder without reconnect, isolated close and close-all")
    }

    private static func verifyReadOnlyNavigationAndNames() async throws {
        let home = try RemotePath("/home/fixture")
        let unicode = Data("目录 😀".utf8), invalid = Data([0xff, 0x64])
        let control = Data("line\n\u{202e}name".utf8)
        let joinedEmoji = "中文 👩‍💻"
        try check(SFTPBrowserText.display(Data(joinedEmoji.utf8)) == joinedEmoji,
                  "A joined emoji name lost its zero-width joiner during safe display")
        try check(SFTPBrowserText.display(invalid) != SFTPBrowserText.display(Data("\\xFFd".utf8)),
                  "A literal escape-looking name could impersonate non-UTF-8 filename bytes")
        let entries = [entry("z10.txt"), entry("z2.txt"), entry(".config", directory: true),
                       entry(bytes: unicode, directory: true), entry(bytes: invalid, directory: true),
                       entry(bytes: control, directory: true),
                       SFTPDirectoryEntry(name: Data("link".utf8), attributes: .init(permissions: 0o120777))]
        let children = [unicode, invalid, control]
        var directories: [Data: [SFTPDirectoryEntry]] = [home.bytes: entries, Data("/".utf8): [], Data("/home".utf8): []]
        for child in children { directories[try home.appending(bytes: child).bytes] = [] }
        let peer = M91DirectoryClient(home: home, directories: directories)
        let factory = M91DirectoryFactory([peer])
        let browser = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        defer { browser.close() }
        try check(await factory.state().calls == 0 && browser.phase == .idle, "An unopened browser authenticated eagerly")
        browser.start(profile: profile)
        try await ready(browser, at: home)
        try check(browser.entries.count == entries.count && browser.currentPathDisplay == "/home/fixture",
                  "The initial canonical directory or complete listing was lost")
        try check(!browser.visibleEntries.contains { $0.nameBytes == Data(".config".utf8) }, "Hidden entries were shown by default")
        let sorted = browser.visibleEntries
        let firstFile = sorted.firstIndex { $0.kind == .file } ?? sorted.count
        try check(sorted.dropFirst(firstFile).allSatisfy { $0.kind != .directory }, "Directories were interspersed with regular files")
        let z2 = sorted.firstIndex { $0.nameBytes == Data("z2.txt".utf8) }, z10 = sorted.firstIndex { $0.nameBytes == Data("z10.txt".utf8) }
        try check(z2 != nil && z10 != nil && z2! < z10!, "Numeric file names were not naturally ordered")
        browser.showHidden = true
        try check(browser.visibleEntries.contains { $0.nameBytes == Data(".config".utf8) }, "The hidden-files control did not expose a hidden entry")
        browser.filter = "Z2"
        try check(browser.visibleEntries.map(\.nameBytes) == [Data("z2.txt".utf8)], "The name filter failed case-insensitive matching")
        browser.filter = ""
        for name in [invalid, control] {
            guard let item = browser.entries.first(where: { $0.nameBytes == name }) else { throw failure("A raw name vanished") }
            try check(!item.displayName.contains("\n") && !item.displayName.contains("\u{202e}") && !item.displayName.isEmpty,
                      "An untrusted name inserted controls or bidirectional overrides into the browser")
        }
        for child in children {
            guard let item = browser.entries.first(where: { $0.nameBytes == child }) else { throw failure("A raw directory was missing") }
            browser.open(item)
            let expected = try home.appending(bytes: child)
            try await ready(browser, at: expected)
            try check(browser.entries.isEmpty, "An empty directory was not represented as a successful empty listing")
            browser.goHome()
            try await ready(browser, at: home)
        }
        let linked = try RemotePath("/shared")
        let linkPath = try home.appending("link")
        await peer.setAlias(linkPath, target: linked)
        await peer.setDirectory(linked, entries: [])
        guard let link = browser.entries.first(where: { $0.kind == .symlink }) else { throw failure("A symbolic directory link was missing") }
        browser.open(link); try await ready(browser, at: linked)
        browser.goHome(); try await ready(browser, at: home)
        guard let regular = browser.entries.first(where: { $0.nameBytes == Data("z2.txt".utf8) }) else { throw failure("A regular file was missing") }
        let before = await peer.counts()
        browser.open(regular)
        await Task.yield()
        let after = await peer.counts()
        try check(browser.currentPath == home && before.canonical == after.canonical && before.listings == after.listings,
                  "Opening a regular file performed navigation or loaded file contents")
        browser.goUp(); try await ready(browser, at: RemotePath("/home"))
        browser.goUp(); try await ready(browser, at: RemotePath("/"))
        try check(!browser.canGoUp, "The root directory offered an invalid parent")
        try check(await peer.counts().unwanted == 0, "The read-only browser invoked a transfer or mutation method")
    }

    private static func verifyLatestIntentAndFailureRetention() async throws {
        let home = try RemotePath("/home/fixture"), first = try RemotePath("/a"), skipped = try RemotePath("/b"), last = try RemotePath("/c")
        let denied = try RemotePath("/denied")
        let peer = M91DirectoryClient(home: home, directories: [home.bytes: [entry("original")], first.bytes: [], skipped.bytes: [], last.bytes: [entry("latest")]])
        await peer.setFailure(denied, error: .status(3))
        let browser = SFTPBrowserViewModel(factory: M91DirectoryFactory([peer]), prompts: SSHConnectionPrompts())
        defer { browser.close() }
        browser.start(profile: profile); try await ready(browser, at: home)
        await peer.holdListing(first)
        browser.navigate(to: "/a")
        try await wait("The controlled navigation did not reach its peer") { await peer.isHolding() }
        browser.navigate(to: "/b"); browser.navigate(to: "/c")
        try check(browser.currentPath == home && browser.entries.first?.nameBytes == Data("original".utf8),
                  "A pending navigation overwrote the last successful directory")
        await peer.releaseListing()
        try await ready(browser, at: last)
        let calls = await peer.counts()
        try check(calls.cancelled == 0 && !calls.listings.contains(skipped.bytes) && browser.entries.first?.nameBytes == Data("latest".utf8),
                  "Rapid navigation cancelled an RPC or displayed an obsolete intermediate directory")
        let snapshot = browser.entries
        browser.navigate(to: "/denied")
        try await wait("A denied directory did not become a visible operation error") { browser.error != nil && !browser.isLoading }
        try check(browser.currentPath == last && browser.entries.map(\.nameBytes) == snapshot.map(\.nameBytes),
                  "A denied navigation erased or relabeled the successful directory")
        browser.navigate(to: "bad\0path")
        try await wait("An invalid path did not finish") { !browser.isLoading }
        try check(browser.error != nil && browser.currentPath == last, "An invalid path was silently ignored or changed directories")
        let count = (await peer.counts()).canonical.count
        browser.refresh()
        try await wait("Refresh did not fetch the successful directory again") {
            let requests = await peer.counts()
            return !browser.isLoading && requests.canonical.count > count
        }
        let refreshed = await peer.counts()
        try check(browser.currentPath == last && browser.error == nil && refreshed.unwanted == 0,
                  "Refresh failed to recover a directory-only browser")
    }

    private static func verifyCloseAndLateConnection() async throws {
        let home = try RemotePath("/home/fixture")
        let first = M91DirectoryClient(home: home, directories: [home.bytes: []])
        let second = M91DirectoryClient(home: home, directories: [home.bytes: []])
        let factory = M91DirectoryFactory([first, second], holdFirst: true)
        let browser = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        defer { browser.close() }
        browser.start(profile: profile)
        try await wait("The first lazy connection did not start") { await factory.state().calls == 1 }
        browser.reconnect()
        await Task.yield()
        try check(await factory.state().calls == 1, "Reconnect overlapped a cancelled connect which still owned resources")
        await factory.releaseConnect()
        try await ready(browser, at: home)
        let state = await factory.state()
        let firstClosed = await first.isClosed(), secondClosed = await second.isClosed()
        try check(state.calls == 2 && !state.overlap && firstClosed && !secondClosed,
                  "A late client was leaked, reused, or not retired before reconnect")
        browser.close()
        try await wait("Closing a ready browser retained its SFTP client") { await second.isClosed() }
        try check(browser.phase == .idle && !browser.isLoading, "Closing a browser left an active presentation")
    }

    private static func verifyFailureKindsAndHomeRecovery() async throws {
        let home = try RemotePath("/home/fixture")
        let first = M91DirectoryClient(home: home, directories: [home.bytes: [entry("after-permission-recovery")]])
        let replacement = M91DirectoryClient(home: home, directories: [home.bytes: [entry("after-reconnect")]])
        await first.setFailure(home, error: .status(3))
        let factory = M91DirectoryFactory([first, replacement])
        let browser = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        defer { browser.close() }
        browser.start(profile: profile)
        try await wait("A rejected initial listing left the browser loading indefinitely") {
            browser.phase == .ready && !browser.isLoading && browser.error != nil
        }
        try check(browser.homePath == home && browser.currentPath == home && browser.entries.isEmpty,
                  "A denied initial directory lost the canonical home needed for retry")
        await first.setFailure(home, error: nil)
        browser.refresh()
        try await wait("The initial permission failure could not recover through refresh") {
            !browser.isLoading && browser.error == nil && browser.entries.first?.nameBytes == Data("after-permission-recovery".utf8)
        }
        await first.setFailure(home, error: .connectionClosed)
        browser.refresh()
        try await wait("A closed SFTP channel did not produce an explicit disconnected browser") {
            browser.phase == .failed && !browser.isLoading
        }
        try check(browser.entries.first?.nameBytes == Data("after-permission-recovery".utf8) && browser.error != nil,
                  "A connection loss hid its error or discarded the prior directory context")
        browser.start(profile: profile)
        await Task.yield()
        try check(await factory.state().calls == 1, "Reopening a failed panel silently retried authentication")
        browser.reconnect()
        try await ready(browser, at: home)
        try check(browser.entries.first?.nameBytes == Data("after-reconnect".utf8), "Explicit reconnect did not replace the disconnected directory client")
    }

    private static func verifyPromptLifetime() async throws {
        let home = try RemotePath("/home/fixture")
        let client = M91DirectoryClient(home: home, directories: [home.bytes: []])
        let prompts = SSHConnectionPrompts()
        let factory = M91PromptFactory(prompts: prompts, client: client)
        let browser = SFTPBrowserViewModel(factory: factory, prompts: prompts)
        defer { browser.close() }
        browser.start(profile: profile)
        try await wait("The browser did not expose its own password decision") { prompts.passwordRequest != nil }
        let staleID = prompts.passwordRequest!.id
        browser.reconnect()
        try await wait("Reconnect did not replace its cancelled password decision") {
            prompts.passwordRequest.map { $0.id != staleID } ?? false
        }
        let newID = prompts.passwordRequest!.id
        prompts.answerPassword(id: staleID, bytes: Data("synthetic-obsolete".utf8))
        try check(prompts.passwordRequest?.id == newID, "An obsolete answer consumed a new browser's credential request")
        prompts.answerPassword(id: newID, bytes: Data("synthetic-current".utf8))
        try await ready(browser, at: home)
        let state = await factory.state()
        try check(state.attempts == 2 && state.accepted == 1 && state.cancellations == 1,
                  "Browser authentication retried unexpectedly or retained a cancelled credential request")
    }

    private static func verifyOwnerLifetime() async throws {
        let home = try RemotePath("/home/fixture")
        let peer = M91DirectoryClient(home: home, directories: [home.bytes: []])
        let factory = M91DirectoryFactory([peer], holdFirst: true)
        var browser: SFTPBrowserViewModel? = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        let reference = M91WeakBrowser(browser!)
        browser!.start(profile: profile)
        try await wait("The lifetime fixture did not reach its connect suspension") { await factory.state().calls == 1 }
        browser = nil
        try await wait("An in-flight connect retained its dropped browser owner") { reference.value == nil }
        await factory.releaseConnect()
        try await wait("A late connection outlived its dropped browser owner") { await peer.isClosed() }
    }

    private static func verifyTabOwnership() async throws {
        let factory = M91TabFactory(), tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let firstID = tabs.open(profile: profile, settings: .defaults)
        let secondID = tabs.open(profile: profile, settings: .defaults)
        let first = factory.records[0], second = factory.records[1]
        let firstInitial = await first.factory.state(), secondInitial = await second.factory.state()
        try check(firstInitial.calls == 0 && secondInitial.calls == 0,
                  "Opening terminal tabs started SFTP connections eagerly")
        tabs.toggleSelectedFiles()
        try await ready(second.browser, at: RemotePath("/home/tab-1"))
        tabs.select(id: firstID)
        try check(!tabs.showsSelectedFiles && first.browser.phase == .idle,
                  "Selecting another terminal displayed the previous tab's file session")
        tabs.toggleSelectedFiles()
        try await ready(first.browser, at: RemotePath("/home/tab-0"))
        tabs.hideFiles(id: firstID)
        let hiddenClosed = await first.peer.isClosed()
        try check(!tabs.showsSelectedFiles && !hiddenClosed, "Hiding files closed a tab's directory session")
        tabs.toggleSelectedFiles()
        tabs.move(id: firstID, to: 1)
        let visibleCalls = await first.factory.state().calls
        try check(tabs.selectedID == firstID && tabs.showsSelectedFiles && visibleCalls == 1,
                  "Showing or reordering an existing browser created another SFTP connection")
        tabs.close(id: firstID)
        try await wait("Closing one tab did not retire its own SFTP session") { await first.peer.isClosed() }
        let survivorClosed = await second.peer.isClosed()
        try check(tabs.selectedID == secondID && tabs.showsSelectedFiles && !survivorClosed,
                  "Closing one tab disturbed another tab's file connection or visibility")
        tabs.closeAll()
        try await wait("Closing the workspace left its remaining SFTP session alive") { await second.peer.isClosed() }
    }

    private static func entry(_ name: String, directory: Bool = false) -> SFTPDirectoryEntry {
        entry(bytes: Data(name.utf8), directory: directory)
    }
    private static func entry(bytes: Data, directory: Bool) -> SFTPDirectoryEntry {
        SFTPDirectoryEntry(name: bytes, attributes: .init(size: directory ? nil : 12,
            permissions: directory ? 0o040755 : 0o100644, modificationTime: 1_700_000_000))
    }
    private static func ready(_ browser: SFTPBrowserViewModel, at path: RemotePath) async throws {
        try await wait("The browser did not finish loading its expected directory") {
            browser.phase == .ready && !browser.isLoading && browser.currentPath == path
        }
    }
    private static func wait(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> M91BrowserFailure { M91BrowserFailure(description: message) }
}

private actor M91UISettings: SettingsRepository {
    private var value = TerminalSettings.defaults
    func load() -> TerminalSettings { value }
    func save(_ settings: TerminalSettings) { value = settings }
}

private actor M91UIChannel: SSHSessionChannel {
    private let output = BoundedTerminalChannel()
    private var lastResize = TerminalSize(columns: 80, rows: 24)
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws { guard !closed else { throw SSHConnectionError.connectionFailed } }
    func resize(to size: TerminalSize) { lastResize = size }
    func close() async { closed = true; await output.close() }
    func size() -> TerminalSize { lastResize }
}

private actor M91UIConnection: SSHConnection {
    let channel = M91UIChannel()
    private var closed = false
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }; return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
}

private actor M91UITransport: SSHTransport {
    let connection = M91UIConnection()
    private var calls = 0
    func connect(to profile: SessionProfile) -> any SSHConnection { calls += 1; return connection }
    func count() -> Int { calls }
}

@MainActor
private final class M91UITabFactory: TerminalSessionFactory {
    struct Record {
        let session: TerminalTabSession
        let transport: M91UITransport
        let peer: M91DirectoryClient
        let factory: M91DirectoryFactory
    }
    private(set) var records: [Record] = []
    func makeSession() -> TerminalTabSession {
        let home = try! RemotePath("/home/ui-\(records.count)")
        let child = try! home.appending("中文目录")
        let peer = M91DirectoryClient(home: home, directories: [home.bytes: [
            SFTPDirectoryEntry(name: Data("中文目录".utf8), attributes: .init(permissions: 0o040755)),
            SFTPDirectoryEntry(name: Data("README.md".utf8), attributes: .init(size: 2048, permissions: 0o100644, modificationTime: 1_700_000_000)),
            SFTPDirectoryEntry(name: Data("backup.tar.gz".utf8), attributes: .init(size: 1_073_741_824, permissions: 0o100600, modificationTime: 1_700_000_000))
        ], child.bytes: [
            SFTPDirectoryEntry(name: Data("中文说明 👩‍💻.txt".utf8), attributes: .init(size: 128, permissions: 0o100644, modificationTime: 1_700_000_000))
        ]])
        let factory = M91DirectoryFactory([peer]), transport = M91UITransport()
        let files = SFTPBrowserViewModel(factory: factory, prompts: SSHConnectionPrompts())
        let session = TerminalTabSession(controller: SSHSessionController(transport: transport),
            prompts: SSHConnectionPrompts(), files: files)
        records.append(Record(session: session, transport: transport, peer: peer, factory: factory))
        return session
    }
}

/// Actual SwiftUI/AppKit surfaces verify that opening a file panel changes
/// geometry, without replacing terminal views or starting additional SSH sessions.
@MainActor
enum M91SFTPBrowserUIVerification {
    static func run(l10n: L10n) async throws {
        _ = NSApplication.shared
        let factory = M91UITabFactory(), tabs = TerminalTabsViewModel(factory: factory)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: M91UISettings()))
        await settings.load()
        let profile = SessionProfile(name: "M9.1 UI", host: "browser-ui.invalid", username: "fixture", authentication: .agent)
        let first = tabs.open(profile: profile, settings: settings.settings)
        let second = tabs.open(profile: profile, settings: settings.settings)
        let root = NSHostingView(rootView: TerminalTabsPane(model: tabs, settings: settings, l10n: l10n))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { tabs.closeAll(); window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        try await wait("Browser UI fixture did not mount both real terminals") {
            root.layoutSubtreeIfNeeded()
            return factory.records.allSatisfy { $0.session.controller.phase == .connected }
                && factory.records.allSatisfy { terminal(in: root, controller: $0.session.controller) != nil }
        }
        guard let grid = identified(in: root, id: "dockshell.terminal-grid") else { throw failure("The persistent terminal grid was missing") }
        let gridIdentity = ObjectIdentifier(grid)
        let terminals = factory.records.compactMap { terminal(in: root, controller: $0.session.controller) }
        let identities = terminals.map(ObjectIdentifier.init)
        let parents = terminals.map { $0.superview.map(ObjectIdentifier.init) }
        tabs.toggleSelectedFiles()
        try await wait("Opening files did not mount the selected browser") {
            root.layoutSubtreeIfNeeded()
            return tabs.selectedID == second && factory.records[1].session.files?.phase == .ready
                && identified(in: root, id: "dockshell.sftp.panel-host") != nil
        }
        try checkStableTerminals(root: root, records: factory.records, identities: identities, parents: parents, grid: gridIdentity)
        try await checkGeometry(root: root, records: factory.records, visible: true)
        try await wait("The browser did not mount a native directory table") {
            root.layoutSubtreeIfNeeded()
            guard let panel = identified(in: root, id: "dockshell.sftp.panel-host"), let table = firstTable(in: panel) else { return false }
            return table.numberOfRows > 0
        }
        try await setFileWidth(520, columns: 3, root: root)
        try await checkGeometry(root: root, records: factory.records, visible: true)
        try checkStableTerminals(root: root, records: factory.records, identities: identities, parents: parents, grid: gridIdentity)
        try await capture(root, name: "m91-browser-wide-" + l10n.language + ".png")
        try await setFileWidth(380, columns: 2, root: root)
        try await checkGeometry(root: root, records: factory.records, visible: true)
        tabs.select(id: first)
        try await wait("A tab with an unopened browser retained another tab's panel") {
            root.layoutSubtreeIfNeeded()
            return identified(in: root, id: "dockshell.sftp.panel-host") == nil
        }
        tabs.toggleSelectedFiles()
        let firstHome = try RemotePath("/home/ui-0"), firstChild = try firstHome.appending("中文目录")
        try await wait("The first tab's independent browser did not connect") { factory.records[0].session.files?.phase == .ready }
        factory.records[0].session.files?.navigate(to: firstChild.utf8String!)
        try await wait("The first tab's browse directory was not retained") { factory.records[0].session.files?.currentPath == firstChild }
        tabs.select(id: second)
        try await wait("Switching tabs did not preserve the second browser directory") {
            root.layoutSubtreeIfNeeded()
            return factory.records[1].session.files?.currentPath?.utf8String == "/home/ui-1"
                && identified(in: root, id: "dockshell.sftp.panel-host") != nil
        }
        tabs.setArrangement(.horizontal)
        try await checkGeometry(root: root, records: factory.records, visible: true)
        try checkStableTerminals(root: root, records: factory.records, identities: identities, parents: parents, grid: gridIdentity)
        tabs.hideFiles(id: second)
        try await wait("Hiding files left its native panel mounted") {
            root.layoutSubtreeIfNeeded()
            return identified(in: root, id: "dockshell.sftp.panel-host") == nil
        }
        tabs.select(id: first)
        try await wait("Returning to the first browser lost its directory") {
            root.layoutSubtreeIfNeeded()
            return factory.records[0].session.files?.currentPath == firstChild
                && identified(in: root, id: "dockshell.sftp.panel-host") != nil
        }
        window.setContentSize(NSSize(width: 800, height: 540))
        try await checkGeometry(root: root, records: factory.records, visible: true)
        try checkStableTerminals(root: root, records: factory.records, identities: identities, parents: parents, grid: gridIdentity)
        try await capture(root, name: "m91-browser-compact-" + l10n.language + ".png")
        for record in factory.records {
            let terminalCalls = await record.transport.count(), fileCalls = await record.factory.state().calls
            try check(terminalCalls == 1 && fileCalls == 1,
                      "File panel presentation reconnected a terminal or existing browser")
        }
        tabs.closeAll()
        try await wait("Browser UI teardown retained its file or terminal connections") {
            for record in factory.records {
                let fileClosed = await record.peer.isClosed(), terminalClosed = await record.transport.connection.isClosed()
                if !fileClosed || !terminalClosed { return false }
            }
            return true
        }
        print("PASS M9.1 native browser UI: right-hand panel, per-tab directory, compact resize and terminal parent/view preservation")
        print("PASS M9.1 native browser lifecycle: tab/hide/tile switches keep one terminal and file connection; teardown closes all owned sessions")
    }

    private static func checkGeometry(root: NSView, records: [M91UITabFactory.Record], visible: Bool) async throws {
        try await wait("The file panel or resized terminals did not fit the workspace") {
            root.layoutSubtreeIfNeeded()
            guard let split = identified(in: root, id: "dockshell.sftp.workspace") as? NSSplitView else { return false }
            if visible {
                guard let panel = identified(in: root, id: "dockshell.sftp.panel-host"),
                      split.convert(panel.bounds, from: panel).maxX <= split.bounds.maxX + 1,
                      panel.bounds.width >= 359, panel.bounds.height > 100,
                      split.arrangedSubviews.count == 2 else { return false }
            }
            for record in records {
                guard let view = terminal(in: root, controller: record.session.controller), let surface = view as? any TerminalSurface else { return false }
                let size = await record.transport.connection.channel.size()
                if surface.terminalSize != size { return false }
            }
            return true
        }
    }

    private static func setFileWidth(_ width: CGFloat, columns: Int, root: NSView) async throws {
        guard let split = identified(in: root, id: "dockshell.sftp.workspace") as? NSSplitView else {
            throw failure("The browser split view was missing")
        }
        split.setPosition(split.bounds.maxX - width - split.dividerThickness, ofDividerAt: 0)
        try await wait("Resizing the browser did not expose its expected metadata columns") {
            root.layoutSubtreeIfNeeded()
            guard let panel = identified(in: root, id: "dockshell.sftp.panel-host"),
                  let table = firstTable(in: panel) else { return false }
            return abs(panel.bounds.width - width) <= 2 && table.numberOfColumns == columns
        }
    }

    private static func checkStableTerminals(root: NSView, records: [M91UITabFactory.Record], identities: [ObjectIdentifier],
                                             parents: [ObjectIdentifier?], grid: ObjectIdentifier) throws {
        try check(identified(in: root, id: "dockshell.terminal-grid").map(ObjectIdentifier.init) == grid,
                  "A file panel switch replaced the persistent terminal grid")
        for (index, record) in records.enumerated() {
            guard let view = terminal(in: root, controller: record.session.controller) else { throw failure("A file panel switch removed a terminal") }
            try check(ObjectIdentifier(view) == identities[index] && view.superview.map(ObjectIdentifier.init) == parents[index],
                      "A file panel switch replaced or reparented a terminal surface")
        }
    }
    private static func terminal(in view: NSView, controller: SSHSessionController) -> NSView? {
        if let surface = view as? any TerminalSurface, controller.isAttached(to: surface) { return view }
        for child in view.subviews { if let found = terminal(in: child, controller: controller) { return found } }
        return nil
    }
    private static func identified(in view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = identified(in: child, id: id) { return found } }
        return nil
    }
    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = firstTable(in: child) { return found } }
        return nil
    }
    private static func capture(_ view: NSView, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DOCKSHELL_UI_CAPTURE_DIRECTORY"], !path.isEmpty else { return }
        guard path.hasPrefix("/") else { throw failure("UI capture requires an absolute output directory") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw failure("The isolated browser view could not create a screenshot representation")
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw failure("The isolated browser screenshot could not be encoded")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        }.value
    }
    private static func wait(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> M91BrowserFailure { M91BrowserFailure(description: message) }
}

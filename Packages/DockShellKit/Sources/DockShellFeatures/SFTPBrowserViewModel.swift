import Combine
import DockShellDomain
import Foundation

public enum SFTPBrowserPhase: Sendable, Equatable {
    case idle, connecting, ready, failed
}

/// Only typed application/protocol failures reach the presentation. Arbitrary
/// server text and process diagnostics are never retained by the browser.
public enum SFTPBrowserError: Error, Sendable {
    case invalidPath
    case connection(any Error)
    case operation(any Error)
}

public enum SFTPBrowserEntryKind: Sendable, Equatable {
    case directory, file, symlink, other, unknown
}

/// A name is identified by its original bytes, not its escaped display text.
/// Display escaping never changes which remote child a navigation opens.
public struct SFTPBrowserEntry: Identifiable, Hashable, Sendable {
    public let nameBytes: Data
    public let displayName: String
    public let attributes: SFTPFileAttributes
    public let kind: SFTPBrowserEntryKind
    public var id: Data { nameBytes }
    public var isHidden: Bool { nameBytes.first == 46 }
    public var canOpen: Bool { kind == .directory || kind == .symlink || kind == .unknown }

    public init(_ entry: SFTPDirectoryEntry) {
        nameBytes = entry.name
        displayName = SFTPBrowserText.display(entry.name)
        attributes = entry.attributes
        switch entry.attributes.permissions.map({ $0 & 0o170000 }) {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symlink
        case nil, 0: kind = .unknown
        default: kind = .other
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.nameBytes == rhs.nameBytes && lhs.attributes == rhs.attributes
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(nameBytes) }
}

/// One-line, unambiguous display for untrusted remote names and paths. A literal
/// backslash is escaped too, so it cannot imitate an escaped control byte.
public enum SFTPBrowserText {
    public static func display(_ bytes: Data) -> String {
        guard let string = String(data: bytes, encoding: .utf8) else {
            return bytes.map { byte in
                if byte == 92 { return "\\\\" }
                if (32...126).contains(byte) { return String(Unicode.Scalar(byte)) }
                return String(format: "\\x%02X", byte)
            }.joined()
        }
        return string.unicodeScalars.map { scalar in
            if scalar.value == 92 { return "\\\\" }
            // Joining characters are needed for emoji and connected scripts;
            // bidi controls and the remaining invisible formats stay escaped.
            if scalar.value == 0x200c || scalar.value == 0x200d { return String(scalar) }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return scalar.value <= 255 ? String(format: "\\x%02X", scalar.value)
                    : "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: return String(scalar)
            }
        }.joined()
    }
}

/// One tab's lazily opened, read-only file connection. Navigation is serialized:
/// a newer intent replaces the queued intent without canceling an in-flight RPC
/// (SFTP v3 cancellation would retire the entire file session).
@MainActor
public final class SFTPBrowserViewModel: ObservableObject {
    public let prompts: SSHConnectionPrompts
    public let transfers: SFTPTransfersViewModel?
    @Published public private(set) var profile: SessionProfile?
    @Published public private(set) var phase: SFTPBrowserPhase = .idle
    @Published public private(set) var isLoading = false
    @Published public private(set) var currentPath: RemotePath?
    @Published public private(set) var homePath: RemotePath?
    @Published public private(set) var entries: [SFTPBrowserEntry] = []
    @Published public private(set) var error: SFTPBrowserError?
    @Published public var showHidden = false
    @Published public var filter = ""

    private let factory: any SFTPClientFactory
    private var client: (any SFTPClient)?
    private var connectionTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var generation = UUID()
    private var latestIntent = UUID()
    private struct Navigation { let id: UUID; let path: RemotePath }
    private var queuedNavigation: Navigation?
    private var transferObservation: AnyCancellable?

    public init(factory: any SFTPClientFactory, prompts: SSHConnectionPrompts, transfers: SFTPTransfersViewModel? = nil) {
        self.factory = factory
        self.prompts = prompts
        self.transfers = transfers
        transferObservation = transfers?.$completedRevision.dropFirst().sink { [weak self] _ in
            guard let self, self.canNavigate,
                  self.transfers?.jobs.last(where: { $0.phase == .completed })?.request.direction == .upload else { return }
            self.refresh()
        }
    }

    public var currentPathDisplay: String { currentPath.map { SFTPBrowserText.display($0.bytes) } ?? "" }
    public var canNavigate: Bool { phase == .ready && client != nil }
    public var canGoUp: Bool { currentPath.map { $0.bytes != Data([47]) } ?? false }
    public var visibleEntries: [SFTPBrowserEntry] {
        entries.filter { (showHidden || !$0.isHidden) && (filter.isEmpty || $0.displayName.localizedStandardContains(filter)) }
    }

    /// Reopening a hidden panel never reauthenticates an existing or failed file
    /// connection. A failed connection requires the explicit reconnect action.
    public func start(profile: SessionProfile) {
        guard self.profile != profile || phase == .idle else { return }
        let changed = self.profile != profile
        self.profile = profile
        if changed { currentPath = nil; homePath = nil; entries = []; filter = "" }
        beginConnection(profile: profile)
    }

    public func reconnect() {
        guard let profile else { return }
        beginConnection(profile: profile)
    }

    public func navigate(to path: String) {
        guard canNavigate else { return }
        do {
            let raw = Data(path.utf8)
            guard !raw.isEmpty else { throw SFTPError.invalidPath }
            let target: RemotePath
            if raw.first == 47 { target = try RemotePath(bytes: raw) }
            else if let currentPath { target = try Self.join(currentPath, raw) }
            else { target = try RemotePath(bytes: raw) }
            enqueue(target)
        } catch { self.error = .invalidPath }
    }

    /// Directory links and unknown types are attempted as directories. Regular
    /// files are never downloaded, read, executed or opened by M9.1.
    public func open(_ entry: SFTPBrowserEntry) {
        guard canNavigate, entry.canOpen, entries.contains(where: { $0.nameBytes == entry.nameBytes }),
              let currentPath else { return }
        do { enqueue(try currentPath.appending(bytes: entry.nameBytes)) }
        catch { self.error = .invalidPath }
    }

    public func goUp() {
        guard canNavigate, let currentPath, canGoUp else { return }
        do { enqueue(try currentPath.appending("..")) }
        catch { self.error = .invalidPath }
    }

    public func goHome() { if canNavigate, let homePath { enqueue(homePath) } }
    public func refresh() { if canNavigate, let path = currentPath ?? homePath { enqueue(path) } }
    public func dismissError() { error = nil }

    /// Ends only this tab's file connection and any pending file-authentication
    /// decisions. The owning terminal session is never accessed here.
    public func close() {
        stop()
        phase = .idle; isLoading = false; error = nil
    }

    private func beginConnection(profile: SessionProfile) {
        stop()
        phase = .connecting; isLoading = true; error = nil
        let token = generation, factory = factory, closing = closeTask
        let previousPath = currentPath
        connectionTask = Task { [weak self] in
            var connected: (any SFTPClient)?
            var resolvedHome: RemotePath?
            do {
                await closing?.value
                try Task.checkCancellation()
                let client = try await factory.connect(to: profile)
                connected = client
                guard !Task.isCancelled, self?.generation == token else { await client.shutdown(); return }
                self?.client = client
                let home = try await client.canonicalPath(RemotePath("."))
                guard home.bytes.first == 47 else { throw SFTPError.invalidPacket }
                resolvedHome = home
                let listing = try await Self.load(client: client, path: previousPath ?? home)
                guard !Task.isCancelled, self?.generation == token else { await client.shutdown(); return }
                self?.homePath = home
                self?.apply(listing)
                self?.phase = .ready
            } catch {
                guard !Task.isCancelled, self?.generation == token else { await connected?.shutdown(); return }
                if let resolvedHome, !Self.isFatal(error), connected != nil {
                    self?.homePath = resolvedHome
                    if self?.currentPath == nil { self?.currentPath = resolvedHome }
                    self?.phase = .ready
                    self?.error = .operation(Self.sanitized(error))
                } else {
                    await connected?.shutdown()
                    guard self?.generation == token else { return }
                    self?.client = nil
                    self?.phase = .failed
                    self?.error = .connection(Self.sanitized(error))
                }
            }
            if self?.generation == token { self?.isLoading = false; self?.connectionTask = nil }
        }
    }

    private func enqueue(_ path: RemotePath) {
        guard let client, canNavigate else { return }
        let intent = UUID()
        latestIntent = intent
        queuedNavigation = Navigation(id: intent, path: path)
        error = nil; isLoading = true
        guard navigationTask == nil else { return }
        let token = generation
        navigationTask = Task { [weak self, client] in
            while let job = self?.takeNavigation(token: token) {
                do {
                    let listing = try await Self.load(client: client, path: job.path)
                    guard !Task.isCancelled, self?.generation == token else { return }
                    if self?.latestIntent == job.id { self?.apply(listing) }
                } catch {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    if Self.isFatal(error) {
                        self?.queuedNavigation = nil
                        self?.client = nil
                        self?.phase = .failed
                        self?.error = .connection(Self.sanitized(error))
                        await client.shutdown()
                        break
                    }
                    if self?.latestIntent == job.id { self?.error = .operation(Self.sanitized(error)) }
                }
            }
            if self?.generation == token { self?.isLoading = false; self?.navigationTask = nil }
        }
    }

    private func takeNavigation(token: UUID) -> Navigation? {
        guard generation == token, !Task.isCancelled else { return nil }
        let next = queuedNavigation
        queuedNavigation = nil
        return next
    }

    private struct Listing: Sendable { let path: RemotePath; let entries: [SFTPBrowserEntry] }

    private nonisolated static func load(client: any SFTPClient, path: RemotePath) async throws -> Listing {
        let canonical = try await client.canonicalPath(path)
        guard canonical.bytes.first == 47 else { throw SFTPError.invalidPacket }
        let entries = try await client.listDirectory(canonical, maximumEntries: 10_000)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            guard entries.count <= 10_000 else { throw SFTPError.directoryLimit }
            var seen = Set<Data>(), retained = 0
            var result: [SFTPBrowserEntry] = []
            for entry in entries {
                guard !entry.name.isEmpty, entry.name.count <= 32_768,
                      !entry.name.contains(0), !entry.name.contains(47) else {
                    throw SFTPError.invalidPacket
                }
                if entry.name == Data([46]) || entry.name == Data([46, 46]) { continue }
                retained += entry.name.count + 64
                guard retained <= 4_194_304 else { throw SFTPError.directoryLimit }
                // A directory can change between READDIR pages. Show the first
                // occurrence once rather than exposing duplicate SwiftUI IDs.
                if seen.insert(entry.name).inserted { result.append(SFTPBrowserEntry(entry)) }
            }
            result.sort {
                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.nameBytes.lexicographicallyPrecedes($1.nameBytes) : order == .orderedAscending
            }
            return Listing(path: canonical, entries: result)
        }.value
    }

    private func apply(_ listing: Listing) { currentPath = listing.path; entries = listing.entries }

    private nonisolated static func join(_ base: RemotePath, _ relative: Data) throws -> RemotePath {
        try RemotePath(bytes: base.bytes + (base.bytes.last == 47 ? Data() : Data([47])) + relative)
    }

    private nonisolated static func isFatal(_ error: any Error) -> Bool {
        guard let error = error as? SFTPError else { return true }
        switch error {
        case .invalidPath, .invalidArgument, .invalidHandle, .requestLimit, .directoryLimit, .unsupportedOperation: return false
        case .status(let code): return code == 6 || code == 7
        default: return true
        }
    }

    private nonisolated static func sanitized(_ error: any Error) -> any Error {
        if let error = error as? SFTPError { return error }
        if let error = error as? SSHConnectionError { return error }
        if let error = error as? HostTrustError { return error }
        if let error = error as? SSHAuthenticationError { return error }
        if let error = error as? DockShellError { return error }
        return SFTPError.connectionClosed
    }

    private func stop() {
        generation = UUID(); latestIntent = UUID(); queuedNavigation = nil
        prompts.cancelAll()
        let connecting = connectionTask, navigating = navigationTask, client = client, closing = closeTask
        connecting?.cancel(); navigating?.cancel()
        connectionTask = nil; navigationTask = nil; self.client = nil
        closeTask = Task {
            await closing?.value
            await client?.shutdown()
            await connecting?.value
            await navigating?.value
        }
    }

    deinit {
        connectionTask?.cancel(); navigationTask?.cancel()
        let connecting = connectionTask, navigating = navigationTask, client = client, closing = closeTask
        let prompts = prompts
        let transfers = transfers
        Task { @MainActor in
            transfers?.close()
            prompts.cancelAll()
            await closing?.value
            await client?.shutdown()
            await connecting?.value
            await navigating?.value
        }
    }
}

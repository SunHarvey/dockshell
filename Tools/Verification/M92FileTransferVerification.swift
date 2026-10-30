import CryptoKit
import Darwin
import DockShellApplication
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M92TransferTestFailure: Error, CustomStringConvertible { let description: String }

/// Real transfer logic and real disposable local files, with a deterministic
/// remote filesystem. No personal server, credentials, or application data.
enum M92FileTransferVerification {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DockShell-M92-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await roundtrip(root)
        try await conflicts(root)
        try await cancellation(root)
        try await failures(root)
        try await localSafety(root)
        print("PASS M9.2 transfer engine: bounded binary/empty roundtrip, short reads, raw names and acknowledged progress")
        print("PASS transfer naming: automatic upload replacement, numbered downloads, no-clobber races and no leftover temporary files")
        print("PASS M9.2 local files: regular sources, symlink/FIFO rejection, changed sources and no-clobber destination races")
    }

    private static var engine: SFTPFileTransferEngine { SFTPFileTransferEngine(localFiles: SystemSFTPTransferLocalFiles()) }
    private static func bytes() -> Data { Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) }) }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M92TransferTestFailure(description: message) }
    }
    private static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    private static func perform(_ request: SFTPTransferRequest, peer: any SFTPClient,
                                token: SFTPTransferCancellation = SFTPTransferCancellation(),
                                progress: @escaping @Sendable (SFTPTransferProgress) async -> Void = { _ in },
                                decision: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision = { _ in
                                    throw M92TransferTestFailure(description: "The default transfer policy unexpectedly requested a filename decision")
                                }
    ) async throws -> SFTPTransferOutcome {
        try await engine.perform(request, client: peer, cancellation: token, progress: progress, resolveConflict: decision)
    }

    private static func roundtrip(_ root: URL) async throws {
        let body = bytes(), source = root.appendingPathComponent("source.bin"), destination = root.appendingPathComponent("download.bin")
        try body.write(to: source)
        let path = try RemotePath(bytes: Data("/remote/中文-".utf8) + Data([0xff, 0x61]))
        let peer = M92TransferPeer(), progress = M92Progress()
        _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: path), peer: peer,
                              progress: { await progress.record($0) })
        try check(await peer.data(path) == body, "Upload changed the exact binary data")
        _ = try await perform(SFTPTransferRequest(direction: .download, localURL: destination, remotePath: path), peer: peer)
        let received = try Data(contentsOf: destination)
        try check(received.count == body.count && hash(received) == hash(body), "Short-read download changed the binary file")
        try check(await progress.valid(total: UInt64(body.count)), "Upload progress was not acknowledged and monotonic")
        let stats = await peer.statistics()
        try check(stats.maximumRead <= 32_768 && stats.maximumWrite <= 32_768 && stats.peak <= 4,
                  "Transfer IO exceeded its four bounded chunks")
        try check(await peer.temporaryNames().isEmpty, "Successful upload retained a temporary remote file")
        let zero = root.appendingPathComponent("empty-source"), zeroOut = root.appendingPathComponent("empty-download")
        try Data().write(to: zero)
        let zeroPath = try RemotePath("/remote/empty")
        _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: zero, remotePath: zeroPath), peer: peer)
        _ = try await perform(SFTPTransferRequest(direction: .download, localURL: zeroOut, remotePath: zeroPath), peer: peer)
        try check(try Data(contentsOf: zeroOut).isEmpty, "Empty-file transfer did not commit an empty file")
    }

    private static func conflicts(_ root: URL) async throws {
        let source = root.appendingPathComponent("conflict-source"), new = Data("replacement".utf8), old = Data("preserve me".utf8)
        try new.write(to: source)
        let target = try RemotePath("/remote/existing")
        let peer = M92TransferPeer(); await peer.put(target, data: old)
        _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: target), peer: peer)
        try check(await peer.data(target) == new, "Same-name upload did not replace its destination automatically")
        try check(await peer.temporaryNames().isEmpty, "Automatic replacement retained remote staging data")
        let unsupported = M92TransferPeer(atomic: false); await unsupported.put(target, data: old)
        try await failure(.remote(.unsupportedOperation)) {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: target), peer: unsupported)
        }
        try check(await unsupported.data(target) == old, "A missing atomic capability damaged the existing file")
        let newOnly = M92TransferPeer(atomic: false)
        _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: target), peer: newOnly)
        try check(await newOnly.data(target) == new, "A server without replacement support rejected a new filename")
        let folder = root.appendingPathComponent("numbered-downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let local = folder.appendingPathComponent("报告 👩‍💻.txt")
        for name in ["报告 👩‍💻.txt", "报告 👩‍💻 (1).txt", "报告 👩‍💻 (2).txt"] {
            let outcome = try await perform(SFTPTransferRequest(direction: .download, localURL: local, remotePath: target), peer: peer)
            guard case .completedAt(.local(let actual)) = outcome else {
                throw M92TransferTestFailure(description: "Numbered download did not report its actual completed destination")
            }
            try check(actual.lastPathComponent == name, "Repeated download did not allocate the next filename")
            try check(try Data(contentsOf: folder.appendingPathComponent(name)) == new, "Numbered download changed content")
            try noLocalTemporary(folder)
        }
        // Gaps, dotfiles, extensionless names and maximum-length UTF-8 names.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("报告 👩‍💻 (1).txt"))
        let gap = try await perform(SFTPTransferRequest(direction: .download, localURL: local, remotePath: target), peer: peer)
        guard case .completedAt(.local(let gapURL)) = gap else { throw M92TransferTestFailure(description: "Gap copy did not complete") }
        try check(gapURL.lastPathComponent == "报告 👩‍💻 (1).txt", "Download failed to reuse a free copy number")
        for original in ["README", ".env", String(repeating: "中", count: 83) + ".txt"] {
            let selected = folder.appendingPathComponent(original)
            try old.write(to: selected)
            let outcome = try await perform(SFTPTransferRequest(direction: .download, localURL: selected, remotePath: target), peer: peer)
            guard case .completedAt(.local(let actual)) = outcome else { throw M92TransferTestFailure(description: "Named copy did not complete") }
            try check(actual.lastPathComponent.utf8.count <= 255 && actual.lastPathComponent.contains(" (1)"),
                      "A numbered Unicode filename exceeded the filesystem limit or lost its number")
            try check(try Data(contentsOf: actual) == new && (try Data(contentsOf: selected)) == old,
                      "A named copy replaced the original or changed its payload")
        }
        try noLocalTemporary(folder)
        let parallelFolder = root.appendingPathComponent("parallel-copies")
        try FileManager.default.createDirectory(at: parallelFolder, withIntermediateDirectories: false)
        let gate = M92CommitGate(), parallelTarget = parallelFolder.appendingPathComponent("same.txt")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    _ = try await perform(SFTPTransferRequest(direction: .download, localURL: parallelTarget, remotePath: target), peer: peer,
                        progress: { if $0.stage == .committing { await gate.arrive() } })
                }
            }
            try await group.waitForAll()
        }
        for name in ["same.txt", "same (1).txt"] {
            try check(try Data(contentsOf: parallelFolder.appendingPathComponent(name)) == new,
                      "Parallel downloads overwrote each other or saved incomplete content")
        }
        try noLocalTemporary(parallelFolder)
    }

    private static func cancellation(_ root: URL) async throws {
        let body = bytes(), old = Data("original before cancellation".utf8), path = try RemotePath("/remote/cancel")
        let source = root.appendingPathComponent("cancel-source"); try body.write(to: source)
        for direction in [SFTPTransferDirection.upload, .download] {
            let peer = M92TransferPeer(); await peer.put(path, data: direction == .upload ? old : body)
            let local = direction == .upload ? source : root.appendingPathComponent("cancel-download")
            if direction == .download { try old.write(to: local) }
            let token = SFTPTransferCancellation()
            try await failure(.cancelled) {
                _ = try await perform(SFTPTransferRequest(direction: direction, localURL: local, remotePath: path), peer: peer, token: token,
                    progress: { event in if event.stage == .transferring && event.bytes > 0 { await token.requestCancellation() } },
                    decision: { _ in .replace })
            }
            if direction == .upload { try check(await peer.data(path) == old, "Cancel changed the final remote target") }
            else {
                try check(try Data(contentsOf: local) == old, "Cancel changed the final local target")
                try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel-download (1)").path),
                          "Cancellation left an incomplete numbered download")
            }
            try check(await peer.temporaryNames().isEmpty, "Cooperative cancel did not remove remote staging")
            try noLocalTemporary(root)
        }
    }

    private static func failures(_ root: URL) async throws {
        let source = root.appendingPathComponent("failure-source"), body = bytes(), old = Data("original".utf8)
        try body.write(to: source)
        let path = try RemotePath("/remote/failure")
        let changed = M92TransferPeer(); await changed.put(path, data: old)
        let once = M92Once()
        try await failure(.sourceChanged) {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: path), peer: changed,
                progress: { event in
                    if event.stage == .transferring && event.bytes > 0, await once.claim() { try? Data([1]).write(to: source) }
                }, decision: { _ in .replace })
        }
        try check(await changed.data(path) == old, "A changed upload source replaced the target")
        try check(await changed.temporaryNames().isEmpty, "Changed-source upload retained its temporary file")
        try body.write(to: source)
        let lostOpen = M92TransferPeer(lostOpen: true)
        let possible = try await failure(.remote(.connectionClosed)) {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: path), peer: lostOpen)
        }
        let possibleTemporary = await lostOpen.temporaryNames()
        try check(possible?.residues.isEmpty == false && !possibleTemporary.isEmpty,
                  "Lost OPEN handle discarded the possibly-created temporary location")
        let forced = M92TransferPeer(); await forced.put(path, data: old)
        let token = SFTPTransferCancellation()
        let forcedResult = try await failure(.cancelled) {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: path), peer: forced, token: token,
                progress: { event in
                    if event.stage == .transferring && event.bytes > 0 {
                        await token.requestCancellation()
                        await forced.shutdown()
                    }
                }, decision: { _ in .replace })
        }
        let preservedForcedTarget = await forced.data(path)
        try check(forcedResult?.residues.isEmpty == false && preservedForcedTarget == old,
                  "Forced cancellation hid its residue or changed the final target")
        let lost = M92TransferPeer(lostCommit: true); await lost.put(path, data: old)
        let uncertain = try await failure(.commitUncertain) {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: path), peer: lost, decision: { _ in .replace })
        }
        try check(uncertain?.uncertainDestination == .remote(path) && uncertain?.residues.isEmpty == false,
                  "Lost commit reply was reported as definite failure or lost its possible residue")
        try check(await lost.data(path) == body, "The uncertain-commit fixture did not actually commit before losing the reply")
        try check(await lost.removedFinal() == false, "Uncertain commit tried deleting the final destination")
        let mutable = M92TransferPeer(changedAfterRead: true); await mutable.put(path, data: body)
        let download = root.appendingPathComponent("changed-remote"); try old.write(to: download)
        try await failure(.sourceChanged) {
            _ = try await perform(SFTPTransferRequest(direction: .download, localURL: download, remotePath: path), peer: mutable, decision: { _ in .replace })
        }
        try check(try Data(contentsOf: download) == old, "A changed remote source replaced the local target")
        try noLocalTemporary(root)
    }

    private static func localSafety(_ root: URL) async throws {
        let files = SystemSFTPTransferLocalFiles(), real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try Data("real".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try await failure(.unsupportedFile) { _ = try await files.openSource(link) }
        let fifo = root.appendingPathComponent("fifo")
        try check(mkfifo(fifo.path, 0o600) == 0, "Could not create a disposable FIFO")
        try await failure(.unsupportedFile) { _ = try await files.openSource(fifo) }
        let race = root.appendingPathComponent("race-target"), body = Data("download".utf8), concurrent = Data("concurrently created".utf8)
        let path = try RemotePath("/remote/race"), peer = M92TransferPeer(); await peer.put(path, data: body)
        let raced = try await perform(SFTPTransferRequest(direction: .download, localURL: race, remotePath: path), peer: peer,
            progress: { event in if event.stage == .committing { try? concurrent.write(to: race) } })
        try check(try Data(contentsOf: race) == concurrent, "No-clobber commit replaced a concurrently created target")
        guard case .completedAt(.local(let racedURL)) = raced else { throw M92TransferTestFailure(description: "Raced download did not complete") }
        try check(racedURL.lastPathComponent == "race-target (1)" && (try Data(contentsOf: racedURL)) == body,
                  "A commit-time filename collision did not retry using a numbered copy")
        // A closed, synced stage can be committed again after a rename error.
        let retryFolder = root.appendingPathComponent("retry-stage")
        try FileManager.default.createDirectory(at: retryFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let retry = try await files.prepareDestination(retryFolder.appendingPathComponent("first.bin"))
        try await retry.write(body, offset: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: retryFolder.path)
        do {
            try await retry.commit(replacing: nil)
            throw M92TransferTestFailure(description: "A readonly test directory accepted a rename")
        } catch SFTPTransferError.localPermission { }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retryFolder.path)
        try await retry.selectName("second.bin")
        try await retry.commit(replacing: nil)
        try check(await retry.discard(), "Retried commit did not finish its temporary cleanup")
        try check(try Data(contentsOf: retryFolder.appendingPathComponent("second.bin")) == body,
                  "Retrying an already closed stage lost its data")
        try noLocalTemporary(retryFolder)
        let selected = root.appendingPathComponent("swapped-target")
        let writer = try await files.prepareDestination(selected)
        try await writer.write(body, offset: 0)
        let temporary = await writer.temporaryURL()
        try FileManager.default.removeItem(at: temporary)
        try concurrent.write(to: temporary)
        do {
            try await writer.commit(replacing: nil)
            throw M92TransferTestFailure(description: "A substituted temporary inode was committed")
        } catch is SFTPTransferError { }
        try check(!(await writer.discard()), "Cleanup claimed ownership of a substituted temporary inode")
        try check(!FileManager.default.fileExists(atPath: selected.path) && (try Data(contentsOf: temporary)) == concurrent,
                  "Temporary substitution changed the destination or removed another inode")
        try FileManager.default.removeItem(at: temporary)
        try noLocalTemporary(root)
    }

    /// This helper is called only inside the existing generated-key local sshd
    /// fixture. Both the remote names and local directory belong to this test.
    static func verifyReal(client: any SFTPClient, directory: RemotePath, root: URL) async throws {
        let local = root.appendingPathComponent("m92-real-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source.bin"), output = local.appendingPathComponent("download.bin"), body = bytes()
        let remote = try directory.appending("M92-中文 😀-" + UUID().uuidString + ".bin")
        try body.write(to: source)
        do {
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: remote), peer: client)
            let info = try await client.attributes(of: remote, followSymbolicLinks: false)
            try check(info.size == UInt64(body.count) && info.permissions.map { $0 & 0o170000 == 0o100000 } == true,
                      "Real upload lost its size or regular-file metadata")
            _ = try await perform(SFTPTransferRequest(direction: .download, localURL: output, remotePath: remote), peer: client)
            try check(hash(try Data(contentsOf: output)) == hash(body), "Real transfer engine roundtrip changed bytes")
            let replacement = Data("second version 中文".utf8); try replacement.write(to: source)
            _ = try await perform(SFTPTransferRequest(direction: .upload, localURL: source, remotePath: remote), peer: client)
            for name in ["download (1).bin", "download (2).bin"] {
                let outcome = try await perform(SFTPTransferRequest(direction: .download, localURL: output, remotePath: remote), peer: client)
                guard case .completedAt(.local(let actual)) = outcome else { throw M92TransferTestFailure(description: "Real numbered download did not complete") }
                try check(actual.lastPathComponent == name && (try Data(contentsOf: actual)) == replacement,
                          "Real numbered download saved the wrong name or data")
            }
            try check(hash(try Data(contentsOf: output)) == hash(body), "Repeated download overwrote the existing original")
            try noLocalTemporary(local)
            try await client.removeFile(remote)
        } catch {
            try? await client.removeFile(remote)
            throw error
        }
        print("PASS real transfer naming: generated-host SSH, automatic upload replacement, numbered repeat downloads and staging cleanup")
    }

    @discardableResult
    private static func failure(_ expected: SFTPTransferError, action: () async throws -> Void) async throws -> SFTPTransferFailure? {
        do { try await action() }
        catch let failure as SFTPTransferFailure { try check(failure.reason == expected, "Transfer returned a different sanitized failure: \(failure.reason)"); return failure }
        catch let error as SFTPTransferError { try check(error == expected, "Local transfer returned a different typed failure: \(error)"); return nil }
        throw M92TransferTestFailure(description: "Transfer did not reject \(expected)")
    }
    private static func noLocalTemporary(_ root: URL) throws {
        try check(!FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".dockshell-download-") }),
                  "Local transfer cleanup left an owned temporary file")
    }
}

private actor M92Once { private var used = false; func claim() -> Bool { if used { return false }; used = true; return true } }
private actor M92CommitGate {
    private var arrivals = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func arrive() async {
        arrivals += 1
        if arrivals == 2 { release() }
        else {
            await withTaskCancellationHandler {
                guard !Task.isCancelled else { return }
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { waiting = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
    }
    private func release() { waiting?.resume(); waiting = nil }
}
private actor M92Progress {
    var events: [SFTPTransferProgress] = []
    func record(_ event: SFTPTransferProgress) { events.append(event) }
    func valid(total: UInt64) -> Bool {
        var previous: UInt64 = 0
        for event in events { if event.bytes < previous || event.bytes > total || event.totalBytes != total { return false }; previous = event.bytes }
        return previous == total && events.last?.stage == .committing
    }
}

private actor M92TransferPeer: SFTPClient {
    let capabilities: SFTPCapabilities
    private let sessionID = UUID(), lostCommit: Bool, changedAfterRead: Bool, lostOpen: Bool
    private var files: [Data: Data] = [:], handles: [Data: Data] = [:]
    private var reads = 0, active = 0, peak = 0, maximumRead = 0, maximumWrite = 0
    private var didRemoveFinal = false
    private var closed = false
    init(atomic: Bool = true, lostCommit: Bool = false, changedAfterRead: Bool = false, lostOpen: Bool = false) {
        capabilities = SFTPCapabilities(supportsAtomicRename: atomic)
        self.lostCommit = lostCommit; self.changedAfterRead = changedAfterRead; self.lostOpen = lostOpen
    }
    func put(_ path: RemotePath, data: Data) { files[path.bytes] = data }
    func data(_ path: RemotePath) -> Data? { files[path.bytes] }
    func statistics() -> (maximumRead: Int, maximumWrite: Int, peak: Int) { (maximumRead, maximumWrite, peak) }
    func removedFinal() -> Bool { didRemoveFinal }
    func temporaryNames() -> [Data] { files.keys.filter { String(decoding: $0, as: UTF8.self).contains(".dockshell-upload-") } }
    private func attrs(_ path: Data) throws -> SFTPFileAttributes {
        guard !closed else { throw SFTPError.connectionClosed }
        guard let data = files[path] else { throw SFTPError.status(2) }
        return SFTPFileAttributes(size: UInt64(data.count) + (changedAfterRead && reads > 0 ? 1 : 0), userID: 501, groupID: 20,
            permissions: 0o100600, accessTime: reads > 0 ? 1_700_000_001 : 1_700_000_000, modificationTime: 1_700_000_000)
    }
    func attributes(of path: RemotePath, followSymbolicLinks: Bool) async throws -> SFTPFileAttributes { try attrs(path.bytes) }
    func attributes(of handle: SFTPHandle) async throws -> SFTPFileAttributes { try attrs(try scoped(handle)) }
    private func scoped(_ handle: SFTPHandle) throws -> Data {
        guard !closed else { throw SFTPError.connectionClosed }
        guard handle.sessionID == sessionID, let path = handles[handle.bytes] else { throw SFTPError.invalidHandle }; return path
    }
    func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32) async throws -> SFTPHandle {
        guard !closed else { throw SFTPError.connectionClosed }
        if options.contains(.exclusive) && files[path.bytes] != nil { throw SFTPError.status(4) }
        if options.contains(.create) { files[path.bytes] = Data() }
        if lostOpen && options.contains(.create) { throw SFTPError.connectionClosed }
        guard files[path.bytes] != nil else { throw SFTPError.status(2) }
        let key = Data(UUID().uuidString.utf8); handles[key] = path.bytes
        return SFTPHandle(sessionID: sessionID, bytes: key)
    }
    func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) async throws -> Data? {
        let path = try scoped(handle); maximumRead = max(maximumRead, maximumBytes)
        active += 1; peak = max(peak, active); defer { active -= 1 }
        await Task.yield()
        reads += 1
        let bytes = files[path]!
        guard offset < bytes.count else { return nil }
        let at = Int(offset), end = min(bytes.count, at + min(maximumBytes, 2111))
        return Data(bytes[at..<end])
    }
    func write(_ handle: SFTPHandle, offset: UInt64, data: Data) async throws {
        let path = try scoped(handle); maximumWrite = max(maximumWrite, data.count)
        active += 1; peak = max(peak, active); defer { active -= 1 }
        await Task.yield()
        var bytes = files[path]!
        let end = Int(offset) + data.count
        if end > bytes.count { bytes.append(Data(count: end - bytes.count)) }
        bytes.replaceSubrange(Int(offset)..<end, with: data); files[path] = bytes
    }
    func closeHandle(_ handle: SFTPHandle) async throws { _ = try scoped(handle); handles.removeValue(forKey: handle.bytes) }
    func removeFile(_ path: RemotePath) async throws {
        guard !closed else { throw SFTPError.connectionClosed }
        if !String(decoding: path.bytes, as: UTF8.self).contains(".dockshell-upload-") { didRemoveFinal = true }
        guard files.removeValue(forKey: path.bytes) != nil else { throw SFTPError.status(2) }
    }
    func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) async throws {
        guard !closed else { throw SFTPError.connectionClosed }
        guard let value = files[source.bytes] else { throw SFTPError.status(2) }
        if files[destination.bytes] != nil && !replaceExisting { throw SFTPError.status(4) }
        if replaceExisting && !capabilities.supportsAtomicRename { throw SFTPError.unsupportedOperation }
        files[destination.bytes] = value; files.removeValue(forKey: source.bytes)
        if lostCommit { throw SFTPError.connectionClosed }
    }
    func canonicalPath(_ path: RemotePath) async throws -> RemotePath { path }
    func listDirectory(_ path: RemotePath, maximumEntries: Int) async throws -> [SFTPDirectoryEntry] { throw SFTPError.unsupportedOperation }
    func createDirectory(_ path: RemotePath, permissions: UInt32) async throws { throw SFTPError.unsupportedOperation }
    func removeDirectory(_ path: RemotePath) async throws { throw SFTPError.unsupportedOperation }
    func shutdown() async { closed = true; handles.removeAll() }
}

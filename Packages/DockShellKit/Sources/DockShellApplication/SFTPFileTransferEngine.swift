import DockShellDomain
import Foundation

/// Bounded file transfers with four in-flight chunks, acknowledged progress and
/// same-directory staging. Final targets are changed only at the commit step.
public struct SFTPFileTransferEngine: SFTPFileTransferring {
    private let localFiles: any SFTPTransferLocalFiles
    public init(localFiles: any SFTPTransferLocalFiles) { self.localFiles = localFiles }

    public func perform(_ request: SFTPTransferRequest, client: any SFTPClient,
                        cancellation: SFTPTransferCancellation,
                        progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                        resolveConflict: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome {
        guard request.remotePath.bytes.first == 47, request.localURL.isFileURL,
              request.localURL.path.hasPrefix("/") else { throw SFTPTransferFailure(.invalidPath) }
        switch request.direction {
        case .upload:
            return try await upload(request, client: client, cancellation: cancellation,
                                    progress: progress, resolve: resolveConflict)
        case .download:
            return try await download(request, client: client, cancellation: cancellation,
                                      progress: progress, resolve: resolveConflict)
        }
    }

    private func upload(_ request: SFTPTransferRequest, client: any SFTPClient,
                        cancellation: SFTPTransferCancellation,
                        progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                        resolve: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome {
        let source = try await localFiles.openSource(request.localURL)
        var temporary: RemotePath?
        var ownsTemporary = false
        var handle: SFTPHandle?
        var commitStarted = false
        var destination = request.remotePath
        var total: UInt64 = 0, completed: UInt64 = 0
        do {
            try await check(cancellation)
            let original = try await source.metadata()
            guard original.isRegular else { throw SFTPTransferError.unsupportedFile }
            total = original.size
            let capabilities = await client.capabilities
            var replacing: SFTPFileAttributes?
            let initial = try await chooseRemote(destination, request: request, client: client,
                canReplace: capabilities.supportsAtomicRename, cancellation: cancellation, resolve: resolve)
            guard let initial else { await source.close(); return .skipped }
            destination = initial.0; replacing = initial.1
            try await check(cancellation)
            let parent = try parent(of: destination)
            let temp = try parent.appending(".dockshell-upload-" + UUID().uuidString + ".part")
            temporary = temp
            let opened: SFTPHandle
            do { opened = try await client.openFile(temp, options: .exclusiveCreate, permissions: 0o600) }
            catch {
                // A failed OPEN status proves no new handle; lost transport
                // may mean the file was created but its HANDLE never arrived.
                if isDefiniteRemoteFailure(error) { temporary = nil }
                throw error
            }
            ownsTemporary = true; handle = opened
            let chunk = min(32_768, capabilities.maximumWriteBytes)
            guard chunk > 0 else { throw SFTPTransferError.remote(.invalidPacket) }
            await progress(SFTPTransferProgress(bytes: 0, totalBytes: total))
            var offset: UInt64 = 0
            while offset < total {
                try await check(cancellation)
                var batch: [(UInt64, Data)] = []
                for _ in 0..<4 where offset < total {
                    let amount = Int(min(UInt64(chunk), total - offset))
                    guard let bytes = try await source.read(maxBytes: amount), !bytes.isEmpty,
                          bytes.count <= amount else { throw SFTPTransferError.sourceChanged }
                    batch.append((offset, bytes)); offset += UInt64(bytes.count)
                }
                // Cancellation is checked between batches. Cancelling a child
                // RPC would retire the session before normal temporary cleanup.
                try await withThrowingTaskGroup(of: UInt64.self) { group in
                    for (position, bytes) in batch {
                        group.addTask {
                            try await client.write(opened, offset: position, data: bytes)
                            return UInt64(bytes.count)
                        }
                    }
                    for try await bytes in group {
                        completed += bytes
                        await progress(SFTPTransferProgress(bytes: completed, totalBytes: total))
                    }
                }
            }
            guard try await source.read(maxBytes: 1) == nil, try await source.metadata() == original else {
                throw SFTPTransferError.sourceChanged
            }
            let remote = try await client.attributes(of: opened)
            guard remote.size == total, regular(remote) else { throw SFTPTransferError.sourceChanged }
            try await client.closeHandle(opened); handle = nil
            await source.close()
            try await check(cancellation)
            // Reassess at commit: a target may have appeared while uploading.
            let current = try await remoteAttributes(destination, client: client)
            if current != replacing {
                let revised = try await chooseRemote(destination, request: request, client: client,
                    canReplace: capabilities.supportsAtomicRename, cancellation: cancellation, resolve: resolve)
                guard let revised else {
                    try await client.removeFile(temp); temporary = nil
                    return .skipped
                }
                destination = revised.0; replacing = revised.1
            }
            try await check(cancellation)
            await progress(SFTPTransferProgress(bytes: total, totalBytes: total, stage: .committing))
            try await check(cancellation)
            commitStarted = true
            try await client.rename(temp, to: destination, replaceExisting: replacing != nil)
            temporary = nil
            return .completedAt(.remote(destination))
        } catch {
            if let handle { try? await client.closeHandle(handle) }
            await source.close()
            let uncertain = commitStarted && !isDefiniteRemoteFailure(error)
            var residues: [SFTPTransferLocation] = []
            if let temporary {
                await progress(SFTPTransferProgress(bytes: completed, totalBytes: total, stage: .cleaning))
                if uncertain || !ownsTemporary { residues.append(.remote(temporary)) }
                else {
                    do { try await client.removeFile(temporary) }
                    catch SFTPError.status(2) { }
                    catch { residues.append(.remote(temporary)) }
                }
            }
            let wasCancelled = await cancellation.isCancelled() || Task.isCancelled
            let reason: SFTPTransferError = uncertain ? .commitUncertain : wasCancelled ? .cancelled : sanitized(error)
            throw SFTPTransferFailure(reason, residues: residues,
                uncertainDestination: uncertain ? .remote(destination) : nil)
        }
    }

    private func download(_ request: SFTPTransferRequest, client: any SFTPClient,
                          cancellation: SFTPTransferCancellation,
                          progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                          resolve: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome {
        var destination: (any SFTPTransferDestination)?
        var handle: SFTPHandle?
        var total: UInt64 = 0, completed: UInt64 = 0
        do {
            try await check(cancellation)
            let pathInfo = try await client.attributes(of: request.remotePath, followSymbolicLinks: false)
            guard regular(pathInfo) else { throw SFTPTransferError.unsupportedFile }
            let opened = try await client.openFile(request.remotePath, options: .read, permissions: 0)
            handle = opened
            let original = try await client.attributes(of: opened)
            guard regular(original), let size = original.size, size <= UInt64(Int64.max) else {
                throw SFTPTransferError.unsupportedFile
            }
            total = size
            try await check(cancellation)
            let local = try await localFiles.prepareDestination(request.localURL)
            destination = local
            guard let replacing = try await chooseLocal(local, request: request, cancellation: cancellation, resolve: resolve) else {
                try await client.closeHandle(opened); handle = nil
                guard await local.discard() else { throw SFTPTransferFailure(.localIO, residues: [.local(await local.temporaryURL())]) }
                return .skipped
            }
            let capabilities = await client.capabilities
            let chunk = min(32_768, capabilities.maximumReadBytes)
            guard chunk > 0 else { throw SFTPTransferError.remote(.invalidPacket) }
            await progress(SFTPTransferProgress(bytes: 0, totalBytes: total))
            var offset: UInt64 = 0
            while offset < total {
                try await check(cancellation)
                var ranges: [(UInt64, Int)] = []
                for _ in 0..<4 where offset < total {
                    let count = Int(min(UInt64(chunk), total - offset))
                    ranges.append((offset, count)); offset += UInt64(count)
                }
                try await withThrowingTaskGroup(of: UInt64.self) { group in
                    for (position, count) in ranges {
                        group.addTask {
                            var at = position
                            let end = position + UInt64(count)
                            while at < end {
                                guard let bytes = try await client.read(opened, offset: at, maximumBytes: Int(end - at)),
                                      !bytes.isEmpty, UInt64(bytes.count) <= end - at else {
                                    throw SFTPTransferError.sourceChanged
                                }
                                try await local.write(bytes, offset: at)
                                at += UInt64(bytes.count)
                            }
                            return UInt64(count)
                        }
                    }
                    for try await count in group {
                        completed += count
                        await progress(SFTPTransferProgress(bytes: completed, totalBytes: total))
                    }
                }
            }
            guard try await client.read(opened, offset: total, maximumBytes: 1) == nil else { throw SFTPTransferError.sourceChanged }
            let final = try await client.attributes(of: opened)
            // Reading can legitimately update atime. Size and mtime describe
            // content stability; v3 cannot provide an atomic source snapshot.
            guard final.size == original.size, final.modificationTime == original.modificationTime,
                  regular(final) else { throw SFTPTransferError.sourceChanged }
            try await client.closeHandle(opened); handle = nil
            try await check(cancellation)
            await progress(SFTPTransferProgress(bytes: total, totalBytes: total, stage: .committing))
            try await check(cancellation)
            try await local.commit(replacing: replacing.value)
            guard await local.discard() else { throw SFTPTransferError.localIO }
            return .completedAt(.local(await local.currentURL()))
        } catch {
            if let handle { try? await client.closeHandle(handle) }
            var residues = (error as? SFTPTransferFailure)?.residues ?? []
            if let destination {
                await progress(SFTPTransferProgress(bytes: completed, totalBytes: total, stage: .cleaning))
                if !(await destination.discard()) { residues.append(.local(await destination.temporaryURL())) }
            }
            let wasCancelled = await cancellation.isCancelled() || Task.isCancelled
            let reason: SFTPTransferError = wasCancelled ? .cancelled : sanitized(error)
            throw SFTPTransferFailure(reason, residues: Array(Set(residues)))
        }
    }

    private struct LocalChoice { let value: SFTPTransferLocalMetadata? }
    private func chooseLocal(_ destination: any SFTPTransferDestination, request: SFTPTransferRequest,
                             cancellation: SFTPTransferCancellation,
                             resolve: @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> LocalChoice? {
        for _ in 0..<100 {
            try await check(cancellation)
            guard let existing = try await destination.inspect() else { return LocalChoice(value: nil) }
            let url = await destination.currentURL()
            let decision = try await resolve(SFTPTransferConflict(requestID: request.id,
                destinationName: Data(url.lastPathComponent.utf8), direction: .download, canReplace: existing.isRegular))
            switch decision {
            case .skip: return nil
            case .replace:
                guard existing.isRegular else { throw SFTPTransferError.unsupportedFile }
                return LocalChoice(value: existing)
            case .rename(let name): try await destination.selectName(name)
            }
        }
        throw SFTPTransferError.destinationChanged
    }

    private func chooseRemote(_ first: RemotePath, request: SFTPTransferRequest, client: any SFTPClient,
                              canReplace: Bool, cancellation: SFTPTransferCancellation,
                              resolve: @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> (RemotePath, SFTPFileAttributes?)? {
        var path = first
        let parent = try parent(of: first)
        for _ in 0..<100 {
            try await check(cancellation)
            guard let existing = try await remoteAttributes(path, client: client) else { return (path, nil) }
            let allowed = canReplace && regular(existing)
            switch try await resolve(SFTPTransferConflict(requestID: request.id,
                destinationName: Data(path.bytes.split(separator: 47).last ?? Data.SubSequence()),
                direction: .upload, canReplace: allowed)) {
            case .skip: return nil
            case .replace:
                guard allowed else { throw SFTPTransferError.remote(.unsupportedOperation) }
                return (path, existing)
            case .rename(let name):
                guard validName(name) else { throw SFTPTransferError.invalidPath }
                path = try parent.appending(name)
            }
        }
        throw SFTPTransferError.destinationChanged
    }

    private func remoteAttributes(_ path: RemotePath, client: any SFTPClient) async throws -> SFTPFileAttributes? {
        do { return try await client.attributes(of: path, followSymbolicLinks: false) }
        catch SFTPError.status(2) { return nil }
    }
    private func parent(of path: RemotePath) throws -> RemotePath {
        guard let last = path.bytes.lastIndex(of: 47), last < path.bytes.count - 1 else { throw SFTPTransferError.invalidPath }
        let component = Data(path.bytes[(last + 1)...])
        guard component != Data(".".utf8), component != Data("..".utf8) else { throw SFTPTransferError.invalidPath }
        return try RemotePath(bytes: last == 0 ? Data([47]) : Data(path.bytes[..<last]))
    }
    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
    private func regular(_ attrs: SFTPFileAttributes) -> Bool { attrs.permissions.map { $0 & 0o170000 == 0o100000 } ?? false }
    private func check(_ token: SFTPTransferCancellation) async throws { try Task.checkCancellation(); try await token.check() }
    private func isDefiniteRemoteFailure(_ error: any Error) -> Bool {
        if let value = error as? SFTPError, case .status = value { return true }; return false
    }
    private func sanitized(_ error: any Error) -> SFTPTransferError {
        if let failure = error as? SFTPTransferFailure { return failure.reason }
        if let value = error as? SFTPTransferError { return value }
        if let value = error as? SFTPError { return .remote(value) }
        if error is CancellationError { return .cancelled }
        return .localIO
    }
}

import Darwin
import DockShellDomain
import Foundation

/// Owns an OpenSSH-compatible known_hosts file, with atomic full-key approval and a cross-process lock.
/// It never reads or changes the user's ~/.ssh/known_hosts or accepts a changed key implicitly.
public actor OpenSSHHostKeyStore: HostKeyTrustStore {
    private let url: URL
    private static let header = "# DockShell known_hosts v1\n"
    private static let maximumFileSize = 1_048_576

    public init(url: URL) { self.url = url }

    public func knownKeys(for endpoint: SSHHostEndpoint) throws -> [SSHHostKey] {
        try withLockedFile { records in records[endpoint] ?? [] }
    }

    public func approve(_ keys: [SSHHostKey], for endpoint: SSHHostEndpoint) throws {
        guard !keys.isEmpty, keys.count <= 8, Set(keys).count == keys.count else {
            throw HostTrustError.invalidKey
        }
        try withLockedFile { records in
            if let previous = records[endpoint] {
                guard Set(previous) == Set(keys) else { throw HostTrustError.hostKeyChanged }
                return
            }
            var updated = records
            updated[endpoint] = Self.sorted(keys)
            try write(updated)
        }
    }

    public func knownHostsFileURL() throws -> URL {
        try withLockedFile { _ in
            if !FileManager.default.fileExists(atPath: url.path) { try write([:]) }
            return url
        }
    }

    private func withLockedFile<Result>(_ operation: ([SSHHostEndpoint: [SSHHostKey]]) throws -> Result) throws -> Result {
        try prepareDirectory()
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw HostTrustError.storageUnavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HostTrustError.storageUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation(read())
    }

    private func prepareDirectory() throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw HostTrustError.storageUnavailable }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw HostTrustError.storageUnavailable }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw HostTrustError.storageUnavailable
        }
    }

    private func read() throws -> [SSHHostEndpoint: [SSHHostKey]] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return [:] }
            throw HostTrustError.storageUnavailable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= Self.maximumFileSize else {
            throw HostTrustError.storageUnavailable
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HostTrustError.storageUnavailable }
            if count == 0 { break }
            guard bytes.count + count <= Self.maximumFileSize else { throw HostTrustError.storageCorrupt }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: bytes, encoding: .utf8), text.hasPrefix(Self.header) else {
            throw HostTrustError.storageCorrupt
        }
        var records: [SSHHostEndpoint: [SSHHostKey]] = [:]
        for line in text.dropFirst(Self.header.count).split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let bytes = Data(base64Encoded: String(fields[2])) else {
                throw HostTrustError.storageCorrupt
            }
            do {
                let endpoint = try Self.endpoint(from: String(fields[0]))
                let key = try SSHHostKey(algorithm: String(fields[1]), publicKey: bytes)
                guard !(records[endpoint]?.contains(key) ?? false), records[endpoint, default: []].count < 8 else {
                    throw HostTrustError.storageCorrupt
                }
                records[endpoint, default: []].append(key)
            } catch { throw HostTrustError.storageCorrupt }
        }
        return records.mapValues(Self.sorted)
    }

    private static func endpoint(from name: String) throws -> SSHHostEndpoint {
        let endpoint: SSHHostEndpoint
        if name.hasPrefix("["), let end = name.range(of: "]:", options: .backwards) {
            let host = String(name[name.index(after: name.startIndex)..<end.lowerBound])
            guard let port = UInt16(name[end.upperBound...]) else { throw HostTrustError.invalidEndpoint }
            endpoint = try SSHHostEndpoint(host: host, port: port)
        } else {
            endpoint = try SSHHostEndpoint(host: name, port: 22)
        }
        guard endpoint.knownHostsName == name else { throw HostTrustError.invalidEndpoint }
        return endpoint
    }

    private static func sorted(_ keys: [SSHHostKey]) -> [SSHHostKey] {
        keys.sorted { lhs, rhs in
            func order(_ key: SSHHostKey) -> Int {
                switch key.algorithm {
                case "ssh-ed25519": 0
                case "ecdsa-sha2-nistp256": 1
                case "ecdsa-sha2-nistp384": 2
                case "ecdsa-sha2-nistp521": 3
                default: 4
                }
            }
            let a = order(lhs), b = order(rhs)
            return a == b ? lhs.publicKey.base64EncodedString() < rhs.publicKey.base64EncodedString() : a < b
        }
    }

    private func write(_ records: [SSHHostEndpoint: [SSHHostKey]]) throws {
        var text = Self.header
        for endpoint in records.keys.sorted(by: { $0.knownHostsName < $1.knownHostsName }) {
            for key in Self.sorted(records[endpoint] ?? []) {
                text += "\(endpoint.knownHostsName) \(key.algorithm) \(key.publicKey.base64EncodedString())\n"
            }
        }
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.maximumFileSize else { throw HostTrustError.storageUnavailable }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".known-hosts-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw HostTrustError.storageUnavailable }
        defer { close(descriptor); unlink(temporary.path) }
        let succeeded = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return fsync(descriptor) == 0
        }
        guard succeeded, rename(temporary.path, url.path) == 0 else { throw HostTrustError.storageUnavailable }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw HostTrustError.storageUnavailable }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw HostTrustError.storageUnavailable }
    }
}

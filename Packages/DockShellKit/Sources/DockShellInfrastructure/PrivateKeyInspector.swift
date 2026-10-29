import Darwin
import DockShellDomain
import Foundation

/// Inspects a bounded external key container without importing it into application storage.
/// This is a format/encryption preflight; system OpenSSH performs all cryptographic validation.
public actor PrivateKeyInspector: PrivateKeyInspecting {
    private static let maximumBytes = 1_048_576

    public init() {}

    public func inspect(_ url: URL) throws -> PrivateKeyInfo {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.contains("\0") else { throw SSHAuthenticationError.privateKeyUnavailable }
        if url.pathExtension.lowercased() == "ppk" { throw SSHAuthenticationError.privateKeyUnsupported }
        // Bookmarked symlinks are useful file references. Resolve them, then refuse a second symlink
        // at the actual open and validate the descriptor rather than trusting earlier path metadata.
        let resolved = url.resolvingSymlinksInPath()
        let descriptor = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SSHAuthenticationError.privateKeyUnavailable }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw SSHAuthenticationError.privateKeyUnavailable
        }
        guard metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw SSHAuthenticationError.privateKeyPermissions
        }
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumBytes else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SSHAuthenticationError.privateKeyUnavailable }
            if count == 0 { break }
            guard bytes.count + count <= Self.maximumBytes else { throw SSHAuthenticationError.privateKeyMalformed }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw SSHAuthenticationError.privateKeyUnsupported }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { throw SSHAuthenticationError.privateKeyMalformed }
        if first.hasPrefix("PuTTY-User-Key-File-") { throw SSHAuthenticationError.privateKeyUnsupported }
        switch first {
        case "-----BEGIN OPENSSH PRIVATE KEY-----":
            guard last == "-----END OPENSSH PRIVATE KEY-----" else { throw SSHAuthenticationError.privateKeyMalformed }
            let body = try decode(Array(lines.dropFirst().dropLast()))
            return try inspectOpenSSH(body)
        case "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----":
            let end = first.replacingOccurrences(of: "BEGIN", with: "END")
            guard last == end else { throw SSHAuthenticationError.privateKeyMalformed }
            return try inspectLegacyPEM(Array(lines.dropFirst().dropLast()), rsa: first.contains("RSA"))
        case "-----BEGIN PRIVATE KEY-----":
            guard last == "-----END PRIVATE KEY-----" else { throw SSHAuthenticationError.privateKeyMalformed }
            let body = try decode(Array(lines.dropFirst().dropLast()))
            var sequence = try DERFields.sequence(body)
            guard try sequence.next(tag: 0x02) == Data([0]) else { throw SSHAuthenticationError.privateKeyUnsupported }
            var algorithm = try DERFields.sequence(try sequence.next(tag: 0x30), wrapped: false)
            let oid = try algorithm.next(tag: 0x06)
            // OpenSSH's PEM fallback supports RSA and NIST EC; do not promise every PKCS#8 algorithm.
            guard oid == Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01])
                || oid == Data([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]) else {
                throw SSHAuthenticationError.privateKeyUnsupported
            }
            guard !(try sequence.next(tag: 0x04)).isEmpty else { throw SSHAuthenticationError.privateKeyMalformed }
            return PrivateKeyInfo(format: .pem, requiresPassphrase: false)
        case "-----BEGIN ENCRYPTED PRIVATE KEY-----":
            guard last == "-----END ENCRYPTED PRIVATE KEY-----" else { throw SSHAuthenticationError.privateKeyMalformed }
            var sequence = try DERFields.sequence(try decode(Array(lines.dropFirst().dropLast())))
            var algorithm = try DERFields.sequence(try sequence.next(tag: 0x30), wrapped: false)
            // Restrict encrypted PKCS#8 preflight to the common PBES2 envelope.
            guard try algorithm.next(tag: 0x06) == Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x05,0x0d]) else {
                throw SSHAuthenticationError.privateKeyUnsupported
            }
            guard !(try sequence.next(tag: 0x04)).isEmpty, sequence.isAtEnd else {
                throw SSHAuthenticationError.privateKeyMalformed
            }
            return PrivateKeyInfo(format: .pem, requiresPassphrase: true)
        case "-----BEGIN DSA PRIVATE KEY-----": throw SSHAuthenticationError.privateKeyUnsupported
        default: throw SSHAuthenticationError.privateKeyUnsupported
        }
    }

    private func decode(_ lines: [String]) throws -> Data {
        guard !lines.isEmpty, let body = Data(base64Encoded: lines.joined()), !body.isEmpty else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        return body
    }

    private func inspectOpenSSH(_ body: Data) throws -> PrivateKeyInfo {
        let magic = Data("openssh-key-v1\0".utf8)
        guard body.starts(with: magic) else { throw SSHAuthenticationError.privateKeyMalformed }
        var wire = KeyContainerWire(Data(body.dropFirst(magic.count)))
        guard let cipher = String(data: try wire.string(), encoding: .ascii), !cipher.isEmpty,
              let kdf = String(data: try wire.string(), encoding: .ascii) else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        let options = try wire.string()
        guard try wire.number() == 1 else { throw SSHAuthenticationError.privateKeyUnsupported }
        let publicKey = try wire.string()
        var publicWire = KeyContainerWire(publicKey)
        guard let algorithm = String(data: try publicWire.string(), encoding: .ascii) else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        do { _ = try SSHHostKey(algorithm: algorithm, publicKey: publicKey) }
        catch { throw SSHAuthenticationError.privateKeyUnsupported }
        let privateBytes = try wire.string()
        guard privateBytes.count >= 16 else { throw SSHAuthenticationError.privateKeyMalformed }
        if cipher == "none" {
            guard kdf == "none", options.isEmpty, privateBytes.count.isMultiple(of: 8), wire.isAtEnd else {
                throw SSHAuthenticationError.privateKeyMalformed
            }
            return PrivateKeyInfo(format: .openSSH, requiresPassphrase: false)
        }
        guard kdf == "bcrypt" else { throw SSHAuthenticationError.privateKeyUnsupported }
        let supported = ["aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-cbc", "aes192-cbc", "aes256-cbc",
                         "aes128-gcm@openssh.com", "aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"]
        guard supported.contains(cipher) else { throw SSHAuthenticationError.privateKeyUnsupported }
        // OpenSSH stores an AEAD authentication tag after the length-delimited ciphertext.
        let aead = cipher.contains("gcm@") || cipher == "chacha20-poly1305@openssh.com"
        let blockSize = cipher == "chacha20-poly1305@openssh.com" ? 8 : 16
        guard privateBytes.count.isMultiple(of: blockSize), wire.remainingCount == (aead ? 16 : 0) else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        var kdfWire = KeyContainerWire(options)
        let salt = try kdfWire.string()
        guard (1...1_024).contains(salt.count), try kdfWire.number() > 0, kdfWire.isAtEnd else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        return PrivateKeyInfo(format: .openSSH, requiresPassphrase: true)
    }

    private func inspectLegacyPEM(_ lines: [String], rsa: Bool) throws -> PrivateKeyInfo {
        var lines = lines
        if lines.first?.hasPrefix("Proc-Type:") == true {
            guard lines.removeFirst() == "Proc-Type: 4,ENCRYPTED", let info = lines.first,
                  info.hasPrefix("DEK-Info: ") else { throw SSHAuthenticationError.privateKeyMalformed }
            lines.removeFirst()
            let fields = info.dropFirst("DEK-Info: ".count).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw SSHAuthenticationError.privateKeyMalformed }
            let supported = ["AES-128-CBC", "AES-192-CBC", "AES-256-CBC", "DES-EDE3-CBC"]
            guard supported.contains(String(fields[0])) else { throw SSHAuthenticationError.privateKeyUnsupported }
            guard !fields[1].isEmpty, fields[1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
                  (try decode(lines)).count >= 16 else { throw SSHAuthenticationError.privateKeyMalformed }
            return PrivateKeyInfo(format: .pem, requiresPassphrase: true)
        }
        var sequence = try DERFields.sequence(try decode(lines))
        let version = try sequence.next(tag: 0x02)
        if rsa {
            guard version == Data([0]) else { throw SSHAuthenticationError.privateKeyUnsupported }
            for _ in 0..<8 {
                guard !(try sequence.next(tag: 0x02)).isEmpty else { throw SSHAuthenticationError.privateKeyMalformed }
            }
            guard sequence.isAtEnd else { throw SSHAuthenticationError.privateKeyMalformed }
        } else {
            guard version == Data([1]), !(try sequence.next(tag: 0x04)).isEmpty else {
                throw SSHAuthenticationError.privateKeyMalformed
            }
        }
        return PrivateKeyInfo(format: .pem, requiresPassphrase: false)
    }
}

/// Minimal length-delimited container readers; neither performs private-key mathematics or decryption.
private struct KeyContainerWire {
    private let bytes: [UInt8]
    private var position = 0
    init(_ data: Data) { bytes = Array(data) }
    var isAtEnd: Bool { position == bytes.count }
    var remainingCount: Int { bytes.count - position }
    mutating func number() throws -> UInt32 {
        guard bytes.count - position >= 4 else { throw SSHAuthenticationError.privateKeyMalformed }
        defer { position += 4 }
        return bytes[position..<(position + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    mutating func string() throws -> Data {
        let length = try number()
        guard length <= bytes.count - position else { throw SSHAuthenticationError.privateKeyMalformed }
        defer { position += Int(length) }
        return Data(bytes[position..<(position + Int(length))])
    }
}

private struct DERFields {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: Data) { self.bytes = Array(bytes) }
    var isAtEnd: Bool { position == bytes.count }
    static func sequence(_ data: Data, wrapped: Bool = true) throws -> DERFields {
        if !wrapped { return DERFields(data) }
        var outer = DERFields(data)
        let contents = try outer.next(tag: 0x30)
        guard outer.isAtEnd else { throw SSHAuthenticationError.privateKeyMalformed }
        return DERFields(contents)
    }
    mutating func next(tag: UInt8) throws -> Data {
        guard position < bytes.count, bytes[position] == tag else { throw SSHAuthenticationError.privateKeyMalformed }
        position += 1
        guard position < bytes.count else { throw SSHAuthenticationError.privateKeyMalformed }
        let leading = bytes[position]; position += 1
        var length = Int(leading)
        if leading & 0x80 != 0 {
            let count = Int(leading & 0x7f)
            guard (1...3).contains(count), bytes.count - position >= count, bytes[position] != 0 else {
                throw SSHAuthenticationError.privateKeyMalformed
            }
            length = bytes[position..<(position + count)].reduce(0) { ($0 << 8) | Int($1) }
            position += count
            guard length >= 128 else { throw SSHAuthenticationError.privateKeyMalformed }
        }
        guard length <= bytes.count - position else { throw SSHAuthenticationError.privateKeyMalformed }
        defer { position += length }
        return Data(bytes[position..<(position + length)])
    }
}

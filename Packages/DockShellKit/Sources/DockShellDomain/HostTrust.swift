import CryptoKit
import Darwin
import Foundation

/// Sanitized host-trust failures. Public keys, server banners and subprocess output are not errors.
public enum HostTrustError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidKey, scanFailed, scanTimeout
    case storageUnavailable, storageCorrupt, hostKeyChanged
}

/// A normalized network endpoint and its OpenSSH known_hosts lookup name.
public struct SSHHostEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard port > 0, !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-") else {
            throw HostTrustError.invalidEndpoint
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.contains(":") {
            // Keep a numeric interface scope, when supplied, outside inet_pton's address bytes.
            let pieces = host.split(separator: "%", omittingEmptySubsequences: false)
            guard pieces.count <= 2, let address = pieces.first, !address.isEmpty else {
                throw HostTrustError.invalidEndpoint
            }
            var parsed = in6_addr()
            guard String(address).withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else {
                throw HostTrustError.invalidEndpoint
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &parsed, &output, socklen_t(output.count)) != nil else {
                throw HostTrustError.invalidEndpoint
            }
            host = String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if pieces.count == 2 {
                let scope = pieces[1]
                guard !scope.isEmpty, scope.utf8.count <= 32,
                      scope.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else {
                    throw HostTrustError.invalidEndpoint
                }
                host += "%" + scope
            }
        } else {
            // No commas, wildcards, @, slash, whitespace or option prefixes can enter known_hosts.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            // Explicit capture avoids Swift 6.4 -O miscompiling a bound CharacterSet method.
            guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }), !host.contains("..") else {
                throw HostTrustError.invalidEndpoint
            }
            host = host.lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            guard !host.isEmpty else { throw HostTrustError.invalidEndpoint }
        }
        self.host = host
        self.port = port
    }

    public var knownHostsName: String { port == 22 ? host : "[\(host)]:\(port)" }
}

/// A complete SSH public-key blob. Fingerprints are display values, never the stored trust anchor.
public struct SSHHostKey: Hashable, Sendable {
    public let algorithm: String
    public let publicKey: Data

    /// Validates the SSH wire format and supported host-key algorithm before exposing a fingerprint.
    public init(algorithm: String, publicKey: Data) throws {
        guard publicKey.count <= 16_384 else { throw HostTrustError.invalidKey }
        var wire = HostKeyWire(publicKey)
        guard try wire.string() == Data(algorithm.utf8) else { throw HostTrustError.invalidKey }
        switch algorithm {
        case "ssh-ed25519":
            guard try wire.string().count == 32 else { throw HostTrustError.invalidKey }
        case "ssh-rsa":
            let exponent = try wire.positiveMPInt()
            let modulus = try wire.positiveMPInt()
            guard exponent.count <= 16, let last = exponent.last, last & 1 == 1,
                  exponent.count > 1 || last >= 3, (128...1_025).contains(modulus.count) else {
                throw HostTrustError.invalidKey
            }
        case "ecdsa-sha2-nistp256":
            guard try wire.string() == Data("nistp256".utf8),
                  (try? P256.Signing.PublicKey(x963Representation: wire.string())) != nil else {
                throw HostTrustError.invalidKey
            }
        case "ecdsa-sha2-nistp384":
            guard try wire.string() == Data("nistp384".utf8),
                  (try? P384.Signing.PublicKey(x963Representation: wire.string())) != nil else {
                throw HostTrustError.invalidKey
            }
        case "ecdsa-sha2-nistp521":
            guard try wire.string() == Data("nistp521".utf8),
                  (try? P521.Signing.PublicKey(x963Representation: wire.string())) != nil else {
                throw HostTrustError.invalidKey
            }
        default:
            throw HostTrustError.invalidKey
        }
        guard wire.isAtEnd else { throw HostTrustError.invalidKey }
        self.algorithm = algorithm
        self.publicKey = publicKey
    }

    public var sha256Fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: publicKey)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// RSA key blobs use ssh-rsa encoding while modern handshakes use RSA/SHA-2 signatures.
    public var hostKeyAlgorithms: [String] {
        algorithm == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256"] : [algorithm]
    }
}

/// Keyscan results are untrusted candidates until the user approves the complete public keys.
public enum HostTrustAssessment: Equatable, Sendable {
    case unknown([SSHHostKey])
    case trusted([SSHHostKey])
    case changed(known: [SSHHostKey], offered: [SSHHostKey])

    public static func assess(known: [SSHHostKey], offered: [SSHHostKey]) throws -> Self {
        guard !offered.isEmpty else { throw HostTrustError.scanFailed }
        if known.isEmpty { return .unknown(offered) }
        // Preserve the stored preference order rather than keyscan's concurrent response order.
        let matching = known.filter { offered.contains($0) }
        return matching.isEmpty ? .changed(known: known, offered: offered) : .trusted(matching)
    }
}

/// Application-owned full-key trust storage. Approval never replaces an existing different key set.
public protocol HostKeyTrustStore: Sendable {
    func knownKeys(for endpoint: SSHHostEndpoint) async throws -> [SSHHostKey]
    func approve(_ keys: [SSHHostKey], for endpoint: SSHHostEndpoint) async throws
    func knownHostsFileURL() async throws -> URL
}

/// Discovers candidate public keys without sending authentication material.
public protocol SSHHostKeyScanner: Sendable {
    func scan(_ endpoint: SSHHostEndpoint) async throws -> [SSHHostKey]
}

private struct HostKeyWire {
    let data: [UInt8]
    var offset = 0
    init(_ data: Data) { self.data = Array(data) }
    var isAtEnd: Bool { offset == data.count }

    mutating func string() throws -> Data {
        guard data.count - offset >= 4 else { throw HostTrustError.invalidKey }
        let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        guard length <= data.count - offset else { throw HostTrustError.invalidKey }
        defer { offset += Int(length) }
        return Data(data[offset..<(offset + Int(length))])
    }

    mutating func positiveMPInt() throws -> Data {
        let value = try string()
        guard let first = value.first, first & 0x80 == 0,
              !(value.count == 1 && first == 0),
              !(value.count > 1 && first == 0 && value[value.startIndex + 1] & 0x80 == 0) else {
            throw HostTrustError.invalidKey
        }
        return value
    }
}

import DockShellDomain
import Foundation

/// Original bounded SFTP v3 encoding. Wire integers use network byte order.
enum SFTPWire {
    static let maximumPacketBytes = 1_048_576
    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func uint64(_ value: UInt64) -> Data { uint32(UInt32(value >> 32)) + uint32(UInt32(truncatingIfNeeded: value)) }
    static func string(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPacketBytes else { throw SFTPError.packetTooLarge }
        return uint32(UInt32(payload.count)) + payload
    }

    struct Reader {
        let data: Data
        private(set) var offset = 0
        var remaining: Int { data.count - offset }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw SFTPError.invalidPacket }
            defer { offset += count }
            return Data(data[offset..<(offset + count)])
        }
        mutating func byte() throws -> UInt8 { try bytes(1)[0] }
        mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
        mutating func uint64() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8) | UInt64($1) } }
        mutating func string(maximum: Int = maximumPacketBytes) throws -> Data {
            let length = try uint32()
            guard UInt64(length) <= UInt64(maximum) else { throw SFTPError.packetTooLarge }
            return try bytes(Int(length))
        }
        mutating func attributes() throws -> SFTPFileAttributes {
            let flags = try uint32()
            guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPError.invalidPacket }
            let size: UInt64? = flags & 1 != 0 ? try uint64() : nil
            let uid: UInt32? = flags & 2 != 0 ? try uint32() : nil
            let gid: UInt32? = flags & 2 != 0 ? try uint32() : nil
            let permissions: UInt32? = flags & 4 != 0 ? try uint32() : nil
            let access: UInt32? = flags & 8 != 0 ? try uint32() : nil
            let modified: UInt32? = flags & 8 != 0 ? try uint32() : nil
            if flags & 0x80000000 != 0 {
                let count = try uint32()
                guard count <= 64 else { throw SFTPError.invalidPacket }
                for _ in 0..<count { _ = try string(); _ = try string() }
            }
            return SFTPFileAttributes(size: size, userID: uid, groupID: gid, permissions: permissions,
                                      accessTime: access, modificationTime: modified)
        }
        func requireEnd() throws { guard remaining == 0 else { throw SFTPError.invalidPacket } }
    }

    /// A single reader owns framing across arbitrary pipe fragmentation/coalescing.
    struct Framer: Sendable {
        let channel: any SFTPByteChannel
        private var buffer = Data()
        init(channel: any SFTPByteChannel) { self.channel = channel }
        mutating func next() async throws -> Data {
            while buffer.count < 4 { try await fill() }
            let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0 else { throw SFTPError.invalidPacket }
            guard size <= maximumPacketBytes else { throw SFTPError.packetTooLarge }
            let length = Int(size) + 4
            while buffer.count < length { try await fill() }
            let packet = Data(buffer[4..<length])
            buffer = Data(buffer.dropFirst(length))
            return packet
        }
        private mutating func fill() async throws {
            try Task.checkCancellation()
            guard let bytes = try await channel.read(maxBytes: 65_536), !bytes.isEmpty else {
                throw SFTPError.connectionClosed
            }
            guard bytes.count <= 65_536, buffer.count + bytes.count <= maximumPacketBytes + 65_540 else {
                throw SFTPError.packetTooLarge
            }
            buffer.append(bytes)
        }
    }
}

/// Actor isolation alone does not serialize a write across suspension. This gate
/// keeps complete frames ordered even if a byte-channel implementation suspends.
actor SFTPPacketWriter {
    let channel: any SFTPByteChannel
    private var busy = false
    private var closed = false
    private var admittedFrames = 0
    private var admittedBytes = 0
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    init(channel: any SFTPByteChannel) { self.channel = channel }
    func send(_ packet: Data) async throws {
        guard !closed else { throw SFTPError.connectionClosed }
        guard admittedFrames < 32, packet.count <= 2_097_152 - admittedBytes else {
            throw SFTPError.requestLimit
        }
        admittedFrames += 1
        admittedBytes += packet.count
        defer { admittedFrames -= 1; admittedBytes -= packet.count }
        if busy {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } else { busy = true }
        defer { release() }
        try Task.checkCancellation()
        guard !closed else { throw SFTPError.connectionClosed }
        try await channel.write(packet)
    }
    func close() {
        closed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: SFTPError.connectionClosed) }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

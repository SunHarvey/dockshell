import Foundation

/// A bounded byte ring. Input must be valid UTF-8; eviction never leaves a partial scalar.
/// A scalar boundary is sufficient for valid text; it is not necessarily an emoji/grapheme boundary.
struct UTF8Tail {
    let capacity: Int
    private var storage: [UInt8]
    private var head = 0
    private(set) var count = 0
    private(set) var removedBytes: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity >= 4)
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: min(capacity, 4_096))
    }

    mutating func append(_ data: Data) {
        if count + data.count > storage.count && storage.count < capacity {
            let retained = self.data()
            storage = [UInt8](repeating: 0, count: min(capacity, max(count + data.count, storage.count * 2)))
            storage.replaceSubrange(0..<retained.count, with: retained)
            head = 0
        }
        for byte in data {
            if count == storage.count { discardFirst() }
            storage[(head + count) % storage.count] = byte
            count += 1
        }
        while count > 0 && storage[head] & 0xc0 == 0x80 { discardFirst() }
    }

    mutating func clear() {
        head = 0; count = 0; removedBytes = 0
    }

    func data() -> Data {
        guard count > 0 else { return Data() }
        let firstCount = min(count, storage.count - head)
        var result = Data(storage[head..<(head + firstCount)])
        if firstCount < count { result.append(contentsOf: storage[0..<(count - firstCount)]) }
        return result
    }

    private mutating func discardFirst() {
        head = (head + 1) % storage.count
        count -= 1
        removedBytes += 1
    }
}

/// Probe-only diagnostics never include terminal content, credentials or private paths.
struct ProbeFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ProbeFailure(description: message) }
}

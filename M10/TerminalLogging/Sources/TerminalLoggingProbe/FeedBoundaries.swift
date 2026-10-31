import Foundation

/// Finds feed boundaries only; SwiftTerm still interprets every byte. In particular,
/// a cursor movement must be observed before subsequent printable text/newlines.
/// State survives packet boundaries without retaining an unbounded control string.
struct FeedBoundaries {
    private enum State { case text, escape, intermediate, csi, string, stringEscape }
    private var state = State.text

    mutating func segments(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        for index in bytes.indices {
            let byte = bytes[index]
            var complete = false
            switch state {
            case .text:
                if byte < 0x20 || byte == 0x7f {
                    if start < index { result.append(bytes[start..<index]) }
                    start = index
                    if byte == 0x1b { state = .escape }
                    else { complete = true }
                }
            case .escape:
                switch byte {
                case 0x5b: state = .csi
                case 0x5d, 0x50, 0x5f, 0x5e, 0x58: state = .string
                case 0x20...0x2f: state = .intermediate
                case 0x1b: break
                default: complete = true
                }
            case .intermediate:
                if byte >= 0x30 && byte <= 0x7e { complete = true }
            case .csi:
                if byte >= 0x40 && byte <= 0x7e { complete = true }
                else if byte == 0x1b { state = .escape }
            case .string:
                if byte == 0x07 { complete = true }
                else if byte == 0x1b { state = .stringEscape }
            case .stringEscape:
                if byte == 0x5c { complete = true }
                else if byte != 0x1b { state = .string }
            }
            if complete {
                result.append(bytes[start...index]); start = index + 1; state = .text
            }
        }
        if start < bytes.endIndex { result.append(bytes[start..<bytes.endIndex]) }
        return result
    }
}

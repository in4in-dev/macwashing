import Foundation

/// A read-only parser of Finder's `.DS_Store` files («Bud1»: a buddy allocator holding one B-tree of records). The
/// Storage section reads only the Trash's, for the put-back records (`ptbL`, `ptbN`); it never writes one.
///
/// Layout: after a 4-byte version (1) and «Bud1», the offset of the allocator's root block. Offsets count from byte 4.
/// The root block lists block addresses (offset | log2 size in the low 5 bits) and a table of contents whose «DSDB»
/// entry is the block of the tree header (root node, levels, records, nodes, page size). A node starts with `P` and a
/// record count: `P == 0` is a leaf of records; otherwise each record follows the child before it and `P` is the
/// rightmost child. A record is a UTF-16BE file name, a four-letter code and a typed value.
public enum DSStore {
    public struct Record: Sendable, Hashable {
        /// The item the record is about: a name inside the folder that holds the `.DS_Store`.
        public let name: String
        /// Four letters: `ptbL` (put-back folder), `ptbN` (put-back name), `Iloc` (icon position)…
        public let code: String
        public let value: Value
    }

    public enum Value: Sendable, Hashable {
        case bool(Bool)
        case integer(Int64)
        case type(String)
        case string(String)
        case blob(Data)
    }

    public struct Malformed: Error, Sendable {}

    /// Bigger files are not read: a Trash with that many records is not worth parsing.
    static let maxFileSize = 64 << 20

    /// Every record of the file, in the tree's order.
    public static func records(in data: Data) throws -> [Record] {
        guard data.count <= maxFileSize else { throw Malformed() }
        let reader = Reader(bytes: [UInt8](data))
        guard try reader.u32(at: 0) == 1, try reader.u32(at: 4) == 0x4275_6431 else { throw Malformed() }   // «Bud1»
        let rootOffset = Int(try reader.u32(at: 8))
        let blocks = try reader.blockAddresses(root: rootOffset + 4)
        guard let header = try reader.directory(root: rootOffset + 4, count: blocks.count)["DSDB"],
              let headerAt = blocks[safe: header] else { throw Malformed() }
        let rootNode = Int(try reader.u32(at: headerAt))
        var records: [Record] = []
        var visited: Set<Int> = []
        try reader.node(rootNode, blocks: blocks, depth: 0, visited: &visited, into: &records)
        return records
    }

    private struct Reader {
        let bytes: [UInt8]

        func u32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw Malformed() }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }

        func slice(at offset: Int, count: Int) throws -> ArraySlice<UInt8> {
            guard offset >= 0, count >= 0, offset + count <= bytes.count else { throw Malformed() }
            return bytes[offset ..< offset + count]
        }

        /// File offsets of the allocator's blocks, by block number.
        func blockAddresses(root: Int) throws -> [Int] {
            let count = Int(try u32(at: root))
            guard count < 1 << 20 else { throw Malformed() }
            return try (0 ..< count).map { index in
                let address = Int(try u32(at: root + 8 + index * 4))
                return (address & ~0x1F) + 4
            }
        }

        /// The allocator's table of contents: name → block number. It follows the addresses, which are padded to a
        /// multiple of 256 entries.
        func directory(root: Int, count: Int) throws -> [String: Int] {
            var offset = root + 8 + ((count + 255) / 256 * 256) * 4
            let entries = Int(try u32(at: offset))
            guard entries < 1_024 else { throw Malformed() }
            offset += 4
            var result: [String: Int] = [:]
            for _ in 0 ..< entries {
                let length = Int(try slice(at: offset, count: 1).first ?? 0)
                let name = String(decoding: try slice(at: offset + 1, count: length), as: UTF8.self)
                result[name] = Int(try u32(at: offset + 1 + length))
                offset += 1 + length + 4
            }
            return result
        }

        func node(_ block: Int, blocks: [Int], depth: Int, visited: inout Set<Int>, into records: inout [Record]) throws {
            // A loop or an absurd depth is a broken file, not a deep tree.
            guard depth < 32, visited.insert(block).inserted, let start = blocks[safe: block] else { throw Malformed() }
            let rightmost = Int(try u32(at: start))
            let count = Int(try u32(at: start + 4))
            guard count < 1 << 16 else { throw Malformed() }
            var offset = start + 8
            for _ in 0 ..< count {
                if rightmost != 0 {
                    let child = Int(try u32(at: offset))
                    offset += 4
                    try node(child, blocks: blocks, depth: depth + 1, visited: &visited, into: &records)
                }
                records.append(try record(at: &offset))
            }
            if rightmost != 0 {
                try node(rightmost, blocks: blocks, depth: depth + 1, visited: &visited, into: &records)
            }
        }

        func record(at offset: inout Int) throws -> Record {
            let name = try utf16(at: &offset)
            let code = String(decoding: try slice(at: offset, count: 4), as: UTF8.self)
            let type = String(decoding: try slice(at: offset + 4, count: 4), as: UTF8.self)
            offset += 8
            let value: Value
            switch type {
            case "bool":
                value = .bool((try slice(at: offset, count: 1).first ?? 0) != 0)
                offset += 1
            case "long", "shor":
                value = .integer(Int64(Int32(bitPattern: try u32(at: offset))))
                offset += 4
            case "type":
                value = .type(String(decoding: try slice(at: offset, count: 4), as: UTF8.self))
                offset += 4
            case "comp", "dutc":
                value = .integer(Int64(bitPattern: UInt64(try u32(at: offset)) << 32 | UInt64(try u32(at: offset + 4))))
                offset += 8
            case "blob":
                let length = Int(try u32(at: offset))
                value = .blob(Data(try slice(at: offset + 4, count: length)))
                offset += 4 + length
            case "ustr":
                value = .string(try utf16(at: &offset))
            default:
                // Without its size the rest of the node cannot be read.
                throw Malformed()
            }
            return Record(name: name, code: code, value: value)
        }

        /// A length in UTF-16 units, then the big-endian text.
        func utf16(at offset: inout Int) throws -> String {
            let length = Int(try u32(at: offset))
            let raw = try slice(at: offset + 4, count: length * 2)
            offset += 4 + length * 2
            var units: [UInt16] = []
            units.reserveCapacity(length)
            var index = raw.startIndex
            while index < raw.endIndex {
                units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

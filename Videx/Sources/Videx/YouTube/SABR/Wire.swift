import Foundation

/// Minimal protobuf/UMP codecs. Unknown protobuf fields and UMP part types are retained/skipped.
enum Protobuf {
    enum Value: Equatable { case integer(UInt64), bytes(Data), fixed32(UInt32), fixed64(UInt64) }
    struct Message {
        var fields: [Int: [Value]] = [:]
        init(_ data: Data = Data()) throws {
            var reader = WireReader(data)
            while !reader.isAtEnd {
                let tag = try reader.varint()
                let number = Int(tag >> 3)
                guard number > 0 else { throw ExtractionError.parse("protobuf 字段号为零") }
                let value: Value
                switch tag & 7 {
                case 0: value = .integer(try reader.varint())
                case 1: value = .fixed64(try reader.fixed(8))
                case 2:
                    let length = try reader.varint()
                    guard length <= UInt64(reader.remaining) else { throw ExtractionError.parse("protobuf 字段截断") }
                    value = .bytes(try reader.read(Int(length)))
                case 5: value = .fixed32(UInt32(try reader.fixed(4)))
                default: throw ExtractionError.parse("不支持的 protobuf wire type")
                }
                fields[number, default: []].append(value)
            }
        }
        func integer(_ field: Int) -> UInt64? {
            guard case .integer(let value) = fields[field]?.first else { return nil }; return value
        }
        func bytes(_ field: Int) -> Data? {
            guard case .bytes(let value) = fields[field]?.first else { return nil }; return value
        }
        func string(_ field: Int) -> String? { bytes(field).flatMap { String(data: $0, encoding: .utf8) } }
        func message(_ field: Int) throws -> Message? { try bytes(field).map { try Message($0) } }
        func integers(_ field: Int) throws -> [UInt64] {
            var values: [UInt64] = []
            for value in fields[field] ?? [] {
                switch value {
                case .integer(let n): values.append(n)
                case .bytes(let data):
                    var reader = WireReader(data)
                    while !reader.isAtEnd { values.append(try reader.varint()) }
                default: break
                }
            }
            return values
        }
    }
    struct Writer {
        var data = Data()
        mutating func integer(_ field: Int, _ value: UInt64?) {
            guard let value else { return }
            varint(UInt64(field << 3)); varint(value)
        }
        mutating func bytes(_ field: Int, _ value: Data?) {
            guard let value else { return }
            varint(UInt64(field << 3 | 2)); varint(UInt64(value.count)); data.append(value)
        }
        mutating func string(_ field: Int, _ value: String?) { bytes(field, value.map { Data($0.utf8) }) }
        private mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
            data.append(UInt8(value))
        }
    }
}

struct WireReader {
    private let data: Data
    private(set) var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0 && count <= remaining else { throw ExtractionError.parse("二进制帧截断") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func byte() throws -> UInt8 { try read(1)[0] }
    mutating func fixed(_ count: Int) throws -> UInt64 {
        try read(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let value = try byte()
            if shift == 63 && value > 1 { throw ExtractionError.parse("protobuf varint 溢出") }
            result |= UInt64(value & 127) << shift
            if value & 128 == 0 { return result }
        }
        throw ExtractionError.parse("protobuf varint 溢出")
    }
    mutating func umpInteger() throws -> UInt64 {
        let prefix = try byte()
        let size = prefix < 128 ? 1 : prefix < 192 ? 2 : prefix < 224 ? 3 : prefix < 240 ? 4 : 5
        var result = size == 5 ? UInt64(0) : UInt64(prefix & UInt8((1 << (8 - size)) - 1))
        var shift = size == 5 ? 0 : 8 - size
        for _ in 1..<size { result |= UInt64(try byte()) << shift; shift += 8 }
        return result
    }
}

enum UMP {
    struct Part { let type: Int; let data: Data }
    static func decode(_ data: Data) throws -> [Part] {
        var reader = WireReader(data), parts: [Part] = []
        while !reader.isAtEnd {
            let type = try reader.umpInteger(), size = try reader.umpInteger()
            guard size <= UInt64(reader.remaining), size <= 64 * 1024 * 1024 else { throw ExtractionError.parse("UMP 数据帧过大或截断") }
            parts.append(Part(type: Int(type), data: try reader.read(Int(size))))
        }
        return parts
    }
    static func encode(type: Int, data: Data) -> Data {
        func integer(_ value: UInt64) -> Data {
            if value < 128 { return Data([UInt8(value)]) }
            let size = value < 16384 ? 2 : value < 2097152 ? 3 : value < 268435456 ? 4 : 5
            let bits = size == 5 ? 0 : 8 - size
            var result = Data([size == 5 ? 240 : UInt8(value & UInt64((1 << bits) - 1)) | (size == 2 ? 128 : size == 3 ? 192 : 224)])
            for i in 0..<size - 1 { result.append(UInt8((value >> (bits + i * 8)) & 255)) }
            return result
        }
        return integer(UInt64(type)) + integer(UInt64(data.count)) + data
    }
}

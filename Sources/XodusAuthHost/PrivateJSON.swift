// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum HostFailure: String, Error, Sendable {
    case protocolInvalid, channelClosed, deadlineExpired, navigationFailed
    case rendererTerminated, bridgeInvalid, javaScriptFailed, popupUnsupported, cancelled
}

indirect enum PrivateValue: Equatable, Sendable {
    case object([String: PrivateValue]), array([PrivateValue]), string(String), number(String)
    case bool(Bool), null

    func object(keys: Set<String>) throws -> [String: PrivateValue] {
        guard case .object(let value) = self, Set(value.keys) == keys else {
            throw HostFailure.protocolInvalid
        }
        return value
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var unsigned: UInt64? {
        guard case .number(let value) = self, !value.hasPrefix("-") else { return nil }
        return UInt64(value)
    }

    func encoded() throws -> Data {
        switch self {
        case .string(let value): return try JSONEncoder().encode(value)
        case .number(let value):
            guard case .number = try PrivateJSON.parse(Data(value.utf8)) else {
                throw HostFailure.protocolInvalid
            }
            return Data(value.utf8)
        case .bool(let value): return Data((value ? "true" : "false").utf8)
        case .null: return Data("null".utf8)
        case .array(let values):
            var result = Data("[".utf8)
            for (index, value) in values.enumerated() {
                if index > 0 { result.append(44) }
                result.append(try value.encoded())
            }
            result.append(93)
            return result
        case .object(let values):
            var result = Data("{".utf8)
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { result.append(44) }
                result.append(try JSONEncoder().encode(key))
                result.append(58)
                guard let value = values[key] else { throw HostFailure.protocolInvalid }
                result.append(try value.encoded())
            }
            result.append(125)
            return result
        }
    }
}

enum PrivateJSON {
    static let maximumBytes = 262_144

    static func parse(_ data: Data) throws -> PrivateValue {
        guard !data.isEmpty, data.count <= maximumBytes else { throw HostFailure.protocolInvalid }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.offset == parser.bytes.count else { throw HostFailure.protocolInvalid }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func space() {
            while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func consume(_ byte: UInt8) throws {
            space()
            guard offset < bytes.count, bytes[offset] == byte else { throw HostFailure.protocolInvalid }
            offset += 1
        }

        mutating func string() throws -> String {
            space()
            let start = offset
            try consume(34)
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                    catch { throw HostFailure.protocolInvalid }
                } else if byte < 32 { throw HostFailure.protocolInvalid }
            }
            throw HostFailure.protocolInvalid
        }

        mutating func value(depth: Int) throws -> PrivateValue {
            guard depth <= 24 else { throw HostFailure.protocolInvalid }
            space()
            guard offset < bytes.count else { throw HostFailure.protocolInvalid }
            switch bytes[offset] {
            case 34: return .string(try string())
            case 123:
                offset += 1
                space()
                var values: [String: PrivateValue] = [:]
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; return .object(values) }
                while true {
                    let key = try string()
                    guard values[key] == nil else { throw HostFailure.protocolInvalid }
                    try consume(58)
                    values[key] = try value(depth: depth + 1)
                    space()
                    guard offset < bytes.count else { throw HostFailure.protocolInvalid }
                    if bytes[offset] == 125 { offset += 1; return .object(values) }
                    try consume(44)
                }
            case 91:
                offset += 1
                space()
                var values: [PrivateValue] = []
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    space()
                    guard offset < bytes.count else { throw HostFailure.protocolInvalid }
                    if bytes[offset] == 93 { offset += 1; return .array(values) }
                    try consume(44)
                }
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default:
                let start = offset
                while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) {
                    offset += 1
                }
                let raw = String(decoding: bytes[start..<offset], as: UTF8.self)
                guard raw.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                                options: .regularExpression) != nil,
                      let number = Double(raw), number.isFinite else { throw HostFailure.protocolInvalid }
                return .number(raw)
            }
        }

        mutating func literal(_ value: String) throws {
            let literal = Array(value.utf8)
            guard offset + literal.count <= bytes.count,
                  Array(bytes[offset..<(offset + literal.count)]) == literal else {
                throw HostFailure.protocolInvalid
            }
            offset += literal.count
        }
    }
}

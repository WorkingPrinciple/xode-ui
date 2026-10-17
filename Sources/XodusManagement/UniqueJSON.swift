// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension JSONValue {
    static func decodeUnique(_ data: Data, maximumBytes: Int) throws -> JSONValue {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ManagementError.invalidPayload }
        var scanner = UniqueJSON(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.space()
        guard scanner.offset == scanner.bytes.count else { throw ManagementError.invalidPayload }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// Foundation's keyed decoding discards duplicate keys before schema validation.
private struct UniqueJSON {
    let bytes: [UInt8]
    var offset = 0

    mutating func space() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func consume(_ byte: UInt8) throws {
        space()
        guard offset < bytes.count, bytes[offset] == byte else { throw ManagementError.invalidPayload }
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
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            } else if byte < 32 { throw ManagementError.invalidPayload }
        }
        throw ManagementError.invalidPayload
    }

    mutating func value(depth: Int) throws {
        guard depth <= 24 else { throw ManagementError.invalidPayload }
        space()
        guard offset < bytes.count else { throw ManagementError.invalidPayload }
        switch bytes[offset] {
        case 34: _ = try string()
        case 123:
            offset += 1
            space()
            var keys: Set<String> = []
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            while true {
                guard keys.insert(try string()).inserted else { throw ManagementError.invalidPayload }
                try consume(58)
                try value(depth: depth + 1)
                space()
                guard offset < bytes.count else { throw ManagementError.invalidPayload }
                if bytes[offset] == 125 { offset += 1; return }
                try consume(44)
            }
        case 91:
            offset += 1
            space()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
            while true {
                try value(depth: depth + 1)
                space()
                guard offset < bytes.count else { throw ManagementError.invalidPayload }
                if bytes[offset] == 93 { offset += 1; return }
                try consume(44)
            }
        default:
            let start = offset
            while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw ManagementError.invalidPayload }
        }
    }
}

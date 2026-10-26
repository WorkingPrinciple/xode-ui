// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CalimochoIndexError: Error, LocalizedError {
    case invalid(String)
    case rejected(String)

    var reasonCode: String {
        switch self {
        case .invalid: "schema"
        case .rejected(let code): code
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Calimocho update information wasn't accepted: \(reason)"
        case .rejected(let code): "Calimocho update information wasn't accepted (\(code))."
        }
    }
}

indirect enum CalimochoIndexJSON: Equatable {
    case object([String: Self]), array([Self]), string(String), number(String), boolean(Bool), null

    static func parse(_ data: Data, limit: Int) throws -> Self {
        guard data.count <= limit, String(data: data, encoding: .utf8) != nil else {
            throw CalimochoIndexError.invalid("JSON size or encoding")
        }
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else {
            throw CalimochoIndexError.invalid("trailing JSON")
        }
        return result
    }

    func object(_ required: Set<String>, optional: Set<String> = []) throws -> [String: Self] {
        guard case .object(let fields) = self, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)) else {
            throw CalimochoIndexError.invalid("object fields")
        }
        return fields
    }

    func array(min: Int = 0, max: Int) throws -> [Self] {
        guard case .array(let values) = self, (min...max).contains(values.count) else {
            throw CalimochoIndexError.invalid("array bounds")
        }
        return values
    }

    func text(_ pattern: String? = nil, min: Int = 1, max: Int = 4096) throws -> String {
        guard case .string(let value) = self,
              (min...max).contains(value.unicodeScalars.count),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw CalimochoIndexError.invalid("string")
        }
        if let pattern {
            let regex = try NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard regex.firstMatch(in: value, range: range)?.range == range else {
                throw CalimochoIndexError.invalid("string pattern")
            }
        }
        return value
    }

    func integer(min: Int = 1, max: Int = 2_147_483_647) throws -> Int {
        guard case .number(let token) = self,
              token.range(of: #"\A-?(?:0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil,
              let number = Int(token),
              (min...max).contains(number) else {
            throw CalimochoIndexError.invalid("integer bounds")
        }
        return number
    }

    func equals(_ expected: String) throws {
        guard try text() == expected else { throw CalimochoIndexError.invalid("constant") }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        mutating func value(depth: Int) throws -> CalimochoIndexJSON {
            whitespace()
            guard depth <= 32, offset < bytes.count else {
                throw CalimochoIndexError.invalid("JSON depth or truncation")
            }
            if consume(123) {
                var fields: [String: CalimochoIndexJSON] = [:]
                whitespace()
                if consume(125) { return .object(fields) }
                repeat {
                    whitespace()
                    let key = try string()
                    whitespace()
                    guard fields[key] == nil else { throw CalimochoIndexError.rejected("duplicate_key") }
                    guard consume(58) else { throw CalimochoIndexError.invalid("missing colon") }
                    fields[key] = try value(depth: depth + 1)
                    whitespace()
                    if consume(125) { return .object(fields) }
                    guard consume(44) else { throw CalimochoIndexError.invalid("JSON object") }
                } while true
            }
            if consume(91) {
                var values: [CalimochoIndexJSON] = []
                whitespace()
                if consume(93) { return .array(values) }
                repeat {
                    values.append(try value(depth: depth + 1))
                    whitespace()
                    if consume(93) { return .array(values) }
                    guard consume(44) else { throw CalimochoIndexError.invalid("JSON array") }
                } while true
            }
            if bytes[offset] == 34 { return .string(try string()) }
            for (token, result) in [("true", CalimochoIndexJSON.boolean(true)),
                                    ("false", .boolean(false)), ("null", .null)] {
                let literal = Array(token.utf8)
                if bytes[offset...].starts(with: literal) {
                    offset += literal.count
                    return result
                }
            }
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) {
                offset += 1
            }
            let token = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard token.range(of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
                              options: .regularExpression) != nil else {
                throw CalimochoIndexError.invalid("JSON number or literal")
            }
            return .number(token)
        }

        mutating func string() throws -> String {
            let start = offset
            guard consume(34) else { throw CalimochoIndexError.invalid("JSON string") }
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                }
                if byte == 92 {
                    guard offset < bytes.count else { break }
                    offset += 1
                }
            }
            throw CalimochoIndexError.invalid("unterminated JSON string")
        }
    }
}

extension Dictionary where Key == String, Value == CalimochoIndexJSON {
    func field(_ key: String) throws -> Value {
        guard let value = self[key] else { throw CalimochoIndexError.invalid("missing \(key)") }
        return value
    }
}

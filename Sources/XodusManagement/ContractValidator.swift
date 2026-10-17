// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Evaluates the vocabulary actually used by the pinned producer schema, not arbitrary schemas.
public struct ContractValidator: Sendable {
    private let root: JSONValue

    public init() throws {
        guard let url = Bundle.module.url(forResource: "management-v1.schema", withExtension: "json") else {
            throw ManagementError.unsupportedSchema
        }
        try self.init(schemaURL: url, schemaIdentifier: "urn:xodus:management:1.0")
    }

    public init(schemaURL: URL, schemaIdentifier: String) throws {
        do { root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: schemaURL)) }
        catch { throw ManagementError.unsupportedSchema }
        guard root["$id"]?.string == schemaIdentifier else {
            throw ManagementError.unsupportedSchema
        }
    }

    public func validate(_ value: JSONValue) throws {
        guard matches(value, schema: root, depth: 0) else { throw ManagementError.invalidFrame }
    }

    public func validate(_ value: JSONValue, definition: String) throws {
        guard let schema = root["$defs"]?[definition] else { throw ManagementError.unsupportedSchema }
        guard matches(value, schema: schema, depth: 0) else { throw ManagementError.invalidPayload }
    }

    private func matches(_ value: JSONValue, schema: JSONValue, depth: Int) -> Bool {
        guard depth < 64, let rules = schema.object else { return false }
        if let reference = rules["$ref"]?.string {
            guard reference.hasPrefix("#/$defs/"),
                  let target = root["$defs"]?[String(reference.dropFirst(8))],
                  matches(value, schema: target, depth: depth + 1) else { return false }
        }
        if let constant = rules["const"], !equal(value, constant) { return false }
        if let excluded = rules["not"], matches(value, schema: excluded, depth: depth + 1) { return false }
        if let options = rules["enum"]?.array, !options.contains(where: { equal(value, $0) }) { return false }
        if let types = rules["type"] {
            let names = types.array ?? [types]
            if !names.contains(where: { hasType(value, name: $0.string ?? "") }) { return false }
        }
        if let choices = rules["oneOf"]?.array,
           choices.filter({ matches(value, schema: $0, depth: depth + 1) }).count != 1 { return false }
        if let choices = rules["anyOf"]?.array,
           !choices.contains(where: { matches(value, schema: $0, depth: depth + 1) }) { return false }
        if let choices = rules["allOf"]?.array,
           !choices.allSatisfy({ matches(value, schema: $0, depth: depth + 1) }) { return false }
        if let condition = rules["if"] {
            let branch = matches(value, schema: condition, depth: depth + 1) ? rules["then"] : rules["else"]
            if let branch, !matches(value, schema: branch, depth: depth + 1) { return false }
        }
        if let object = value.object {
            let required = rules["required"]?.array?.compactMap(\.string) ?? []
            if !required.allSatisfy({ object[$0] != nil }) { return false }
            let properties = rules["properties"]?.object ?? [:]
            if rules["additionalProperties"] == .bool(false),
               !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
            for (key, item) in object {
                if let fieldSchema = properties[key],
                   !matches(item, schema: fieldSchema, depth: depth + 1) { return false }
            }
        }
        if let array = value.array {
            if let max = rules["maxItems"]?.uint64, UInt64(array.count) > max { return false }
            if let min = rules["minItems"]?.uint64, UInt64(array.count) < min { return false }
            if let items = rules["items"],
               !array.allSatisfy({ matches($0, schema: items, depth: depth + 1) }) { return false }
            if let contains = rules["contains"] {
                let count = UInt64(array.filter { matches($0, schema: contains, depth: depth + 1) }.count)
                if count < (rules["minContains"]?.uint64 ?? 1) { return false }
                if let maximum = rules["maxContains"]?.uint64, count > maximum { return false }
            }
        }
        if let string = value.string {
            let length = UInt64(string.unicodeScalars.count)
            if let min = rules["minLength"]?.uint64, length < min { return false }
            if let max = rules["maxLength"]?.uint64, length > max { return false }
            if let pattern = rules["pattern"]?.string {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else {
                    return false
                }
            }
            if rules["format"]?.string == "date-time", !Self.validDate(string) { return false }
            if rules["format"]?.string == "uuid",
               string.count != 36 || UUID(uuidString: string) == nil { return false }
        }
        if let number = value.decimal {
            if let min = rules["minimum"]?.decimal, number < min { return false }
            if let max = rules["maximum"]?.decimal, number > max { return false }
        }
        return true
    }

    private func hasType(_ value: JSONValue, name: String) -> Bool {
        switch (name, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
             ("null", .null), ("integer", .integer), ("integer", .unsigned),
             ("number", .integer), ("number", .unsigned), ("number", .number): true
        case ("integer", .number(let n)): n.isFinite && n.rounded() == n
        default: false
        }
    }

    private func equal(_ left: JSONValue, _ right: JSONValue) -> Bool {
        if let l = left.decimal, let r = right.decimal { return l == r }
        return left == right
    }

    public static func validDate(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

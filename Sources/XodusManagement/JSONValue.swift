// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    public var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    public var boolean: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public var uint64: UInt64? {
        switch self {
        case .unsigned(let v): return v
        case .integer(let v) where v >= 0: return UInt64(v)
        default: return nil
        }
    }
    var decimal: Decimal? {
        switch self {
        case .integer(let v): Decimal(string: String(v))
        case .unsigned(let v): Decimal(string: String(v))
        case .number(let v): v.isFinite ? Decimal(string: String(v)) : nil
        default: nil
        }
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
        catch { throw ManagementError.invalidPayload }
    }
}

public enum ManagementError: Error, Equatable, Sendable, LocalizedError {
    case invalidFrame, invalidPayload, invalidRequest, frameTooLarge, truncatedFrame, unsupportedSchema
    case backendUnavailable, nativeAuthHostUnavailable, pairedEngineUnavailable, startFailed, alreadyConnected, disconnected, outputOverflow, credentialStoreUnavailable
    case requestTimedOut, unexpectedResult, writeFailed, capabilityMissing(String)
    case shutdownFailed
    case backendStopped(Int32), backendError(String, retryable: Bool), invalidEvent
    case discoveryFailed(CatalogDiscovery)
    case queryFailed(CatalogQuery)
    case authenticatedReadFailed(AuthenticatedReadFailure)
    case recentLibraryFailed(RecentLibraryFailure)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame, .invalidPayload:
            "Xodus returned an invalid management response. Update the paired app and engine."
        case .invalidRequest:
            "This input does not match the engine's management contract. Check the selected scope and values."
        case .frameTooLarge, .outputOverflow:
            "The engine exceeded its output limit. The connection was stopped safely."
        case .truncatedFrame: "The engine ended a response before it was complete. Reconnect to recover."
        case .unsupportedSchema: "The bundled management contract is unavailable or incompatible."
        case .backendUnavailable: "Choose an executable Xodus management build in Settings."
        case .nativeAuthHostUnavailable:
            "This app's native sign-in helper is missing or does not match its recorded version and hash. Rebuild or reinstall the paired development app. No sign-in was started."
        case .pairedEngineUnavailable:
            "This app has no approved matching engine and sign-in helper, or the bundled files have changed. Install an approved paired build. No engine or sign-in was started."
        case .credentialStoreUnavailable:
            "Xodus cannot access your Mac's Keychain. Review its native permission prompt or unlock the Keychain, then check status again. Your saved credentials were not replaced."
        case .startFailed: "The Xodus engine could not start. Check the selected build and state directory."
        case .alreadyConnected: "An engine is already connected."
        case .disconnected: "The Xodus connection ended. Reconnect before taking another action."
        case .requestTimedOut: "Xodus did not respond in time. Reconnect to recover its durable state."
        case .unexpectedResult: "Xodus returned a response for an unexpected request. The connection was stopped."
        case .writeFailed: "The request could not reach Xodus. Reconnect before retrying."
        case .shutdownFailed: "Xodus has not finished shutting down. Wait, then reconnect or try closing again; another engine was not started."
        case .capabilityMissing(let command): "This engine does not provide \(command)."
        case .backendStopped(let status): "The Xodus engine stopped (exit \(status)). Reconnect to recover."
        case .backendError(let code, _): "Xodus reported \(code). No success was assumed."
        case .discoveryFailed: "The attempted public products could not be checked. Their failures are listed; no empty owned library or successful discovery was assumed."
        case .queryFailed: "The Store search results could not be checked. Their failures are listed; no successful empty search or ownership was assumed."
        case .authenticatedReadFailed(let failure): failure.message
        case .recentLibraryFailed(let failure): failure.message
        case .invalidEvent: "The activity stream is inconsistent. Reload the authoritative snapshot."
        }
    }
}

public struct JSONLineFramer: Sendable {
    public static let maximumBytes = 1_048_576
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 10 {
                guard !pending.isEmpty else { throw ManagementError.invalidFrame }
                lines.append(pending)
                pending = Data()
            } else {
                guard pending.count < Self.maximumBytes else { throw ManagementError.frameTooLarge }
                pending.append(byte)
            }
        }
        return lines
    }

    public func finish() throws {
        guard pending.isEmpty else { throw ManagementError.truncatedFrame }
    }
}

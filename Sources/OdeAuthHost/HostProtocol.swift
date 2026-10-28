// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum HostDisposition: String, Sendable {
    case completed, cancelled, failed
    var exitCode: Int32 { self == .completed ? 0 : self == .cancelled ? 2 : 1 }
}

enum HostCommand: Sendable {
    case open(remainingMillis: UInt64, request: URLRequest, userAgent: String)
    case navigate(URL)
    case close(HostDisposition)
}

struct CommandFrame: Sendable {
    let flowID: String
    let sequence: UInt64
    let command: HostCommand

    init(_ data: Data) throws {
        let envelope = try PrivateJSON.parse(data).object(
            keys: ["version", "flowID", "sessionID", "sequence", "message"])
        guard envelope["version"]?.unsigned == 1, envelope["sessionID"]?.unsigned == 1,
              let flowID = envelope["flowID"]?.string, HostPolicy.validFlow(flowID),
              let sequence = envelope["sequence"]?.unsigned, (1...HostPolicy.maximumSequence).contains(sequence),
              case .object(let message) = envelope["message"],
              let kind = message["kind"]?.string else { throw HostFailure.protocolInvalid }
        self.flowID = flowID
        self.sequence = sequence
        switch kind {
        case "open":
            guard Set(message.keys) == ["kind", "remainingMillis", "url", "headers", "userAgent"],
                  let remaining = message["remainingMillis"]?.unsigned, (1...600_000).contains(remaining),
                  let rawURL = message["url"]?.string, HostPolicy.initial(rawURL),
                  let url = URL(string: rawURL), let headers = message["headers"],
                  message["userAgent"]?.string == HostPolicy.userAgent else { throw HostFailure.protocolInvalid }
            let object = try headers.object(keys: Set(HostPolicy.headers.keys).union(["cxh-correlationid"]))
            var request = URLRequest(url: url)
            for (key, value) in object {
                guard let text = value.string else { throw HostFailure.protocolInvalid }
                if key == "cxh-correlationid" {
                    guard HostPolicy.validFlow(text) else { throw HostFailure.protocolInvalid }
                } else if text != HostPolicy.headers[key] { throw HostFailure.protocolInvalid }
                request.setValue(text, forHTTPHeaderField: key)
            }
            command = .open(remainingMillis: remaining, request: request, userAgent: HostPolicy.userAgent)
        case "navigate":
            guard Set(message.keys) == ["kind", "url"], let rawURL = message["url"]?.string,
                  let url = URL(string: rawURL), HostPolicy.navigation(url) else {
                throw HostFailure.protocolInvalid
            }
            command = .navigate(url)
        case "close":
            guard Set(message.keys) == ["kind", "disposition"],
                  let raw = message["disposition"]?.string, let disposition = HostDisposition(rawValue: raw) else {
                throw HostFailure.protocolInvalid
            }
            command = .close(disposition)
        default: throw HostFailure.protocolInvalid
        }
    }
}

enum HostResult {
    case ready, da(LegacyDA), closed(HostDisposition), cancelled, failed(HostFailure)

    var message: PrivateValue {
        switch self {
        case .ready: .object(["kind": .string("ready")])
        case .da(let data): .object(["kind": .string("da"), "property": data.value])
        case .closed(let disposition):
            .object(["kind": .string("closed"), "disposition": .string(disposition.rawValue)])
        case .cancelled: .object(["kind": .string("cancelled")])
        case .failed(let failure):
            .object(["kind": .string("failed"), "reason": .string(failure.wireReason)])
        }
    }
}

extension HostFailure {
    var wireReason: String {
        switch self {
        case .protocolInvalid: "invalidFrame"
        case .channelClosed: "parentUnavailable"
        case .deadlineExpired: "deadlineExpired"
        case .navigationFailed: "navigationFailed"
        case .rendererTerminated: "contentTerminated"
        case .bridgeInvalid: "bridgeInvalid"
        case .javaScriptFailed: "javaScriptFailed"
        case .popupUnsupported: "popupUnsupported"
        case .cancelled: "parentUnavailable"
        }
    }
}

struct HostSession {
    private(set) var flowID: String?
    private(set) var controlSequence: UInt64 = 0
    private(set) var resultSequence: UInt64 = 0
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var terminal = false
    private var ready = false
    private var delivered = false
    private var continuations = 0
    private var closing: HostDisposition?

    mutating func accept(_ frame: CommandFrame, now: ContinuousClock.Instant = .now) throws {
        guard !terminal, frame.sequence == controlSequence + 1,
              flowID == nil || frame.flowID == flowID else { throw HostFailure.protocolInvalid }
        if let deadline, now >= deadline { throw HostFailure.deadlineExpired }
        switch frame.command {
        case .open(let remaining, _, _):
            guard flowID == nil && controlSequence == 0 else { throw HostFailure.protocolInvalid }
            flowID = frame.flowID
            deadline = now.advanced(by: .milliseconds(Int64(remaining)))
        case .navigate:
            guard delivered, closing == nil, continuations < 4 else { throw HostFailure.protocolInvalid }
            continuations += 1
        case .close(let disposition):
            guard flowID != nil, closing == nil,
                  disposition != .completed || delivered else { throw HostFailure.protocolInvalid }
            closing = disposition
        }
        controlSequence = frame.sequence
        ready = false
        delivered = false
    }

    mutating func encode(_ result: HostResult, now: ContinuousClock.Instant = .now) throws -> Data {
        guard let flowID, !terminal, resultSequence < HostPolicy.maximumSequence else {
            throw HostFailure.protocolInvalid
        }
        var nextState = self
        switch result {
        case .ready:
            guard !ready, closing == nil, let deadline else {
                throw HostFailure.protocolInvalid
            }
            guard now < deadline else { throw HostFailure.deadlineExpired }
            nextState.ready = true
        case .da:
            guard ready, !delivered, closing == nil, let deadline else {
                throw HostFailure.protocolInvalid
            }
            guard now < deadline else { throw HostFailure.deadlineExpired }
            nextState.delivered = true
        case .closed(let disposition):
            guard closing == disposition, let deadline else {
                throw HostFailure.protocolInvalid
            }
            guard now < deadline else { throw HostFailure.deadlineExpired }
            nextState.terminal = true
        case .cancelled, .failed: nextState.terminal = true
        }
        let next = resultSequence + 1
        let data = try PrivateValue.object([
            "version": .number("1"), "flowID": .string(flowID), "sessionID": .number("1"),
            "sequence": .number(String(next)), "replyTo": .number(String(controlSequence)),
            "message": result.message
        ]).encoded()
        guard data.count <= PrivateJSON.maximumBytes else { throw HostFailure.protocolInvalid }
        nextState.resultSequence = next
        self = nextState
        return data
    }
}

enum HostPolicy {
    static let maximumSequence: UInt64 = 9_007_199_254_740_991
    static let initialURL = "https://login.live.com/ppsecure/InlineLogin.srf?id=80604&scid=3&mkt=en-US&Platform=Windows10&clientid=000000004424da1f&hosted=1"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; MSAppHost/3.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.26100"
    static let headers = [
        "cxh-capabilities": LegacyBridge.capabilities,
        "cxh-msabinaryversion": "55", "cxh-identityclientbinaryversion": "3",
        "cxh-osversioninfo": #"{"platformId":2,"majorVersion":10,"minorVersion":0,"buildNumber":26100}"#,
        "cxh-platform": "CloudExperienceHost.Platform.DESKTOP",
        "cxh-protocol": "TokenBroker", "cxh-source": "TokenBroker", "hostapp": "CloudExperienceHost"
    ]

    static func validFlow(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#,
                    options: .regularExpression) != nil
    }

    static func navigation(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              let encodedHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost,
              !encodedHost.contains("%") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("xn--")
                && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return false }
        return ["live.com", "microsoft.com", "microsoftonline.com", "msauth.net", "msftauth.net", "live.net"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func initial(_ value: String) -> Bool {
        guard let url = URL(string: value), navigation(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        if parts.port == 443 { parts.port = nil }
        return parts.string == initialURL
    }

    static func bridge(_ url: URL) -> Bool { navigation(url) && url.host?.lowercased() == "login.live.com" }
    static func finish(_ url: URL) -> Bool {
        bridge(url)
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/ppsecure/post.srf"
    }
}

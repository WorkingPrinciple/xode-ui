// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct LegacyDA: Equatable, Sendable {
    static let keys: Set<String> = ["sDAToken", "sDASessionKey", "sDAStartTime", "sDAExpires",
                                    "sSTSInlineFlowToken", "sSigninName", "K"]
    let fields: [String: String]

    init(_ value: PrivateValue) throws {
        let object = try value.object(keys: Self.keys)
        var fields: [String: String] = [:]
        for (key, value) in object {
            guard let string = value.string else { throw HostFailure.bridgeInvalid }
            fields[key] = string
        }
        self.fields = fields
    }

    var value: PrivateValue { .object(fields.mapValues(PrivateValue.string)) }
}

enum LegacyNotification: Equatable {
    case context(String)
    case da(LegacyDA)
    case ignored

    init(_ value: PrivateValue) throws {
        guard case .object(let object) = value else { self = .ignored; return }
        if LegacyDA.keys.isSubset(of: Set(object.keys)) {
            self = .da(try Self.property(value))
            return
        }
        if let property = object["DAProperty"] {
            self = .da(try Self.property(property))
            return
        }
        guard object["type"]?.string == "invoke", case .object(let fields) = object["value"],
              fields["name"]?.string == "CloudExperienceHost.getContext",
              let context = fields["context"]?.string else { self = .ignored; return }
        self = .context(context)
    }

    init(raw: String) throws {
        let data = Data(raw.utf8)
        guard data.count <= PrivateJSON.maximumBytes else { throw HostFailure.bridgeInvalid }
        let value: PrivateValue
        do { value = try PrivateJSON.parse(data) }
        catch HostFailure.protocolInvalid { self = .ignored; return }
        try self.init(value)
    }

    private static func property(_ value: PrivateValue) throws -> LegacyDA {
        guard case .object(let object) = value, LegacyDA.keys.isSubset(of: Set(object.keys)) else {
            throw HostFailure.bridgeInvalid
        }
        return try LegacyDA(.object(object.filter { LegacyDA.keys.contains($0.key) }))
    }
}

enum LegacyBridge {
    static let handler = "xodusPrivateAuth"
    static let capabilities = #"{"PrivatePropertyBag":1,"PasswordlessConnect":1,"PreferAssociate":1,"ChromelessUI":0}"#
    static func injection(navigation: UInt64) -> String {
        """
    (() => {
      const id = crypto.randomUUID();
      Object.defineProperty(window, "__xodusAuthDocument", { value: id });
      window.external = { notify: raw => {
        if (typeof raw !== "string") throw new TypeError("Invalid native bridge input");
        window.webkit.messageHandlers.xodusPrivateAuth.postMessage(
          JSON.stringify({ navigation: \(navigation), document: id, message: raw }));
      }};
      if (typeof window.external.notify !== "function") throw new TypeError("Native bridge unavailable");
    })();
    """
    }
    static let dispatch = """
    if (window.__xodusAuthDocument !== document) return false;
    const dispatch = window["CloudExperienceHost.Bridge.dispatchMessage"];
    if (typeof dispatch !== "function") throw new TypeError("Native bridge unavailable");
    window["CloudExperienceHost.Bridge.dispatchMessage"](callback);
    return true;
    """
    static let validateDocument = "return window.__xodusAuthDocument === document;"
    static let verifyBridge = """
    return typeof window.__xodusAuthDocument === "string"
        && typeof window.external.notify === "function";
    """
    static let extract = """
    const container = typeof ServerData === "object" && ServerData !== null ? ServerData : null;
    if (!container || Array.isArray(container)) throw new TypeError("Native result unavailable");
    const keys = ["sDAToken", "sDASessionKey", "sDAStartTime", "sDAExpires",
                  "sSTSInlineFlowToken", "sSigninName", "K"];
    const source = keys.every(key => Object.prototype.hasOwnProperty.call(container, key))
        ? container : container.DAProperty;
    if (!source || typeof source !== "object" || Array.isArray(source))
      throw new TypeError("Native result unavailable");
    const result = {};
    for (const key of keys) {
      if (typeof source[key] !== "string") throw new TypeError("Invalid native result");
      result[key] = source[key];
    }
    return JSON.stringify(result);
    """

    static func callback(context: String) throws -> String {
        let value = PrivateValue.object([
            "type": .string("callback"),
            "value": .object([
                "name": .string("CloudExperienceHost.getContext"),
                "args": .array(["CloudExperienceHost", "TokenBroker", "TokenBroker", capabilities]
                    .map(PrivateValue.string)),
                "context": .string(context)
            ])
        ])
        let data = try value.encoded()
        guard data.count <= PrivateJSON.maximumBytes, let json = String(data: data, encoding: .utf8) else {
            throw HostFailure.bridgeInvalid
        }
        return json
    }
}

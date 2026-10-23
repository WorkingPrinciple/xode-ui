// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

extension Checks {
    func odeAccountChecks() throws {
        let validator = try ContractValidator()
        let account = String(repeating: "a", count: 64)
        let params: JSONValue = .object([
            "section": .string("library"), "accountHash": .string(account),
            "market": .string("US"), "language": .string("en-US"), "titleID": .null
        ])
        try validator.validate(params, definition: "odeAccountParams")
        for (key, invalid) in [
            ("accountHash", JSONValue.string("someone@example.invalid")),
            ("section", .string("token")), ("titleID", .string("1")),
            ("token", .string("synthetic-must-not-cross-wire")), ("market", .string("../US"))
        ] {
            var object = params.object!
            object[key] = invalid
            do {
                try validator.validate(.object(object), definition: "odeAccountParams")
                check(false, "Unified request rejects invalid \(key)")
            } catch { check(true, "Unified request rejects invalid \(key)") }
        }
        let data: JSONValue = .object([
            "section": .string("library"), "accountHash": .string(account),
            "checkedAt": .string("2026-10-19T12:00:00Z"), "payload": .object(["items": .array([])])
        ])
        try validator.validate(data, definition: "odeAccountData")
        let read = try data.decode(OdeAccountRead.self)
        try read.validate(section: .library, accountHash: account)
        try read.payload.decode(OdeAccountCollection.self).validate()
        check(true, "Unified empty collection has a typed account-bound result, not token or recent-history data")
        for (section, identity) in [(OdeAccountSection.profile, account), (.library, String(repeating: "b", count: 64))] {
            do {
                try read.validate(section: section, accountHash: identity)
                check(false, "Unified result must match requested section and account")
            } catch { check(true, "Unified result must match requested section and account") }
        }
        for invalidPayload in [
            JSONValue.object(["items": .array([]), "refreshToken": .string("synthetic")]),
            .object(["items": .array([.object(["productID": .string("../escape"),
                                             "acquisitionKind": .string("purchased")])])])
        ] {
            var object = data.object!
            object["payload"] = invalidPayload
            do {
                try validator.validate(.object(object), definition: "odeAccountData")
                check(false, "Unified result rejects credential fields and malformed product identity")
            } catch { check(true, "Unified result rejects credential fields and malformed product identity") }
        }
        let duplicate: JSONValue = .object(["items": .array(Array(repeating: .object([
            "productID": .string("FIXTURE00001"), "acquisitionKind": .string("purchased")
        ]), count: 2))])
        do {
            try duplicate.decode(OdeAccountCollection.self).validate()
            check(false, "Unified collection rejects duplicate identities before dictionary construction")
        } catch { check(true, "Unified collection rejects duplicate identities before dictionary construction") }
        let checkedAt = "2026-10-23T10:00:00Z"
        let now = ISO8601DateFormatter().date(from: checkedAt)!
        func access(_ state: String, reason: String? = nil, expiry: String? = nil,
                    productID: String = "FIXTURE00001") throws -> OdeProductAccess {
            try JSONValue.object([
                "productID": .string(productID), "access": .string(state),
                "reason": reason.map(JSONValue.string) ?? .null,
                "expiresAt": expiry.map(JSONValue.string) ?? .null
            ]).decode(OdeProductAccess.self)
        }
        for expiry in [nil, "2026-10-23T11:00:00Z"] {
            let value = try access("permitted", expiry: expiry)
            try value.validate(productID: "FIXTURE00001", checkedAt: checkedAt)
            check(value.permitsAccess(at: now), "Exact valid product grant permits access without inferring purchase or subscription")
        }
        let expiring = try access("permitted", expiry: "2026-10-23T11:00:00Z")
        check(!expiring.permitsAccess(at: now.addingTimeInterval(3600)),
              "A previously permitted product grant stops authorizing at its actual expiry")
        for reason in ["productNotListed", "validityUnavailable", "grantExpired", "grantNotStarted"] {
            let value = try access("unknown", reason: reason)
            try value.validate(productID: "FIXTURE00001", checkedAt: checkedAt)
            check(!value.permitsAccess(at: now), "Unknown product access (\(reason)) never grants access or becomes denial")
        }
        let denied = try access("denied", reason: "providerDenied")
        try denied.validate(productID: "FIXTURE00001", checkedAt: checkedAt)
        check(!denied.permitsAccess(at: now), "Explicit provider denial never grants access")
        for invalid in [
            try access("permitted", reason: "providerDenied"),
            try access("permitted", expiry: "2026-10-23T09:59:59Z"),
            try access("permitted", expiry: "invalid"),
            try access("permitted", productID: "FIXTURE00002"),
            try access("denied"), try access("unknown"),
            try access("unknown", reason: "providerDenied")
        ] {
            do {
                try invalid.validate(productID: "FIXTURE00001", checkedAt: checkedAt)
                check(false, "Invalid or mismatched product-access fact is rejected")
            } catch { check(true, "Invalid or mismatched product-access fact is rejected") }
        }
        var licenseParams = params.object!
        licenseParams["section"] = .string("license")
        licenseParams["productID"] = .string("FIXTURE00001")
        try validator.validate(.object(licenseParams), definition: "odeAccountParams")
        check(true, "Bundled exact producer schema accepts the additive license request")
        for (key, invalid) in [
            ("productID", JSONValue.string("fixture00001")),
            ("productID", .string("SHORT")), ("titleID", .string("42")),
            ("token", .string("synthetic")), ("section", .string("library"))
        ] {
            var request = licenseParams
            request[key] = invalid
            do {
                try validator.validate(.object(request), definition: "odeAccountParams")
                check(false, "License schema rejects invalid \(key)")
            } catch { check(true, "License schema rejects invalid \(key)") }
        }
        for (state, reason) in [
            ("permitted", Optional<String>.none), ("denied", "providerDenied"),
            ("unknown", "productNotListed"), ("unknown", "validityUnavailable"),
            ("unknown", "grantExpired"), ("unknown", "grantNotStarted")
        ] {
            let payload: JSONValue = .object([
                "productID": .string("FIXTURE00001"), "access": .string(state),
                "expiresAt": .null, "reason": reason.map(JSONValue.string) ?? .null
            ])
            let envelope: JSONValue = .object([
                "section": .string("license"), "accountHash": .string(account),
                "checkedAt": .string(checkedAt), "payload": payload
            ])
            try validator.validate(envelope, definition: "odeAccountData")
            check(true, "Swift contract validator admits typed license \(state)/\(reason ?? "null")")
            for (key, invalid) in [
                ("token", JSONValue.string("synthetic")), ("reason", .string("invented")),
                ("expiresAt", .string("not-a-date"))
            ] {
                var bad = payload.object!
                bad[key] = invalid
                var result = envelope.object!
                result["payload"] = .object(bad)
                do {
                    try validator.validate(.object(result), definition: "odeAccountData")
                    check(false, "License payload schema rejects \(key) for \(state)")
                } catch { check(true, "License payload schema rejects \(key) for \(state)") }
            }
        }
    }
}

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
    }
}

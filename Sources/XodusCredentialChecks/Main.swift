// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import Security
import XodusCredentials

@main
enum CredentialChecks {
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--self-check"] {
            var count = 0
            func check(_ condition: Bool) throws {
                guard condition else { throw CredentialFailure.invalid }
                count += 1
            }
            for operation in [CredentialOperation.read, .write, .delete, .migrate] {
                let request = CredentialRequest(operation: operation, value: operation == .write ? "neutral" : nil)
                let decoded = try CredentialRequest(data: request.encoded())
                try check(decoded.id == request.id && decoded.operation == operation && decoded.value == request.value)
                let response = CredentialResponse(id: request.id)
                try check(try CredentialResponse(data: response.encoded(), request: request).status == 0)
            }
            for data in [Data(), Data([2]), Data(repeating: 0, count: CredentialWire.maximumToken + 44)] {
                do { _ = try CredentialRequest(data: data); throw NSError(domain: "unexpected accept", code: 1) }
                catch CredentialFailure.invalid { count += 1 }
            }
            let read = CredentialRequest(operation: .read)
            let result = CredentialResponse(id: read.id, present: true, value: "neutral")
            try check(try CredentialResponse(data: result.encoded(), request: read).value == "neutral")
            do {
                _ = try CredentialResponse(data: result.encoded(), request: CredentialRequest(operation: .read))
                throw NSError(domain: "request ID accepted", code: 1)
            } catch CredentialFailure.invalid { count += 1 }
            for request in [
                CredentialRequest(operation: .write),
                CredentialRequest(operation: .read, value: "not permitted"),
                CredentialRequest(operation: .delete, presenceOnly: true),
                CredentialRequest(operation: .write, value: String(repeating: "a", count: CredentialWire.maximumToken + 1))
            ] {
                do { _ = try request.encoded(); throw NSError(domain: "invalid operation accepted", code: 1) }
                catch CredentialFailure.invalid { count += 1 }
            }
            var sockets: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw CredentialFailure.unavailable }
            defer { close(sockets[0]); close(sockets[1]) }
            try CredentialWire.validateSocket(sockets[0])
            try CredentialWire.validateSocket(sockets[1])
            try CredentialWire.write(read.encoded(), to: sockets[0], deadline: .now.advanced(by: .seconds(1)))
            let framed = try CredentialRequest(data: CredentialWire.read(sockets[1], deadline: .now.advanced(by: .seconds(1))))
            try check(framed.id == read.id && framed.operation == .read)
            do {
                _ = try CredentialWire.read(sockets[0], deadline: .now.advanced(by: .milliseconds(20)))
                throw NSError(domain: "missing frame accepted", code: 1)
            } catch CredentialFailure.timeout { count += 1 }
            print("\(count) credential wire checks passed; no Keychain access.")
            return
        }
        #if XODUS_CREDENTIAL_SYNTHETIC
        #if XODUS_CREDENTIAL_BUILD_B
        print("Synthetic signed client build B.")
        #else
        print("Synthetic signed client build A.")
        #endif
        guard CommandLine.arguments.count == 7,
              CommandLine.arguments[1] == "--synthetic",
              let bytes = Int(CommandLine.arguments[4]) else { throw CredentialFailure.invalid }
        let broker = CredentialBrokerClient(
            executable: URL(fileURLWithPath: CommandLine.arguments[2]),
            pin: CredentialBrokerPin(sha256: CommandLine.arguments[3], bytes: bytes),
            arguments: ["--synthetic-keychain", CommandLine.arguments[5]])
        let action = CommandLine.arguments[6]
        if ["seed-denied", "seed-foreign", "verify-legacy"].contains(action) {
            var keychain: SecKeychain?
            guard SecKeychainOpen(CommandLine.arguments[5], &keychain) == errSecSuccess, let keychain else {
                throw CredentialFailure.invalid
            }
            let value = Data("synthetic-legacy-not-a-credential".utf8)
            var identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Xodus B6 synthetic qualification", kSecAttrAccount as String: "xbox-web"]
            if action.hasPrefix("seed-") {
                if action == "seed-foreign" {
                    var creator: SecTrustedApplication?, helper: SecTrustedApplication?
                    var access: SecAccess?
                    guard SecTrustedApplicationCreateFromPath(nil, &creator) == errSecSuccess, let creator,
                          SecTrustedApplicationCreateFromPath(CommandLine.arguments[2], &helper) == errSecSuccess, let helper,
                          SecAccessCreate("Synthetic foreign legacy" as CFString,
                                          [creator, helper] as CFArray, &access) == errSecSuccess, let access else {
                        throw CredentialFailure.invalid
                    }
                    identity[kSecAttrAccess as String] = access
                }
                identity[kSecUseKeychain as String] = keychain
                identity[kSecValueData as String] = value
                guard SecItemAdd(identity as CFDictionary, nil) == errSecSuccess else { throw CredentialFailure.invalid }
            } else {
                identity[kSecMatchSearchList as String] = [keychain]
                identity[kSecReturnData as String] = true
                identity[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                var result: CFTypeRef?
                guard SecItemCopyMatching(identity as CFDictionary, &result) == errSecSuccess,
                      result as? Data == value else { throw CredentialFailure.invalid }
            }
            print("PASS synthetic \(action); legacy value never output.")
            return
        }
        let request: CredentialRequest
        switch action {
        case "write-A": request = CredentialRequest(operation: .write, value: "synthetic-value-A-not-a-credential")
        case "write-B": request = CredentialRequest(operation: .write, value: "synthetic-value-B-not-a-credential")
        case "seed-trusted": request = CredentialRequest(operation: .write, value: "synthetic-legacy-staged-not-a-credential")
        case "seed-retained": request = CredentialRequest(operation: .write, value: "synthetic-legacy-retained-not-a-credential")
        case "migrate-trusted": request = CredentialRequest(operation: .migrate)
        case "read-staged": request = CredentialRequest(operation: .read)
        case "read-retained", "read-foreign": request = CredentialRequest(operation: .read)
        case "read-A", "read-B", "denied": request = CredentialRequest(operation: .read)
        case "presence": request = CredentialRequest(operation: .read, presenceOnly: true)
        case "delete", "delete-refused": request = CredentialRequest(operation: .delete)
        case "migrate-denied": request = CredentialRequest(operation: .migrate)
        default: throw CredentialFailure.invalid
        }
        let response: CredentialResponse
        do {
            response = try await broker.send(request)
            if action == "denied" { throw NSError(domain: "unauthorized client accepted", code: 1) }
        } catch CredentialFailure.denied {
            guard action == "denied" else { throw CredentialFailure.denied }
            print("PASS broker rejected untrusted caller before Keychain operation; native exit 77.")
            return
        } catch CredentialFailure.keychain(let status) {
            if action == "delete-refused" && status == -25244 {
                print("PASS unapproved legacy deletion refused explicitly; native status -25244.")
                return
            }
            guard action == "migrate-denied", [-25293, -25308].contains(status) else {
                throw CredentialFailure.keychain(status)
            }
            print("PASS synthetic migration denied without UI; legacy retained, native status \(status).")
            return
        }
        if action == "migrate-denied" { throw CredentialFailure.invalid }
        if action == "delete-refused" { throw CredentialFailure.invalid }
        guard !response.migrationRequired || request.presenceOnly else { throw CredentialFailure.migrationRequired }
        if action == "read-A" {
            guard response.value == "synthetic-value-A-not-a-credential" else { throw CredentialFailure.invalid }
        }
        if action == "read-B" {
            guard response.value == "synthetic-value-B-not-a-credential" else { throw CredentialFailure.invalid }
        }
        if action == "read-staged" {
            guard response.value == "synthetic-legacy-staged-not-a-credential" else { throw CredentialFailure.invalid }
        }
        if action == "read-retained" {
            guard response.value == "synthetic-legacy-retained-not-a-credential", response.legacyRetained else {
                throw CredentialFailure.invalid
            }
        }
        if action == "read-foreign" {
            guard response.value == "synthetic-legacy-not-a-credential", !response.legacyRetained else {
                throw CredentialFailure.invalid
            }
        }
        if action == "presence" {
            print("Synthetic metadata present=\(response.present), migrationRequired=\(response.migrationRequired), legacyRetained=\(response.legacyRetained)")
        }
        print("PASS synthetic \(action); no value output.")
        #else
        throw CredentialFailure.invalid
        #endif
    }
}

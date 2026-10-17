// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security
import LocalAuthentication
import XodusCredentials

private struct CredentialStore {
    private struct Entry {
        let data: Data
        let item: SecKeychainItem
    }
    private let service: String
    private let keychain: SecKeychain?
    private let legacy = "xbox-web"
    private let owned = "xbox-web.credential-broker-v1"

    init() throws {
        #if XODUS_CREDENTIAL_SYNTHETIC
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--synthetic-keychain",
              CommandLine.arguments[2].hasSuffix("/Xodus-B6-broker-neutral.keychain-db") else {
            throw CredentialFailure.invalid
        }
        var result: SecKeychain?
        guard SecKeychainOpen(CommandLine.arguments[2], &result) == errSecSuccess, let result else {
            throw CredentialFailure.unavailable
        }
        keychain = result
        service = "Xodus B6 synthetic qualification"
        #else
        guard CommandLine.arguments.count == 1 else { throw CredentialFailure.invalid }
        keychain = nil
        service = "Xodus Library"
        #endif
    }

    private func identity(_ account: String) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        if let keychain { value[kSecMatchSearchList as String] = [keychain] }
        return value
    }

    private func presence(_ account: String) throws -> Bool {
        var query = identity(account)
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { return true }
        guard status == errSecSuccess else { throw CredentialFailure.keychain(status) }
        return true
    }

    private func read(_ account: String, approval: Bool = false) throws -> Entry? {
        var query = identity(account)
        query[kSecReturnData as String] = true
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if XODUS_CREDENTIAL_SYNTHETIC
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let context = LAContext()
        context.interactionNotAllowed = true
        #else
        query[kSecUseAuthenticationUI as String] = approval ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        let context = LAContext()
        context.interactionNotAllowed = !approval
        #endif
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialFailure.keychain(status) }
        guard let values = result as? [String: Any],
              let data = values[kSecValueData as String] as? Data,
              let ref = values[kSecValueRef as String],
              CFGetTypeID(ref as CFTypeRef) == SecKeychainItemGetTypeID(),
              !data.isEmpty, data.count <= CredentialWire.maximumToken,
              String(data: data, encoding: .utf8) != nil else { throw CredentialFailure.invalid }
        return Entry(data: data, item: ref as! SecKeychainItem)
    }

    private func save(_ data: Data, account: String) throws {
        var query = identity(account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var trusted: SecTrustedApplication?
            var access: SecAccess?
            guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let trusted,
                  SecAccessCreate("Xodus Library credential broker" as CFString,
                                  [trusted] as CFArray, &access) == errSecSuccess, let access else {
                throw CredentialFailure.unavailable
            }
            var item = identity(account)
            item.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { item[kSecUseKeychain as String] = keychain }
            item[kSecValueData as String] = data
            item[kSecAttrAccess as String] = access
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialFailure.keychain(added) }
        } else if status != errSecSuccess { throw CredentialFailure.keychain(status) }
        guard try read(account)?.data == data else { throw CredentialFailure.invalid }
    }

    private func delete(_ account: String) throws {
        var query = identity(account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialFailure.keychain(status) }
    }

    func perform(_ request: CredentialRequest) throws -> CredentialResponse {
        switch request.operation {
        case .read:
            let hasOwned = try presence(owned)
            let hasLegacy = try presence(legacy)
            if request.presenceOnly {
                return CredentialResponse(id: request.id, present: hasOwned || hasLegacy,
                                          migrationRequired: !hasOwned && hasLegacy,
                                          legacyRetained: hasOwned && hasLegacy)
            }
            if !hasOwned && hasLegacy { return CredentialResponse(id: request.id, present: true, migrationRequired: true) }
            let entry = try read(owned)
            return CredentialResponse(id: request.id, present: entry != nil,
                                      legacyRetained: entry != nil && hasLegacy,
                                      value: entry.flatMap { String(data: $0.data, encoding: .utf8) })
        case .write:
            guard let value = request.value else { throw CredentialFailure.invalid }
            let hasLegacy = try presence(legacy)
            if try !presence(owned) && hasLegacy {
                return CredentialResponse(id: request.id, present: true, migrationRequired: true)
            }
            #if XODUS_CREDENTIAL_SYNTHETIC
            let account = ["synthetic-legacy-staged-not-a-credential",
                           "synthetic-legacy-retained-not-a-credential"].contains(value) ? legacy : owned
            #else
            let account = owned
            #endif
            try save(Data(value.utf8), account: account)
            return CredentialResponse(id: request.id, present: true, legacyRetained: hasLegacy)
        case .delete:
            try delete(legacy)
            try delete(owned)
            return CredentialResponse(id: request.id)
        case .migrate:
            // Keep the old item until the broker-owned copy is durably readable without UI.
            if try presence(owned) {
                _ = try read(owned, approval: true)
                return CredentialResponse(id: request.id, present: true, legacyRetained: try presence(legacy))
            }
            if let existing = try read(legacy, approval: true) {
                try save(existing.data, account: owned)
                // SecItemDelete's app-name safety check cannot migrate a foreign creator.
                let canDelete = SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
                #if XODUS_CREDENTIAL_SYNTHETIC
                let injectFailure = existing.data == Data("synthetic-legacy-retained-not-a-credential".utf8)
                #else
                let injectFailure = false
                #endif
                let removed = canDelete && !injectFailure ? SecKeychainItemDelete(existing.item) : errSecInteractionNotAllowed
                if removed != errSecSuccess {
                    return CredentialResponse(id: request.id, present: true, legacyRetained: true)
                }
            }
            return CredentialResponse(id: request.id, present: try presence(owned))
        }
    }
}

@main
enum CredentialBrokerMain {
    static func main() {
        let fd = STDIN_FILENO
        do {
            try CredentialWire.validateSocket(fd)
            try CredentialIdentity.authenticatePeer(fd)
            let request = try CredentialRequest(data: CredentialWire.read(fd, deadline: .now.advanced(by: .seconds(30))))
            #if XODUS_CREDENTIAL_SYNTHETIC
            let allowed = false
            #else
            let allowed = request.operation == .migrate
            #endif
            guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
                throw CredentialFailure.unavailable
            }
            let lock = try lockStore()
            defer { flock(lock, LOCK_UN); close(lock) }
            try CredentialIdentity.authenticatePeer(fd)
            let response: CredentialResponse
            do { response = try CredentialStore().perform(request) }
            catch CredentialFailure.keychain(let status) { response = CredentialResponse(id: request.id, status: status) }
            catch { response = CredentialResponse(id: request.id, status: errSecParam) }
            try CredentialIdentity.authenticatePeer(fd)
            try CredentialWire.write(response.encoded(), to: fd, deadline: .now.advanced(by: .seconds(5)))
        } catch CredentialFailure.denied { exit(77) }
        catch { exit(1) }
    }

    private static func lockStore() throws -> Int32 {
        #if XODUS_CREDENTIAL_SYNTHETIC
        guard CommandLine.arguments.count == 3 else { throw CredentialFailure.invalid }
        let path = CommandLine.arguments[2] + ".broker-lock"
        #else
        let path = NSHomeDirectory() + "/Library/Application Support/Xodus/CredentialBroker/store.lock"
        #endif
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CredentialFailure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            close(fd)
            throw CredentialFailure.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                close(fd)
                throw CredentialFailure.unavailable
            }
            usleep(10_000)
        }
        return fd
    }
}

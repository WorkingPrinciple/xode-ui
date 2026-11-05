// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security
import XodusCredentials

actor PCGamesCredentialStore: PCGamesRefreshStore {
    private let direct: any PCGamesRefreshStore
    private let executable: URL
    private let manifest: URL
#if !XODUS_SHIPPING
    private var sandboxBroker: (@Sendable (CredentialRequest) async throws -> CredentialResponse)?
#endif

    init(direct: any PCGamesRefreshStore = PCGamesKeychain(),
         executable: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xodus/CredentialBroker/XodusCredentialBroker"),
         manifest: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/XodusCredentialBroker.json")) {
        self.executable = executable
        self.manifest = manifest
        self.direct = direct
    }

#if !XODUS_SHIPPING
    init(sandboxBroker: @escaping @Sendable (CredentialRequest) async throws -> CredentialResponse,
         direct: any PCGamesRefreshStore) {
        self.sandboxBroker = sandboxBroker
        self.direct = direct
        executable = URL(fileURLWithPath: "/unused-sandbox-broker")
        manifest = URL(fileURLWithPath: "/unused-sandbox-broker-manifest")
    }
#endif

    private func broker() throws -> CredentialBrokerClient? {
        var info = stat()
        if lstat(executable.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw PCGamesError.credentialBrokerUnavailable
        }
        do {
            let values = try manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size < 1024 else { throw CredentialFailure.invalid }
            let pin = try JSONDecoder().decode(CredentialBrokerPin.self, from: Data(contentsOf: manifest))
            return CredentialBrokerClient(executable: executable, pin: pin)
        } catch { throw PCGamesError.credentialBrokerUnavailable }
    }

    private func brokerResponse(_ request: CredentialRequest) async throws -> CredentialResponse? {
        try await send(request) {
#if !XODUS_SHIPPING
            if let sandboxBroker {
                return try await sandboxBroker(request)
            }
#endif
            guard let broker = try broker() else { return nil }
            return try await broker.send(request)
        }
    }

    private func send(_ request: CredentialRequest,
                      operation: () async throws -> CredentialResponse?) async throws -> CredentialResponse? {
        do {
            guard let response = try await operation() else { return nil }
            if response.migrationRequired && !request.presenceOnly { throw PCGamesError.keychainApprovalRequired }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch let error as PCGamesError { throw error }
        catch CredentialFailure.keychain(let status) {
            if request.operation == .read && !request.presenceOnly && [errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
                throw PCGamesError.keychainApprovalRequired
            }
            if request.operation == .migrate && [errSecUserCanceled, errSecAuthFailed].contains(status) {
                throw PCGamesError.keychainApprovalCancelled
            }
            throw PCGamesError.keychain(status)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PCGamesError.credentialBrokerUnavailable
        }
    }

    func contains() async throws -> Bool {
        guard let response = try await brokerResponse(CredentialRequest(operation: .read, presenceOnly: true))
        else { return try await direct.contains() }
        return response.present
    }

    func migrationRequired() async throws -> Bool {
        try await brokerResponse(CredentialRequest(operation: .read, presenceOnly: true))?.migrationRequired ?? false
    }

    func migrate() async throws {
        guard try await brokerResponse(CredentialRequest(operation: .migrate)) != nil
        else { throw PCGamesError.credentialBrokerUnavailable }
    }

    func legacyRetained() async throws -> Bool {
        try await brokerResponse(CredentialRequest(operation: .read, presenceOnly: true))?.legacyRetained ?? false
    }

    func read() async throws -> String? {
        guard let response = try await brokerResponse(CredentialRequest(operation: .read))
        else { return try await direct.read() }
        return response.value
    }

    func save(_ refreshToken: String) async throws {
        guard try await brokerResponse(CredentialRequest(operation: .write, value: refreshToken)) != nil
        else { return try await direct.save(refreshToken) }
    }

    func delete() async throws {
        guard try await brokerResponse(CredentialRequest(operation: .delete)) != nil
        else { return try await direct.delete() }
    }
}

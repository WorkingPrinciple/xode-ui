// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security
import XodusCredentials

actor PCGamesCredentialStore: PCGamesRefreshStore {
    private let direct: any PCGamesRefreshStore
    private let executable: URL
    private let manifest: URL

    init(direct: any PCGamesRefreshStore = PCGamesKeychain(),
         executable: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xodus/CredentialBroker/XodusCredentialBroker"),
         manifest: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/XodusCredentialBroker.json")) {
        self.executable = executable
        self.manifest = manifest
        self.direct = direct
    }

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

    private func send(_ request: CredentialRequest, via broker: CredentialBrokerClient) async throws -> CredentialResponse {
        do {
            let response = try await broker.send(request)
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
        guard let broker = try broker() else { return try await direct.contains() }
        return try await send(CredentialRequest(operation: .read, presenceOnly: true), via: broker).present
    }

    func migrationRequired() async throws -> Bool {
        guard let broker = try broker() else { return false }
        return try await send(CredentialRequest(operation: .read, presenceOnly: true), via: broker).migrationRequired
    }

    func migrate() async throws {
        guard let broker = try broker() else { throw PCGamesError.credentialBrokerUnavailable }
        _ = try await send(CredentialRequest(operation: .migrate), via: broker)
    }

    func legacyRetained() async throws -> Bool {
        guard let broker = try broker() else { return false }
        return try await send(CredentialRequest(operation: .read, presenceOnly: true), via: broker).legacyRetained
    }

    func read() async throws -> String? {
        guard let broker = try broker() else { return try await direct.read() }
        return try await send(CredentialRequest(operation: .read), via: broker).value
    }

    func save(_ refreshToken: String) async throws {
        guard let broker = try broker() else { return try await direct.save(refreshToken) }
        _ = try await send(CredentialRequest(operation: .write, value: refreshToken), via: broker)
    }

    func delete() async throws {
        guard let broker = try broker() else { return try await direct.delete() }
        _ = try await send(CredentialRequest(operation: .delete), via: broker)
    }
}

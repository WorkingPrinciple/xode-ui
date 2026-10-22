// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusManagement

struct NativeCandidateLaunchCatalogue: Decodable {
    struct Row: Decodable {
        let title: String
        let store_id: String
        let manifest_executable: String
        let manifest_sha256: String
        let profile: String
        let game_arguments: [String]
        let title_environment: [String: String]
        let status: String
        let ready_for_launch: Bool?
        let blocker: String?

        var admitted: Bool {
            status == "candidate, not game-qualified" && ready_for_launch != false
                && title_environment.isEmpty && game_arguments.isEmpty
                && ["creation-dx11-d3dmetal", "queue-winecx-nativejson"].contains(profile)
        }

        var launchProfile: NativeTitleLaunchProfile {
            NativeTitleLaunchProfile(version: 1, productID: store_id, engine: profile,
                shimDirectory: nil, environment: [:],
                unsetEnvironment: ["XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM",
                                   "CX_APPLEGPTK_LIBD3DSHARED_PATH"],
                executable: manifest_executable)
        }

        func validateManifest(folder: URL) throws {
            let file = folder.appendingPathComponent("MicrosoftGame.config")
            try GameScriptFiles.checkPath(file)
            let bytes = try InstalledGameFiles.readRegular(file, maximumBytes: 1_048_576)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest_sha256 else {
                throw NativeLaunchError.invalidProfile
            }
        }

        func validateEngine(_ entry: NativeEngineRegistry.Entry, fallback: String?) throws {
            guard admitted, fallback == nil, entry.name == profile,
                  ["XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM",
                   "CX_APPLEGPTK_LIBD3DSHARED_PATH"].allSatisfy({ entry.environment?[$0] == nil }) else {
                throw NativeLaunchError.invalidProfile
            }
        }
    }

    let schema_version: Int
    let profiles: [Row]

    private static let published: Result<[Row], Error> = Result {
        let sources = [
            ("small-game-candidates", "6a0b6d77f5b8e1d12f6dbc4c92effd55233a3a41adbfe9578d007a0a89188849"),
            ("preflight-game-candidates", "e761862f7326e80a9591115730d1e3a56747e633e6442e87138c6f64cc2ab024")
        ]
        var rows: [Row] = []
        for (name, sha256) in sources {
            let bytes = try Data(contentsOf: LaunchRecipeResources.candidateProfilesURL(name))
            guard bytes.count <= 1_048_576,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw NativeLaunchError.invalidProfile
            }
            let catalogue = try JSONDecoder().decode(Self.self, from: bytes)
            guard catalogue.schema_version == 1 else { throw NativeLaunchError.invalidProfile }
            rows += catalogue.profiles
        }
        guard rows.count == 12, Set(rows.map(\.store_id)).count == rows.count,
              rows.allSatisfy({
                  PCGamesClient.validProductID($0.store_id)
                      && $0.manifest_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }) else { throw NativeLaunchError.invalidProfile }
        return rows
    }

    static func rows() throws -> [Row] { try published.get() }

    static func row(productID: String) throws -> Row? {
        try rows().first { $0.store_id == productID }
    }

    static func issue(productID: String) -> String? {
        do {
            guard let row = try row(productID: productID), !row.admitted else { return nil }
            return row.blocker ?? "This title's candidate launch recipe is not approved for a launch attempt."
        } catch {
            return "The published candidate launch recipes couldn't be verified. Restore the approved app before playing."
        }
    }
}

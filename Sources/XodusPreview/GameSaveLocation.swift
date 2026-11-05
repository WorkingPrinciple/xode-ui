// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import XodusManagement

struct GameSaveCitations: Decodable {
    struct Entry: Decodable {
        let productID: String
        let path: String
        let source: URL
        let scope: String
        let packet: String
        let commit: String
    }
    let schemaVersion: Int
    let items: [Entry]

    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: LaunchRecipeResources.saveLocationsURL()))
        guard value.schemaVersion == 1,
              Set(value.items.map(\.productID)).count == value.items.count,
              value.items.allSatisfy({
                  PCGamesClient.validProductID($0.productID) && !$0.path.isEmpty && $0.path.utf8.count <= 4096
                      && !$0.scope.isEmpty && $0.source.scheme == "https"
                      && $0.source.host == "www.pcgamingwiki.com"
                      && $0.commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
              }) else { throw PCGamesError.invalidResponse }
        return value
    }
}

enum GameSaveLocation {
    struct Observation: Equatable {
        let folder: URL
        let basis: String

        var label: String {
            "Folder found · contents unchecked"
        }
    }

    static func directory(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let root = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(root), url.standardizedFileURL.path == path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try GameScriptFiles.checkPath(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return url
    }

    static func observation(productID: String, recordedPath: String?,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Observation? {
        if let recordedPath {
            return Observation(folder: try directory(recordedPath, home: home),
                               basis: "This folder exists on this Mac. Ode to X doesn't check its contents or which launcher profile uses it.")
        }
        let relative: String
        switch productID {
        case "C3KLDKZBHNCZ": relative = "Documents/My Games/Fallout4 MS/Saves"
        case "9PJ8266BHFWN": relative = "Library/Application Support/minecraft/saves"
        default: return nil
        }
        let path = home.appendingPathComponent(relative).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let basis = productID == "C3KLDKZBHNCZ"
            ? "This folder exists, but Fallout's GDK save location hasn't been confirmed."
            : "This game folder exists on this Mac. Ode to X doesn't check its contents or which launcher profile uses it."
        return Observation(folder: try directory(path, home: home), basis: basis)
    }
}

/// What an uninstall removes (the package folder) versus what it must keep (Ode bottles/prefixes
/// and recorded save folders outside the package). Package files are never counted as saves.
struct GameUninstallImpact: Codable, Equatable, Sendable {
    struct Location: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case prefix, saves }
        let kind: Kind
        let path: String
        let existed: Bool
    }
    struct EngineOwner: Codable, Equatable, Sendable {
        let prefix: String
        let engine: String?
        let wineSHA256: String?
    }
    let version: Int
    let runID: String
    let productID: String
    let installedID: UUID
    let title: String
    let packageFolder: String
    let kept: [Location]
    let savesInsidePackage: [String]
    let engineOwners: [EngineOwner]
    let evidenceEngine: String?
    let evidenceRunID: String?
    let evidenceVerdict: String?
    let recordedAt: Date

    static func inspect(game: InstalledGame, runID: String, storageDirectory: URL,
                        recordedSave: String?, additionalPrefixes: [String] = [],
                        evidence: MacGameEvidence.Game? = nil) -> Self {
        let fileManager = FileManager.default
        let package = URL(fileURLWithPath: game.folder).standardizedFileURL.path
        func inside(_ path: String) -> Bool { path == package || path.hasPrefix(package + "/") }
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        let root = storageDirectory.appendingPathComponent("Prefixes/\(game.id.uuidString)").standardizedFileURL.path
        var prefixes = [root]
        for path in additionalPrefixes.map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
        where !prefixes.contains(path) && !inside(path) { prefixes.append(path) }
        var kept = prefixes.map { Location(kind: .prefix, path: $0, existed: isDirectory($0)) }
        var savesInside: [String] = []
        if let recordedSave {
            let save = URL(fileURLWithPath: recordedSave).standardizedFileURL.path
            if inside(save) { savesInside.append(save) }
            else { kept.append(Location(kind: .saves, path: save, existed: isDirectory(save))) }
        }
        var bottles: [URL] = prefixes.dropFirst().map { URL(fileURLWithPath: $0) }
        if let engines = try? fileManager.contentsOfDirectory(atPath: root) {
            bottles += engines.filter { !$0.hasPrefix(".") }.sorted().map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        }
        let owners = bottles.compactMap { bottle -> EngineOwner? in
            struct Marker: Decodable { let engine: String?; let wine_sha256: String? }
            let marker = bottle.deletingLastPathComponent().appendingPathComponent(".\(bottle.lastPathComponent).xodus-engine-owner.json")
            guard let data = try? InstalledGameFiles.readRegular(marker, maximumBytes: 4096),
                  let value = try? JSONDecoder().decode(Marker.self, from: data) else {
                return isDirectory(bottle.path) ? EngineOwner(prefix: bottle.path, engine: nil, wineSHA256: nil) : nil
            }
            return EngineOwner(prefix: bottle.path, engine: value.engine, wineSHA256: value.wine_sha256)
        }
        return Self(version: 1, runID: runID, productID: game.storeId, installedID: game.id, title: game.title,
                    packageFolder: package, kept: kept, savesInsidePackage: savesInside, engineOwners: owners,
                    evidenceEngine: evidence?.engine, evidenceRunID: evidence?.runId,
                    evidenceVerdict: evidence.map { "\($0.verdict)" }, recordedAt: Date())
    }

    var hasPreservedData: Bool { kept.contains(where: \.existed) }

    /// Kept locations that existed before uninstall and are gone now.
    func missingAfterUninstall() -> [String] {
        kept.filter { location in
            var directory: ObjCBool = false
            return location.existed && !(FileManager.default.fileExists(atPath: location.path, isDirectory: &directory)
                && directory.boolValue)
        }.map(\.path)
    }

    var consentSummary: String {
        var lines = ["Deletes only the game's package folder: \(packageFolder)"]
        let existing = kept.filter(\.existed)
        if existing.isEmpty {
            lines.append("Ode to X hasn't created a bottle or recorded saves for this game yet, so there is nothing else to keep.")
        } else {
            lines.append("Keeps \(existing.count == 1 ? "this location" : "these locations"): "
                + existing.map(\.path).joined(separator: ", "))
        }
        if !savesInsidePackage.isEmpty {
            lines.append("Recorded saves inside the package folder will be deleted with it: "
                + savesInsidePackage.joined(separator: ", ") + ". Back them up first.")
        }
        lines.append("Reinstalling or finding this installation again reuses the kept bottle.")
        return lines.joined(separator: "\n")
    }

    static func checkpointURL(storageDirectory: URL, runID: String) -> URL {
        storageDirectory.appendingPathComponent("LifecycleCheckpoints/uninstall-\(runID).json")
    }

    /// Durably records what must survive before any uninstall transport starts (COR-412).
    func writeCheckpoint(storageDirectory: URL) throws {
        let directory = storageDirectory.appendingPathComponent("LifecycleCheckpoints")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = Self.checkpointURL(storageDirectory: storageDirectory, runID: runID)
        try GameScriptFiles.checkPath(url, allowMissing: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw InstalledGameError.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw InstalledGameError.storage }
        try handle.close()
    }

    static func readCheckpoint(storageDirectory: URL, runID: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try InstalledGameFiles.readRegular(checkpointURL(storageDirectory: storageDirectory, runID: runID),
                                                      maximumBytes: 262_144, privateFile: true)
        let value = try decoder.decode(Self.self, from: data)
        guard value.version == 1, value.runID == runID else { throw InstalledGameError.invalidRegistry }
        return value
    }
}

struct GameSaveLocationView: View {
    let productID: String
    @ObservedObject private var evidence = MacGameEvidenceStore.shared
    @State private var observed: GameSaveLocation.Observation?
    @State private var cited: GameSaveCitations.Entry?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save location").font(.headline)
            if let observed {
                Text(observed.label).font(.subheadline.weight(.medium))
                Text(observed.folder.path).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(observed.basis).font(.caption).foregroundStyle(.secondary)
                Button("Open folder") { open(observed.folder) }
                    .accessibilityIdentifier("xodus.saveLocation.openFolder")
                    .accessibilityLabel("Open save folder for this game")
            }
            if let cited {
                Text("Published Windows save location").font(.subheadline.weight(.medium))
                Text(cited.path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(cited.scope).font(.caption).foregroundStyle(.secondary)
                Link("Save-location source", destination: cited.source)
            }
            if observed == nil && cited == nil && errorMessage == nil {
                Text("No save location recorded for this title.").foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Ode to X shows locations only; it doesn't check save contents or cloud sync.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("xodus.saveLocation")
        .task(id: "\(productID):\(evidence.games[productID]?.saveObservation?.saveDirectory ?? "")") {
            refresh()
        }
    }

    private func refresh() {
        observed = nil
        cited = nil
        errorMessage = nil
        do {
            cited = try GameSaveCitations.load().items.first { $0.productID == productID }
        } catch {
            errorMessage = "The cited save-location data couldn't be read."
        }
        do {
            observed = try GameSaveLocation.observation(productID: productID,
                recordedPath: evidence.games[productID]?.saveObservation?.saveDirectory)
        } catch {
            errorMessage = "The recorded save folder couldn't be accessed. Its location has not been verified on this Mac."
        }
    }

    private func open(_ url: URL) {
        do {
            let checked = try GameSaveLocation.directory(url.path)
            guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: checked.path) else {
                throw CocoaError(.fileReadUnknown)
            }
        } catch {
            errorMessage = "The save folder couldn't be opened. It may have moved or file access may be restricted."
        }
    }
}

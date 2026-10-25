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
                               basis: "This folder exists on this Mac. \(AppBrand.displayName) doesn't check its contents or which launcher profile uses it.")
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
            : "This game folder exists on this Mac. \(AppBrand.displayName) doesn't check its contents or which launcher profile uses it."
        return Observation(folder: try directory(path, home: home), basis: basis)
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
            Text("\(AppBrand.displayName) shows locations only; it doesn't check save contents or cloud sync.")
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

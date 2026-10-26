// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// Every macOS privacy prompt X Ode can trigger, with the Info.plist usage string (tools/Info.plist must match;
/// a check enforces it), the plain reason shown in Settings and the install notes, and where to change it.
/// X Ode is the responsible process for its game service and for the Windows games it runs, so prompts those
/// games trigger name X Ode. Developer ID–signed updates keep the same bundle ID and code requirement, so
/// existing grants and the saved sign-in carry over.
enum PrivacyPermission: String, CaseIterable, Identifiable {
    case localNetwork, removableVolumes, networkVolumes, documents, downloads, desktop, notifications, keychain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: "Local network"
        case .removableVolumes: "External drives"
        case .networkVolumes: "Network drives"
        case .documents: "Documents folder"
        case .downloads: "Downloads folder"
        case .desktop: "Desktop folder"
        case .notifications: "Notifications"
        case .keychain: "Keychain"
        }
    }

    /// When and why the prompt appears, in the words used by Settings and the install notes.
    var reason: String {
        let app = AppBrand.displayName
        return switch self {
        case .localNetwork: "\(app) and the games it runs use your local network to find Xbox consoles and for multiplayer features."
        case .removableVolumes: "When \(app) stores games on an external drive, or a game it runs reads or saves files there."
        case .networkVolumes: "When \(app) stores games on a network drive, or a game it runs reads or saves files there."
        case .documents: "When \(app) stores games in your Documents folder, or a game it runs reads or saves files there."
        case .downloads: "When \(app) stores games in your Downloads folder, or a game it runs reads or saves files there."
        case .desktop: "When \(app) stores games on your Desktop, or a game it runs reads or saves files there."
        case .notifications: "After a game finishes installing, so \(app) can tell you it's ready to play. Never at launch."
        case .keychain: "When \(app) checks or saves your Microsoft sign-in on this Mac."
        }
    }

    /// Info.plist key and usage string; nil when macOS shows its own prompt (Notifications, Keychain).
    var usageDescription: (key: String, text: String)? {
        let app = AppBrand.displayName
        return switch self {
        case .localNetwork: ("NSLocalNetworkUsageDescription",
            "\(app) and the games it runs use your local network to find Xbox consoles and for multiplayer features.")
        case .removableVolumes: ("NSRemovableVolumesUsageDescription",
            "\(app) stores and plays games on this drive, and the games it runs may read or save files there.")
        case .networkVolumes: ("NSNetworkVolumesUsageDescription",
            "\(app) stores and plays games on this network drive, and the games it runs may read or save files there.")
        case .documents: ("NSDocumentsFolderUsageDescription",
            "\(app) and the games it runs use your Documents folder to store games and save files.")
        case .downloads: ("NSDownloadsFolderUsageDescription",
            "\(app) and the games it runs use your Downloads folder to store games and read or save files.")
        case .desktop: ("NSDesktopFolderUsageDescription",
            "\(app) and the games it runs use your Desktop to store games and read or save files.")
        case .notifications, .keychain: nil
        }
    }

    /// Where to change the answer; nil for Keychain, which asks per saved item and has no settings pane.
    var settingsURL: URL? {
        switch self {
        case .localNetwork: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .removableVolumes, .networkVolumes, .documents, .downloads, .desktop:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .keychain: nil
        }
    }

    /// System Settings location named in copy.
    var settingsLocation: String? {
        switch self {
        case .localNetwork: "System Settings ▸ Privacy & Security ▸ Local Network"
        case .removableVolumes, .networkVolumes, .documents, .downloads, .desktop:
            "System Settings ▸ Privacy & Security ▸ Files and Folders"
        case .notifications: "System Settings ▸ Notifications"
        case .keychain: nil
        }
    }

    static let installNotesTitle = "What X Ode may ask permission for, and why"
    static var gamesNote: String {
        "Windows games run through \(AppBrand.displayName), so a prompt a game triggers names \(AppBrand.displayName)."
    }
    static var keychainNote: String {
        "Keychain asks separately for each saved sign-in; there's no System Settings switch for it."
    }
    /// Exact known-issue line for the release notes (owner decision: no microphone entitlement in this beta).
    static let microphoneKnownIssue = "In-game voice chat and microphone input aren't supported in this beta."
}

/// Opens the pane where the user can change one permission.
struct OpenPrivacySettingsButton: View {
    let permission: PrivacyPermission
    var title = "Open System Settings"

    var body: some View {
        if let url = permission.settingsURL {
            Button(title) { NSWorkspace.shared.open(url) }
                .accessibilityLabel("\(title) for \(permission.title)")
                .accessibilityIdentifier("xodus.privacy.open.\(permission.rawValue)")
        }
    }
}

/// Settings ▸ General: what X Ode may ask for, and where to change it.
struct PrivacyPermissionsSection: View {
    var body: some View {
        Section {
            ForEach(PrivacyPermission.allCases) { permission in
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(permission.title)
                    Text(permission.reason)
                }
            }
            Text(PrivacyPermission.gamesNote).font(.callout).foregroundStyle(.secondary)
            Text(PrivacyPermission.keychainNote).font(.callout).foregroundStyle(.secondary)
            Text(PrivacyPermission.microphoneKnownIssue).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                OpenPrivacySettingsButton(permission: .notifications, title: "Open Notifications")
                OpenPrivacySettingsButton(permission: .localNetwork, title: "Open Privacy & Security")
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("macOS asks the first time each one is needed. You can change your answer in System Settings at any time.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Tells a macOS privacy (TCC) denial apart from ordinary folder permissions.
enum PrivacyDenial {
    enum FolderAccess: Equatable {
        case readable
        /// EPERM: macOS privacy blocked access; the permission is nil when the location isn't a protected one.
        case privacyDenied(PrivacyPermission?)
        /// EACCES: the folder's own permissions don't allow access.
        case notPermitted
        case other
    }

    /// The POSIX code behind a file error, looking through Cocoa wrappers.
    static func posixCode(_ error: Error) -> Int32? {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return posixCode(underlying) }
        return nil
    }

    static func classify(_ error: Error, path: String) -> FolderAccess {
        switch posixCode(error) {
        case EPERM?: .privacyDenied(folderPermission(for: path))
        case EACCES?: .notPermitted
        default: .other
        }
    }

    /// Reads the folder listing once to learn whether macOS privacy or the folder's permissions block it.
    static func probe(_ url: URL) -> FolderAccess {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .readable
        } catch {
            return classify(error, path: url.path)
        }
    }

    /// The protected location a path is in, matched by whole path components; nil for unprotected places.
    static func folderPermission(for path: String,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                 volume: (String) -> (removable: Bool, local: Bool)? = volumeTraits) -> PrivacyPermission? {
        func within(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if within(home + "/Documents") { return .documents }
        if within(home + "/Downloads") { return .downloads }
        if within(home + "/Desktop") { return .desktop }
        guard let traits = volume(path) else { return nil }
        if traits.removable { return .removableVolumes }
        if !traits.local { return .networkVolumes }
        return nil
    }

    static func volumeTraits(_ path: String) -> (removable: Bool, local: Bool)? {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsInternalKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return nil }
        let removable = values.volumeIsRemovable == true || values.volumeIsEjectable == true
            || values.volumeIsInternal == false && values.volumeIsLocal != false
        return (removable, values.volumeIsLocal ?? true)
    }

    /// Message and settings link for a games folder that couldn't be used.
    static func installFolderProblem(_ access: FolderAccess, fallback: String) -> (message: String, permission: PrivacyPermission?) {
        let app = AppBrand.displayName
        switch access {
        case .privacyDenied(let permission?):
            return ("macOS hasn't allowed \(app) to use this folder. Allow \(permission.title) in \(permission.settingsLocation ?? "System Settings"), then choose it again.", permission)
        case .privacyDenied(nil):
            return ("macOS didn't allow \(app) to use this folder. Choose another folder.", nil)
        case .notPermitted:
            return ("You don't have permission to use this folder. Check its permissions in Finder (Get Info ▸ Sharing & Permissions), or choose another folder.", nil)
        case .readable, .other:
            return (fallback, nil)
        }
    }
}

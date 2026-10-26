// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// Every macOS privacy prompt X Ode can trigger, with the Info.plist usage string packaging must add,
/// the plain reason shown in Settings and install notes, and the System Settings pane to fix a denial.
/// Bundle ID and code requirement don't change, so existing grants and the saved sign-in survive updates.
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
        case .localNetwork: "Only when you choose Find consoles, so \(app) can look for Xbox consoles on your network."
        case .removableVolumes: "When your games folder or an installed game is on an external drive."
        case .networkVolumes: "When your games folder or an installed game is on a network drive."
        case .documents, .downloads, .desktop:
            "When a game you play saves or reads files there. Games run through \(app), so macOS asks on its behalf."
        case .notifications: "After a game finishes installing, so \(app) can tell you it's ready to play. Never at launch."
        case .keychain: "When \(app) checks or saves your Microsoft sign-in on this Mac."
        }
    }

    /// Info.plist key and usage string; nil when macOS shows its own prompt (Keychain).
    var usageDescription: (key: String, text: String)? {
        let app = AppBrand.displayName
        return switch self {
        case .localNetwork: ("NSLocalNetworkUsageDescription",
            "\(app) looks for Xbox consoles on your local network when you choose Find consoles.")
        case .removableVolumes: ("NSRemovableVolumesUsageDescription",
            "\(app) installs and plays games from the folder you chose on this drive.")
        case .networkVolumes: ("NSNetworkVolumesUsageDescription",
            "\(app) installs and plays games from the folder you chose on this network drive.")
        case .documents: ("NSDocumentsFolderUsageDescription",
            "A game you're playing in \(app) wants to save or read files in your Documents folder.")
        case .downloads: ("NSDownloadsFolderUsageDescription",
            "A game you're playing in \(app) wants to read or save files in your Downloads folder.")
        case .desktop: ("NSDesktopFolderUsageDescription",
            "A game you're playing in \(app) wants to read or save files on your Desktop.")
        case .notifications, .keychain: nil
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .localNetwork: "Privacy_LocalNetwork"
        case .removableVolumes, .networkVolumes, .documents, .downloads, .desktop: "Privacy_FilesAndFolders"
        case .keychain, .notifications: "Privacy"
        }
        if self == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static let installNotesTitle = "What X Ode may ask permission for, and why"
    /// Exact known-issue line for the release notes (owner decision: no microphone entitlement in this beta).
    static let microphoneKnownIssue = "In-game voice chat and microphone input aren't supported in this beta."
}

/// Opens the right Privacy & Security pane after a denial.
struct OpenPrivacySettingsButton: View {
    let permission: PrivacyPermission
    var title = "Open System Settings"

    var body: some View {
        Button(title) { NSWorkspace.shared.open(permission.settingsURL) }
            .accessibilityLabel("\(title) for \(permission.title)")
            .accessibilityIdentifier("xodus.privacy.open.\(permission.rawValue)")
    }
}

/// Settings ▸ General: what X Ode may ask for, and a way to change it.
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
            Text(PrivacyPermission.microphoneKnownIssue).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                OpenPrivacySettingsButton(permission: .keychain, title: "Open Privacy & Security")
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("macOS asks the first time each one is needed. You can change your answer in System Settings at any time.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Recognises macOS privacy denials in file errors so callers can offer System Settings.
enum PrivacyDenial {
    static func isFolderDenial(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isFolderDenial(underlying) }
        return false
    }

    static func folderPermission(for path: String) -> PrivacyPermission {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Volumes/") {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
            return values?.volumeIsLocal == false ? .networkVolumes : .removableVolumes
        }
        if path.hasPrefix(home + "/Documents") { return .documents }
        if path.hasPrefix(home + "/Downloads") { return .downloads }
        if path.hasPrefix(home + "/Desktop") { return .desktop }
        return .removableVolumes
    }
}

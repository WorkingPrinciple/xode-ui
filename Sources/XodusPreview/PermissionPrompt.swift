// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// REQ-118: the explanation X Ode shows just before an action that can make macOS ask for a permission.

struct PermissionPromptCopy: Equatable {
    let title: String
    let explanation: String
    let continueTitle: String
    let cancelTitle: String
}

enum PermissionPrompt {
    static func copy(for permission: PrivacyPermission) -> PermissionPromptCopy {
        switch permission {
        case .localNetwork:
            PermissionPromptCopy(
                title: "Find consoles on your local network?",
                explanation: "When you choose Find consoles, \(AppBrand.displayName) uses Bonjour to look for Xbox consoles on your local network. If you continue, macOS may ask for Local Network access next. No search starts if you choose Not now.",
                continueTitle: "Continue",
                cancelTitle: "Not now"
            )
        case .notifications:
            PermissionPromptCopy(
                title: "Get game-ready notifications?",
                explanation: "\(AppBrand.displayName) asks only after an install or repair has finished. If you continue, macOS may ask to show a notification when that game is ready. The install is complete either way. You can change this later in System Settings ▸ Notifications.",
                continueTitle: "Continue",
                cancelTitle: "Not now"
            )
        case .removableVolumes, .networkVolumes, .documents, .downloads, .desktop:
            PermissionPromptCopy(
                title: "Use this game folder?",
                explanation: fileSelectionMessage,
                continueTitle: "Choose Folder",
                cancelTitle: "Cancel"
            )
        case .keychain:
            PermissionPromptCopy(
                title: "Approve saved sign-in access?",
                explanation: "\(AppBrand.displayName) needs the saved Microsoft sign-in only when you use Account or load your PC games. macOS may ask to approve access to that Keychain item. Declining keeps the saved sign-in and stops account access until you approve it.",
                continueTitle: "Continue",
                cancelTitle: "Not now"
            )
        }
    }

    static var fileSelectionMessage: String { "\(AppBrand.displayName) reads or writes only the files you choose for this feature. If a chosen location is Documents, Downloads, Desktop, an external drive, or a network volume, macOS may ask for access the first time it is used. Games launched from \(AppBrand.displayName) may also read or save their own files in these locations." }

    static var saveMessage: String { "Only the reviewed summary shown in \(AppBrand.displayName) is saved. If you choose Documents, Downloads, Desktop, an external drive, or a network volume, macOS may ask for access to write there." }

    static func firstUseKey(for permission: PrivacyPermission) -> String {
        "Xodus.permission.explained.\(permission.rawValue)"
    }

    @MainActor
    static func confirmFirstUse(_ permission: PrivacyPermission, defaults: UserDefaults = .standard) -> Bool {
        let key = firstUseKey(for: permission)
        guard !defaults.bool(forKey: key) else { return true }
        let copy = copy(for: permission)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.title
        alert.informativeText = copy.explanation
        alert.addButton(withTitle: copy.continueTitle)
        alert.addButton(withTitle: copy.cancelTitle)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: key)
        return true
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
@preconcurrency import UserNotifications

/// UX-M2: posts "<title> is ready to play" with a Play action when an install or repair finishes.
@MainActor
final class GameReadyNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "xodus.game.ready"
    nonisolated static let playAction = "xodus.game.ready.play"
    nonisolated static let folderKey = "folder"

    /// Called with the installed folder when the user chooses Play.
    var play: ((String) -> Void)?
    private var configured = false
    /// One explanation at a time: notices that finish while it is up wait for its answer instead of stacking alerts.
    private var explaining = false
    private var waiting: [UNNotificationRequest] = []

    /// UNUserNotificationCenter requires a bundled app; unbundled tool runs post nothing.
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func content(for announcement: GameReadyAnnouncement) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = announcement.body
        content.body = "Open \(AppBrand.displayName) or choose Play."
        content.categoryIdentifier = category
        content.userInfo = [folderKey: announcement.folder]
        return content
    }

    func configure() {
        guard Self.available, !configured else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category,
            actions: [UNNotificationAction(identifier: Self.playAction, title: "Play", options: [.foreground])],
            intentIdentifiers: [])])
    }

    func post(_ announcement: GameReadyAnnouncement) {
        guard Self.available else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: "\(Self.category).\(announcement.productID)",
                                            content: Self.content(for: announcement), trigger: nil)
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.deliver(request, status: status) }
        }
    }

    /// REQ-118: what a finished install does about notification permission. The system prompt appears only
    /// after X Ode explains it, the first time a game is ready; "Not now" is remembered so installs never nag.
    enum ReadyStep: Equatable { case add, explainThenAsk, skipDeferred, skipDenied }

    nonisolated static func step(status: UNAuthorizationStatus, deferred: Bool) -> ReadyStep {
        switch status {
        case .authorized, .provisional, .ephemeral: .add
        case .denied: .skipDenied
        case .notDetermined: deferred ? .skipDeferred : .explainThenAsk
        @unknown default: .skipDenied
        }
    }

    static let deferredKey = "Xodus.permission.deferred.notifications"

    private func deliver(_ request: UNNotificationRequest, status: UNAuthorizationStatus,
                         defaults: UserDefaults = .standard) {
        let center = UNUserNotificationCenter.current()
        switch Self.step(status: status, deferred: defaults.bool(forKey: Self.deferredKey)) {
        case .add:
            defaults.set(false, forKey: PrivacyPermission.notificationsDeniedKey)
            center.add(request)
        case .skipDenied:
            defaults.set(true, forKey: PrivacyPermission.notificationsDeniedKey)
        case .skipDeferred:
            break
        case .explainThenAsk:
            guard !explaining else { waiting.append(request); return }
            explaining = true
            let confirmed = PermissionPrompt.confirmFirstUse(.notifications, defaults: defaults)
            let requests = [request] + waiting
            waiting = []
            explaining = false
            guard confirmed else {
                defaults.set(true, forKey: Self.deferredKey)
                return
            }
            Self.ask(defaults: defaults) { granted in
                if granted { requests.forEach { center.add($0) } }
            }
        }
    }

    /// Re-reads the real authorization so Settings never shows a stale "off" or "Not now" after the user
    /// changes Notifications in System Settings.
    static func refreshRecordedStatus() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                let defaults = UserDefaults.standard
                defaults.set(status == .denied, forKey: PrivacyPermission.notificationsDeniedKey)
                if status != .notDetermined { defaults.set(false, forKey: deferredKey) }
            }
        }
    }

    /// Settings ▸ Permissions: asks now when X Ode hasn't asked yet; otherwise opens Notifications settings.
    static func requestFromSettings() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .notDetermined else {
                    if let url = PrivacyPermission.notifications.settingsURL { NSWorkspace.shared.open(url) }
                    return
                }
                UserDefaults.standard.set(false, forKey: deferredKey)
                ask(defaults: .standard) { _ in }
            }
        }
    }

    private static func ask(defaults: UserDefaults, completion: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                UserDefaults.standard.set(!granted, forKey: PrivacyPermission.notificationsDeniedKey)
                completion(granted)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let folder = response.notification.request.content.userInfo[Self.folderKey] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if action == Self.playAction, let folder { play?(folder) }
        }
    }
}

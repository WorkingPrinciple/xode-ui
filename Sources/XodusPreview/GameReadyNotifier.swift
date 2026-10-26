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
        let content = Self.content(for: announcement)
        let request = UNNotificationRequest(identifier: "\(Self.category).\(announcement.productID)",
                                            content: content, trigger: nil)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
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

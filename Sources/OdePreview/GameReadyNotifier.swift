// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
@preconcurrency import UserNotifications

/// UX-M2: posts "<title> is ready to play" with a Play action when an install or repair finishes.
@MainActor
final class GameReadyNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "ode.game.ready"
    nonisolated static let playAction = "ode.game.ready.play"
    nonisolated static let folderKey = "folder"

    /// Called with the installed folder when the user chooses Play.
    var play: ((String) -> Void)?
    private var configured = false
    /// One explanation at a time: notices that finish while it is up wait for its answer instead of stacking alerts.
    private var explaining = false
    private var waiting: [UNNotificationRequest] = []
    /// Notices that need the explanation while a game is running or X Ode is in the background. They wait
    /// for the next time the user brings X Ode to the front; nothing interrupts play.
    private(set) var held: [UNNotificationRequest] = []
    private var foregroundObserver: NSObjectProtocol?
    /// True while a game is launching or running.
    var playActive: () -> Bool = { false }
    var appFrontmost: () -> Bool = { NSApp?.isActive ?? false }
    /// Test seams: the explanation and the system add. Production uses PermissionPrompt and the notification center.
    var explainOverride: ((UserDefaults) -> Bool)?
    var addOverride: ((UNNotificationRequest) -> Void)?

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
            Task { @MainActor in self.deliver([request], status: status) }
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

    static let deferredKey = "Ode.permission.deferred.notifications"

    /// Unsolicited modals and activation are allowed only while no game is running and X Ode is frontmost.
    nonisolated static func interruptionAllowed(playing: Bool, frontmost: Bool) -> Bool { !playing && frontmost }

    private func add(_ request: UNNotificationRequest) {
        if let addOverride { addOverride(request) } else { UNUserNotificationCenter.current().add(request) }
    }

    func deliver(_ requests: [UNNotificationRequest], status: UNAuthorizationStatus,
                 defaults: UserDefaults = .standard) {
        guard !requests.isEmpty else { return }
        switch Self.step(status: status, deferred: defaults.bool(forKey: Self.deferredKey)) {
        case .add:
            // A banner only: posting never brings X Ode forward or takes focus from a game.
            defaults.set(false, forKey: PrivacyPermission.notificationsDeniedKey)
            requests.forEach(add)
        case .skipDenied:
            defaults.set(true, forKey: PrivacyPermission.notificationsDeniedKey)
        case .skipDeferred:
            break
        case .explainThenAsk:
            guard !explaining else { waiting.append(contentsOf: requests); return }
            guard Self.interruptionAllowed(playing: playActive(), frontmost: appFrontmost()) else {
                held.append(contentsOf: requests)
                watchForeground()
                return
            }
            explaining = true
            let confirmed = explainOverride?(defaults)
                ?? PermissionPrompt.confirmFirstUse(.notifications, defaults: defaults)
            let all = requests + waiting
            waiting = []
            explaining = false
            guard confirmed else {
                defaults.set(true, forKey: Self.deferredKey)
                return
            }
            Self.ask(defaults: defaults) { [weak self] granted in
                if granted { all.forEach { self?.add($0) } }
            }
        }
    }

    /// Delivers held notices once X Ode is frontmost and no game is running, using the current status.
    func releaseHeld(status: UNAuthorizationStatus, defaults: UserDefaults = .standard) {
        guard !held.isEmpty, Self.interruptionAllowed(playing: playActive(), frontmost: appFrontmost()) else { return }
        let requests = held
        held = []
        deliver(requests, status: status, defaults: defaults)
    }

    private func watchForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foregrounded() }
        }
    }

    private func foregrounded() {
        guard !held.isEmpty, Self.available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.releaseHeld(status: status) }
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
            // The user clicked this banner, so activating X Ode here is solicited.
            NSApp.activate(ignoringOtherApps: true)
            if action == Self.playAction, let folder { play?(folder) }
        }
    }
}

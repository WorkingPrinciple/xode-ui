// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@testable import XodusManagement

private final class FakeUpdateDriver: UpdateDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<AppUpdateFeedResponse, AppUpdateError>]
    private(set) var etags: [String?] = []
    private(set) var relaunches: [AppUpdateInfo] = []
    let isConfigured: Bool

    init(_ responses: [Result<AppUpdateFeedResponse, AppUpdateError>] = [], configured: Bool = true) {
        queue = responses
        isConfigured = configured
    }

    var checkCount: Int { lock.withLock { etags.count } }
    var relaunchCount: Int { lock.withLock { relaunches.count } }

    func check(etag: String?) async throws -> AppUpdateFeedResponse {
        let next: Result<AppUpdateFeedResponse, AppUpdateError> = lock.withLock {
            etags.append(etag)
            return queue.isEmpty ? .success(.current(etag: nil)) : queue.removeFirst()
        }
        return try next.get()
    }

    func relaunchToInstall(_ info: AppUpdateInfo) async throws { lock.withLock { relaunches.append(info) } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

extension Checks {
    func appUpdateChecks() async {
        for result in await AppUpdateCheckSuite.run() { check(result.passed, result.name) }
    }
}

@MainActor
private enum AppUpdateCheckSuite {
    static var results: [(passed: Bool, name: String)] = []

    static func check(_ passed: Bool, _ name: String) { results.append((passed, name)) }

    static func run() async -> [(passed: Bool, name: String)] {
        results = []
        await appUpdateChecks()
        return results
    }

    private static func updateDefaults() -> UserDefaults {
        let name = "xodus.update.checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func makeController(_ driver: UpdateDriver, defaults: UserDefaults, clock: TestClock,
                                conditions: @escaping @MainActor () -> AppUpdateConditions = { AppUpdateConditions() },
                                busy: @escaping @MainActor () -> AppUpdateBusyReason? = { nil },
                                current: String = "0.2.0") -> AppUpdateController {
        AppUpdateController(driver: driver, preferences: AppUpdatePreferences(defaults: defaults),
                            currentVersion: UpdateVersion(current), clock: { clock.now }, conditions: conditions,
                            busy: busy, jitter: { 0.5 })
    }

    private static func appUpdateChecks() async {
        let v2 = AppUpdateInfo(version: "0.3.0")

        check(UpdateVersion("0.10.0")! > UpdateVersion("0.9.2")! && UpdateVersion("v1.0")! == UpdateVersion("1.0.0")!
              && UpdateVersion("1.0.0-beta") == nil && UpdateVersion("") == nil,
              "UPD-02: version comparison is numeric and rejects non-numeric feeds")

        // UPD-02: once a day, conditional GET, first launch, jitter
        do {
            let clock = TestClock(), defaults = updateDefaults()
            let driver = FakeUpdateDriver([.success(.available(v2, etag: "\"e1\"")), .success(.notModified)])
            let controller = makeController(driver, defaults: defaults, clock: clock)
            await controller.checkIfDue()
            check(driver.checkCount == 1 && driver.etags == [nil], "UPD-02: first launch checks once without an ETag")
            clock.advance(23 * 3600)
            await controller.checkIfDue()
            check(driver.checkCount == 1, "UPD-02: no second check inside the 24 hour window")
            clock.advance(2 * 3600 + 1)
            await controller.checkIfDue()
            check(driver.checkCount == 2 && driver.etags.last == "\"e1\"",
                  "UPD-02: the next check sends If-None-Match with the stored ETag")
            let state = controller.state
            check(state == .available(v2), "UPD-02: 304 keeps the existing state unchanged")
            let prefs = AppUpdatePreferences(defaults: defaults)
            let jittered = prefs.nextCheck!.timeIntervalSince(prefs.lastCheck!)
            check(jittered > AppUpdateSchedule.interval
                  && jittered <= AppUpdateSchedule.interval + AppUpdateSchedule.maximumJitter,
                  "UPD-02: the next check is 24 hours plus bounded jitter")
            let restored = makeController(FakeUpdateDriver(), defaults: defaults, clock: clock)
            check(restored.state == .available(v2), "UPD-02: a known update survives relaunch without a request")
        }

        // UPD-03: quiet failure, back-off, offline / Low Data / Low Power
        do {
            check([1, 2, 3, 4, 5, 9].map { AppUpdateSchedule.delay(afterFailures: $0) / 86400 } == [1, 2, 4, 7, 7, 7],
                  "UPD-03: back-off is 1, 2, 4 days capped at 7")
            let clock = TestClock(), defaults = updateDefaults()
            let driver = FakeUpdateDriver([.failure(.offline), .failure(.rateLimited), .success(.current(etag: nil))])
            let controller = makeController(driver, defaults: defaults, clock: clock)
            await controller.checkIfDue()
            let quietFailure = controller.manualFailure
            check(quietFailure == nil && AppUpdatePreferences(defaults: defaults).failures == 1,
                  "UPD-03: a scheduled failure raises no UI and counts toward back-off")
            clock.advance(23 * 3600)
            await controller.checkIfDue()
            check(driver.checkCount == 1, "UPD-03: the first failure backs off at least a day")
            clock.advance(3 * 3600)
            await controller.checkIfDue()
            clock.advance(23 * 3600)
            await controller.checkIfDue()
            check(driver.checkCount == 2, "UPD-03: the second failure backs off two days")
            clock.advance(3 * 24 * 3600)
            await controller.checkIfDue()
            check(AppUpdatePreferences(defaults: defaults).failures == 0, "UPD-03: success resets the back-off")

            for (name, conditions) in [("offline", AppUpdateConditions(online: false)),
                                       ("Low Data Mode", AppUpdateConditions(lowDataMode: true)),
                                       ("Low Power Mode", AppUpdateConditions(lowPowerMode: true))] {
                let gated = FakeUpdateDriver()
                let controller = makeController(gated, defaults: updateDefaults(), clock: clock,
                                                      conditions: { conditions })
                await controller.checkIfDue()
                check(gated.checkCount == 0, "UPD-03: the scheduled check is skipped when \(name)")
                await controller.checkNow()
                check(gated.checkCount == 1, "UPD-03: a manual check still runs when \(name)")
            }

            let failing = FakeUpdateDriver([.failure(.offline)])
            let manual = makeController(failing, defaults: updateDefaults(), clock: clock)
            await manual.checkNow()
            check(manual.manualFailure != nil, "UPD-03: a manual check reports its failure")
        }

        // UPD-04: toolbar indicator only for available/downloading/ready, with accessible text
        do {
            let clock = TestClock()
            let none = makeController(FakeUpdateDriver([.success(.current(etag: nil))]),
                                            defaults: updateDefaults(), clock: clock)
            check(none.indicator == nil, "UPD-04: no indicator before any check")
            await none.checkNow()
            let noneState = none.state
            check(none.indicator == nil && noneState == .upToDate,
                  "UPD-04: no indicator when up to date")
            let unconfigured = makeController(FakeUpdateDriver(configured: false),
                                                    defaults: updateDefaults(), clock: clock)
            check(unconfigured.indicator == nil, "UPD-04: no indicator without a feed")

            let controller = makeController(FakeUpdateDriver([.success(.available(v2, etag: nil))]),
                                                  defaults: updateDefaults(), clock: clock)
            await controller.checkNow()
            let available = controller.indicator
            check(available?.label == "App update available" && available?.value == "Version 0.3.0"
                  && available?.symbol == "arrow.down.app", "UPD-04: the available state has an accessible label and value")
            await controller.markReady(v2)
            let ready = controller.indicator
            check(ready?.label == "App update ready to install" && ready?.value.contains("0.3.0") == true,
                  "UPD-04: the ready state has an accessible label and value")
            let labels = [available?.label, ready?.label]
            check(Set(labels.compactMap { $0 }).count == 2, "UPD-04: each state reads differently")
        }

        // UPD-08: preferences, skip, remind later, manual check
        do {
            let clock = TestClock(), defaults = updateDefaults()
            let prefs = AppUpdatePreferences(defaults: defaults)
            check(prefs.autoCheck, "UPD-08: automatic checks default on")
            prefs.autoCheck = false
            check(!AppUpdatePreferences(defaults: defaults).autoCheck, "UPD-08: the automatic-check choice persists")
            let off = FakeUpdateDriver()
            let disabled = makeController(off, defaults: defaults, clock: clock)
            await disabled.checkIfDue()
            check(off.checkCount == 0, "UPD-08: no scheduled check while automatic checks are off")
            await disabled.checkNow()
            check(off.checkCount == 1, "UPD-08: Check Now works while automatic checks are off")
            check(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Xodus.") }
                    .allSatisfy { $0.hasPrefix(AppUpdatePreferences.keyPrefix) },
                  "UPD-08: every preference lives under Xodus.update.*")

            let v3 = AppUpdateInfo(version: "0.4.0")
            let skipDefaults = updateDefaults()
            let driver = FakeUpdateDriver([.success(.available(v2, etag: nil)), .success(.available(v2, etag: nil)),
                                           .success(.available(v3, etag: nil))])
            let controller = makeController(driver, defaults: skipDefaults, clock: clock)
            await controller.checkNow()
            await controller.skipThisVersion()
            let skippedState = controller.state
            check(controller.indicator == nil && skippedState == .available(v2),
                  "UPD-08: skipping hides the indicator for that version")
            let relaunched = makeController(FakeUpdateDriver(), defaults: skipDefaults, clock: clock)
            check(relaunched.indicator == nil, "UPD-08: the skip persists across relaunch")
            clock.advance(AppUpdateSchedule.interval * 2)
            await controller.checkIfDue()
            check(controller.indicator == nil, "UPD-08: a scheduled check of the skipped version stays hidden")
            clock.advance(AppUpdateSchedule.interval * 2)
            await controller.checkIfDue()
            check(controller.indicator?.value == "Version 0.4.0", "UPD-08: a newer version shows again after a skip")

            let remindDefaults = updateDefaults()
            let remind = makeController(FakeUpdateDriver([.success(.available(v2, etag: nil))]),
                                              defaults: remindDefaults, clock: clock)
            await remind.checkNow()
            await remind.remindMeLater()
            check(remind.indicator == nil, "UPD-08: Remind me later hides the indicator")
            clock.advance(23 * 3600)
            check(remind.indicator == nil, "UPD-08: the snooze holds for the interval")
            clock.advance(2 * 3600)
            check(remind.indicator != nil, "UPD-08: the indicator returns after the snooze")

            let manualDefaults = updateDefaults()
            let manual = makeController(FakeUpdateDriver([.success(.available(v2, etag: nil)),
                                                                .success(.available(v2, etag: nil))]),
                                              defaults: manualDefaults, clock: clock)
            await manual.checkNow()
            await manual.skipThisVersion()
            await manual.checkNow()
            check(manual.indicator != nil, "UPD-08: Check Now surfaces a skipped version again")
        }

        // UPD-07: no install while a game or install is active, and the updater cannot terminate anything
        do {
            let clock = TestClock()
            let box = BusyBox()
            let driver = FakeUpdateDriver([.success(.available(v2, etag: nil))])
            let controller = makeController(driver, defaults: updateDefaults(), clock: clock,
                                                  busy: { box.reason })
            await controller.checkNow()
            await controller.markReady(v2)
            box.reason = .gameRunning
            await controller.installWhenIdle()
            var current = controller.state
            check(driver.relaunchCount == 0 && current == .waiting(v2, .gameRunning),
                  "UPD-07: a running game defers the install")
            check(controller.indicator?.value.contains("game is running") == true,
                  "UPD-07: the UI states the reason")
            box.reason = .installActive
            await controller.busyStateChanged()
            current = controller.state
            check(driver.relaunchCount == 0 && current == .waiting(v2, .installActive),
                  "UPD-07: an active install keeps it waiting")
            box.reason = nil
            await controller.busyStateChanged()
            current = controller.state
            check(driver.relaunchCount == 1 && current == .relaunching(v2),
                  "UPD-07: it resumes once the app is idle")
            let idleAvailable = FakeUpdateDriver([.success(.available(v2, etag: nil))])
            let notReady = makeController(idleAvailable, defaults: updateDefaults(), clock: clock)
            await notReady.checkNow()
            await notReady.installWhenIdle()
            check(idleAvailable.relaunchCount == 0, "UPD-07: nothing installs before the update is downloaded")
        }

        // UPD-10: honest gating without a feed
        do {
            let clock = TestClock(), driver = FakeUpdateDriver(configured: false)
            let controller = makeController(driver, defaults: updateDefaults(), clock: clock)
            await controller.checkIfDue()
            await controller.checkNow()
            check(driver.checkCount == 0, "UPD-10: without a feed no request is ever made")
            let gatedState = controller.state, gatedIndicator = controller.indicator
            check(controller.statusText == "No update feed configured"
                  && gatedState == .unconfigured && gatedIndicator == nil,
                  "UPD-10: the app says no feed is configured and shows no fake update state")
            check(!UnconfiguredUpdateDriver().isConfigured, "UPD-10: the shipped driver is unconfigured")
        }
    }
}

private final class BusyBox: @unchecked Sendable {
    var reason: AppUpdateBusyReason?
}

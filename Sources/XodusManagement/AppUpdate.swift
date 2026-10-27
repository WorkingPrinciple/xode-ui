// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import XodusCore

/// Provider-neutral app update layer (REQ-143). No provider, hosting or signing decision lives here;
/// a concrete driver (a signed feed, Sparkle, ...) plugs in behind `UpdateDriver`.

public struct UpdateVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public var description: String { components.map(String.init).joined(separator: ".") }

    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

public struct AppUpdateInfo: Equatable, Codable, Sendable {
    public let version: String
    public let buildVersion: String?
    public let releaseNotes: URL?

    public init(version: String, buildVersion: String? = nil, releaseNotes: URL? = nil) {
        self.version = version
        self.buildVersion = buildVersion
        self.releaseNotes = releaseNotes
    }

    var preferenceIdentity: String { buildVersion.map { "\(version)#\($0)" } ?? version }
}

public enum AppUpdateFeedResponse: Equatable, Sendable {
    case notModified
    case current(etag: String?)
    case available(AppUpdateInfo, etag: String?)
}

public enum AppUpdateError: Error, Equatable, Sendable {
    case unconfigured, offline, rateLimited, rejected
}

/// The only surface a provider implements. It has no way to terminate a process: relaunching is a
/// request that the controller issues only while the app is idle (UPD-07).
public protocol UpdateDriver: Sendable {
    var isConfigured: Bool { get }
    func check(etag: String?) async throws -> AppUpdateFeedResponse
    func relaunchToInstall(_ info: AppUpdateInfo) async throws
}

/// Shipped until the owner decides where releases are hosted and signed (UPD-10).
public struct UnconfiguredUpdateDriver: UpdateDriver {
    public init() {}
    public var isConfigured: Bool { false }
    public func check(etag: String?) async throws -> AppUpdateFeedResponse { throw AppUpdateError.unconfigured }
    public func relaunchToInstall(_ info: AppUpdateInfo) async throws { throw AppUpdateError.unconfigured }
}

public struct AppUpdateConditions: Equatable, Sendable {
    public var online: Bool
    public var lowDataMode: Bool
    public var lowPowerMode: Bool

    public init(online: Bool = true, lowDataMode: Bool = false, lowPowerMode: Bool = false) {
        self.online = online
        self.lowDataMode = lowDataMode
        self.lowPowerMode = lowPowerMode
    }
}

public enum AppUpdateBusyReason: Equatable, Sendable {
    case gameRunning, installActive

    public var message: String {
        switch self {
        case .gameRunning: "A game is running. The update will wait until you quit it."
        case .installActive: "A game install or operation is in progress. The update will wait until it finishes."
        }
    }
}

public enum AppUpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600
    public static let maximumJitter: TimeInterval = 3600
    public static let maximumBackoffDays = 7

    /// 1, 2, 4 days, then capped at 7.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        let days = min(maximumBackoffDays, 1 << min(failures - 1, 3))
        return TimeInterval(days) * 24 * 3600
    }

    public enum Decision: Equatable, Sendable {
        case run
        case skip(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case disabled, unconfigured, notDue, offline, lowDataMode, lowPowerMode
    }

    public static func decide(now: Date, nextCheck: Date?, autoCheck: Bool, configured: Bool,
                              conditions: AppUpdateConditions) -> Decision {
        if !autoCheck { return .skip(.disabled) }
        if !configured { return .skip(.unconfigured) }
        if let nextCheck, now < nextCheck { return .skip(.notDue) }
        if !conditions.online { return .skip(.offline) }
        if conditions.lowDataMode { return .skip(.lowDataMode) }
        if conditions.lowPowerMode { return .skip(.lowPowerMode) }
        return .run
    }
}

/// User preferences and check bookkeeping, all under `Xodus.update.*`. Only these keys are touched.
public final class AppUpdatePreferences: @unchecked Sendable {
    public static let keyPrefix = "Xodus.update."
    public static let remindInterval: TimeInterval = 24 * 3600
    private let defaults: UserDefaults
    private enum Key {
        static let autoCheck = "Xodus.update.autoCheck"
        static let skippedVersion = "Xodus.update.skippedVersion"
        static let remindUntil = "Xodus.update.remindUntil"
        static let nextCheck = "Xodus.update.nextCheck"
        static let lastCheck = "Xodus.update.lastCheck"
        static let failures = "Xodus.update.failures"
        static let etag = "Xodus.update.etag"
        static let available = "Xodus.update.available"
    }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var autoCheck: Bool {
        get { defaults.object(forKey: Key.autoCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCheck) }
    }
    public var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        set { set(newValue, Key.skippedVersion) }
    }
    public var remindUntil: Date? {
        get { date(Key.remindUntil) }
        set { set(newValue, Key.remindUntil) }
    }
    public var nextCheck: Date? {
        get { date(Key.nextCheck) }
        set { set(newValue, Key.nextCheck) }
    }
    public var lastCheck: Date? {
        get { date(Key.lastCheck) }
        set { set(newValue, Key.lastCheck) }
    }
    public var failures: Int {
        get { max(0, defaults.integer(forKey: Key.failures)) }
        set { defaults.set(max(0, newValue), forKey: Key.failures) }
    }
    public var etag: String? {
        get { defaults.string(forKey: Key.etag) }
        set { set(newValue, Key.etag) }
    }
    public var available: AppUpdateInfo? {
        get { defaults.data(forKey: Key.available).flatMap { try? JSONDecoder().decode(AppUpdateInfo.self, from: $0) } }
        set { set(newValue.flatMap { try? JSONEncoder().encode($0) }, Key.available) }
    }

    private func date(_ key: String) -> Date? {
        defaults.object(forKey: key) is Double ? Date(timeIntervalSince1970: defaults.double(forKey: key)) : nil
    }

    private func set(_ value: Any?, _ key: String) {
        if let date = value as? Date { defaults.set(date.timeIntervalSince1970, forKey: key) }
        else if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

public enum AppUpdateState: Equatable, Sendable {
    case unconfigured
    case idle
    case checking
    case upToDate
    case available(AppUpdateInfo)
    case downloading(AppUpdateInfo, fraction: Double?)
    case ready(AppUpdateInfo)
    case waiting(AppUpdateInfo, AppUpdateBusyReason)
    case relaunching(AppUpdateInfo)
}

/// What the toolbar shows beside the account avatar. `nil` means no item at all.
public struct AppUpdateIndicator: Equatable, Sendable {
    public let symbol: String
    public let label: String
    public let value: String
}

@MainActor
public final class AppUpdateController: ObservableObject {
    @Published public private(set) var state: AppUpdateState
    /// Shown only after a manual check that failed; scheduled failures stay silent (UPD-03).
    @Published public private(set) var manualFailure: String?
    @Published public private(set) var suppressionRevision = 0

    private let driver: UpdateDriver
    private let preferences: AppUpdatePreferences
    private let currentVersion: UpdateVersion?
    private let currentBuildVersion: UpdateVersion?
    private let clock: @Sendable () -> Date
    private let conditions: @MainActor () -> AppUpdateConditions
    private let busy: @MainActor () -> AppUpdateBusyReason?
    private let jitter: @Sendable () -> Double
    private var checkInFlight = false

    public init(driver: UpdateDriver, preferences: AppUpdatePreferences, currentVersion: UpdateVersion?,
                currentBuildVersion: UpdateVersion? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                conditions: @escaping @MainActor () -> AppUpdateConditions = { AppUpdateConditions() },
                busy: @escaping @MainActor () -> AppUpdateBusyReason? = { nil },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.driver = driver
        self.preferences = preferences
        self.currentVersion = currentVersion
        self.currentBuildVersion = currentBuildVersion
        self.clock = clock
        self.conditions = conditions
        self.busy = busy
        self.jitter = jitter
        if !driver.isConfigured {
            state = .unconfigured
        } else if let saved = preferences.available,
                  Self.isNewer(saved, than: currentVersion, build: currentBuildVersion) {
            state = .available(saved)
        } else {
            state = .idle
        }
    }

    public var autoCheck: Bool {
        get { preferences.autoCheck }
        set { preferences.autoCheck = newValue; objectWillChange.send() }
    }

    public var isConfigured: Bool { driver.isConfigured }

    public var statusText: String {
        switch state {
        case .unconfigured: "No update feed configured"
        case .idle: "Not checked yet"
        case .checking: "Checking for updates…"
        case .upToDate: "\(AppBrand.displayName) is up to date"
        case .available(let info): "Version \(info.version) is available"
        case .downloading(let info, _): "Downloading version \(info.version)"
        case .ready(let info): "Version \(info.version) will install when you relaunch"
        case .waiting(let info, let reason): "Version \(info.version) is waiting. \(reason.message)"
        case .relaunching(let info): "Installing version \(info.version)"
        }
    }

    public var indicator: AppUpdateIndicator? {
        let symbol = "arrow.down.app"
        switch state {
        case .available(let info):
            guard !isSuppressed(info) else { return nil }
            return AppUpdateIndicator(symbol: symbol, label: "App update available", value: "Version \(info.version)")
        case .downloading(let info, let fraction):
            let value = fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress"
            return AppUpdateIndicator(symbol: symbol, label: "Downloading app update \(info.version)", value: value)
        case .ready(let info):
            return AppUpdateIndicator(symbol: symbol, label: "App update ready to install",
                                      value: "Version \(info.version), installs when you relaunch")
        case .waiting(let info, let reason):
            return AppUpdateIndicator(symbol: symbol, label: "App update waiting",
                                      value: "Version \(info.version). \(reason.message)")
        case .relaunching(let info):
            return AppUpdateIndicator(symbol: symbol, label: "Installing app update", value: "Version \(info.version)")
        case .unconfigured, .idle, .checking, .upToDate:
            return nil
        }
    }

    /// Recomputes time-based suppression (remind later) after the snooze may have elapsed.
    public func refreshSuppression() { suppressionRevision += 1 }

    private func isSuppressed(_ info: AppUpdateInfo) -> Bool {
        if preferences.skippedVersion == info.preferenceIdentity { return true }
        if let until = preferences.remindUntil, clock() < until { return true }
        return false
    }

    public var canSkipOrRemind: Bool {
        if case .available = state { return true }
        return false
    }

    public func skipThisVersion() {
        guard case .available(let info) = state else { return }
        preferences.skippedVersion = info.preferenceIdentity
        suppressionRevision += 1
    }

    public func remindMeLater() {
        guard case .available = state else { return }
        preferences.remindUntil = clock().addingTimeInterval(AppUpdatePreferences.remindInterval)
        suppressionRevision += 1
    }

    public func checkIfDue() async {
        guard !checkInFlight else { return }
        let decision = AppUpdateSchedule.decide(now: clock(), nextCheck: preferences.nextCheck,
            autoCheck: preferences.autoCheck, configured: driver.isConfigured, conditions: conditions())
        guard decision == .run else { return }
        await perform(manual: false)
    }

    public func checkNow() async {
        guard !checkInFlight else { return }
        guard driver.isConfigured else { state = .unconfigured; return }
        await perform(manual: true)
    }

    private var pipelineActive: Bool {
        switch state {
        case .downloading, .ready, .waiting, .relaunching: true
        default: false
        }
    }

    private func perform(manual: Bool) async {
        guard !pipelineActive else { return }
        checkInFlight = true
        manualFailure = nil
        let previous = state
        state = .checking
        defer { checkInFlight = false }
        let now = clock()
        do {
            let response = try await driver.check(etag: manual ? nil : preferences.etag)
            record(success: true, now: now)
            switch response {
            case .notModified:
                state = previous == .idle ? .upToDate : previous
            case .current(let etag):
                preferences.etag = etag
                preferences.available = nil
                state = .upToDate
            case .available(let info, let etag):
                guard Self.isNewer(info, than: currentVersion, build: currentBuildVersion) else {
                    preferences.etag = etag
                    preferences.available = nil
                    state = .upToDate
                    return
                }
                preferences.etag = etag
                preferences.available = info
                if manual {
                    preferences.skippedVersion = nil
                    preferences.remindUntil = nil
                }
                state = .available(info)
            }
        } catch {
            record(success: false, now: now)
            state = previous
            if manual { manualFailure = Self.message(for: error) }
        }
    }

    private func record(success: Bool, now: Date) {
        preferences.lastCheck = now
        preferences.failures = success ? 0 : preferences.failures + 1
        let delay = AppUpdateSchedule.delay(afterFailures: preferences.failures)
        preferences.nextCheck = now.addingTimeInterval(delay + jitter() * AppUpdateSchedule.maximumJitter)
    }

    private static func isNewer(_ info: AppUpdateInfo, than current: UpdateVersion?,
                                build: UpdateVersion?) -> Bool {
        if let offeredBuild = info.buildVersion {
            guard let build, let version = UpdateVersion(offeredBuild) else { return false }
            return version > build
        }
        guard let current, let version = UpdateVersion(info.version) else { return false }
        return version > current
    }

    private static func message(for error: Error) -> String {
        switch error as? AppUpdateError {
        case .offline: "You appear to be offline. Try again when you're connected."
        case .rateLimited: "The update server asked to try again later."
        case .unconfigured: "No update feed configured"
        default: "The update check didn't finish. Try again later."
        }
    }

    /// Called when the downloaded update is ready (set by a driver once UPD-05/06 land).
    public func markReady(_ info: AppUpdateInfo) { state = .ready(info) }

    /// Install happens on relaunch and never while a game runs or an install is active (UPD-07).
    public func installWhenIdle() async {
        let info: AppUpdateInfo
        switch state {
        case .ready(let value), .waiting(let value, _): info = value
        default: return
        }
        if let reason = busy() {
            state = .waiting(info, reason)
            return
        }
        state = .relaunching(info)
        do {
            try await driver.relaunchToInstall(info)
        } catch {
            state = .ready(info)
            manualFailure = "The update could not relaunch the app. Try again when no game or install is running."
        }
    }

    /// The app calls this when a game or operation ends so a waiting update can proceed.
    public func busyStateChanged() async {
        if case .waiting = state { await installWhenIdle() }
    }
}

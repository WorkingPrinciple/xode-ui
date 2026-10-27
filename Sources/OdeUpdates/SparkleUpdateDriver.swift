// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@preconcurrency import Sparkle
import XodusManagement

/// Missing release configuration must not even construct SPUUpdater.
public struct UpdateFeedConfiguration: Sendable {
    public let isConfigured: Bool

    public init(info: [String: Any]?) {
        let feed = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = feed.flatMap(URL.init(string:))
        isConfigured = url?.scheme == "https" && url?.host != nil
            && url?.user == nil && url?.password == nil && key?.isEmpty == false
    }
}

@MainActor
protocol UpdateSession: AnyObject {
    func check() async throws -> AppUpdateFeedResponse
    func resumeInstallation(_ info: AppUpdateInfo) throws
}

/// A one-shot relaunch continuation, retained while the app is busy and checked again at invocation.
@MainActor
final class DeferredUpdateRelaunch {
    private let isBusy: () -> Bool
    private var pending: (info: AppUpdateInfo, resume: () -> Void)?

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func postpone(_ info: AppUpdateInfo, resume: @escaping () -> Void) {
        pending = (info, resume)
    }

    func resume(_ info: AppUpdateInfo) throws {
        guard let pending, pending.info == info, !isBusy() else { throw AppUpdateError.rejected }
        self.pending = nil
        pending.resume()
    }

    func cancel() { pending = nil }
}

@MainActor
public final class SparkleUpdateDriver: UpdateDriver {
    public nonisolated let isConfigured: Bool
    private let makeSession: () -> any UpdateSession
    private var session: (any UpdateSession)?

    public convenience init(bundle: Bundle = .main,
                            isBusy: @escaping @MainActor () -> Bool,
                            readyToRelaunch: @escaping @MainActor (AppUpdateInfo) -> Void) {
        self.init(configuration: UpdateFeedConfiguration(info: bundle.infoDictionary)) {
            SparkleSession(bundle: bundle, isBusy: isBusy, readyToRelaunch: readyToRelaunch)
        }
    }

    init(configuration: UpdateFeedConfiguration, makeSession: @escaping () -> any UpdateSession) {
        isConfigured = configuration.isConfigured
        self.makeSession = makeSession
    }

    public func check(etag: String?) async throws -> AppUpdateFeedResponse {
        guard isConfigured else { throw AppUpdateError.unconfigured }
        try Task.checkCancellation()
        if session == nil { session = makeSession() }
        guard let session else { throw AppUpdateError.rejected }
        // Sparkle owns HTTP caching. Do not send a second request or invent an ETag/304 response.
        return try await session.check()
    }

    public func relaunchToInstall(_ info: AppUpdateInfo) async throws {
        guard isConfigured else { throw AppUpdateError.unconfigured }
        guard let session else { throw AppUpdateError.rejected }
        try session.resumeInstallation(info)
    }
}

@MainActor
private final class SparkleSession: NSObject, UpdateSession, SPUUpdaterDelegate,
                                    @preconcurrency SPUStandardUserDriverDelegate {
    private let bundle: Bundle
    private let readyToRelaunch: (AppUpdateInfo) -> Void
    private let relaunch: DeferredUpdateRelaunch
    private var updater: SPUUpdater?
    private var result: AppUpdateFeedResponse?
    private var continuation: CheckedContinuation<AppUpdateFeedResponse, Error>?

    init(bundle: Bundle, isBusy: @escaping () -> Bool,
         readyToRelaunch: @escaping (AppUpdateInfo) -> Void) {
        self.bundle = bundle
        self.readyToRelaunch = readyToRelaunch
        relaunch = DeferredUpdateRelaunch(isBusy: isBusy)
    }

    private func startedUpdater() throws -> SPUUpdater {
        if let updater { return updater }
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        let candidate = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                   userDriver: userDriver, delegate: self)
        candidate.automaticallyChecksForUpdates = false
        candidate.automaticallyDownloadsUpdates = false
        candidate.sendsSystemProfile = false
        try candidate.start()
        updater = candidate
        return candidate
    }

    func check() async throws -> AppUpdateFeedResponse {
        guard continuation == nil else { throw AppUpdateError.rejected }
        let updater = try startedUpdater()
        guard updater.canCheckForUpdates else { throw AppUpdateError.rejected }
        result = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            updater.checkForUpdateInformation()
        }
    }

    func resumeInstallation(_ info: AppUpdateInfo) throws { try relaunch.resume(info) }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        result = .available(Self.info(item), etag: nil)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        result = .current(etag: nil)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let result {
            continuation.resume(returning: result)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: AppUpdateError.rejected)
        }
        result = nil
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let info = Self.info(item)
        relaunch.postpone(info, resume: installHandler)
        readyToRelaunch(info)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { relaunch.cancel() }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        // Information-only checks do not start a user-driver session. Scheduled checks remain
        // represented by the app's badge; only a future explicit Download action may show Sparkle UI.
    }

    private static func info(_ item: SUAppcastItem) -> AppUpdateInfo {
        AppUpdateInfo(version: item.displayVersionString, buildVersion: item.versionString,
                      releaseNotes: item.releaseNotesURL)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
final class CalimochoEngineController: ObservableObject {
    enum State: Equatable {
        case unchecked, checking, canceled, missing, detected
        case obtaining(String)
        case verified(AdmittedEngineSelection)
        case failed(String)

        var label: String {
            switch self {
            case .unchecked: "Not checked"
            case .checking: "Checking"
            case .obtaining: "Preparing"
            case .canceled: "Canceled"
            case .missing: "Not installed"
            case .detected: "Detected"
            case .verified: "Verified"
            case .failed: "Needs attention"
            }
        }
    }

    @Published private(set) var state: State = .unchecked
    @Published private(set) var updateMessage: String?
    @Published private(set) var checkingUpdates = false
    @Published private(set) var detectedRelease: CalimochoRelease?
    private let defaults: UserDefaults
    private let root: URL
    private let registries: URL
    private let inspector = EngineInspectionClient()
    private let installer = CalimochoReleaseInstaller()
    private var task: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var reservedOperations: GameOperationsController?
    private var terminating = false

    init(defaults: UserDefaults = .standard,
         root: URL = CalimochoInstalledRelease.enginesRoot,
         registries: URL = CalimochoInstalledRelease.registriesRoot) {
        self.defaults = defaults
        self.root = root
        self.registries = registries
    }

    var isWorking: Bool { task != nil || reservedOperations != nil }
    var isVerified: Bool {
        if case .verified = state { return true }
        return false
    }

    var availableUpdate: Bool { detectedRelease == .release04 && isVerified }

    private static let preferenceKeys = [
        EngineDefaults.defaultEngineKey, NativeEngineDefaults.preferenceKey,
        AdmittedEngineSelection.preferenceKey, "Xodus.lifecycle.registry", "Xodus.lifecycle.engine.calimocho"
    ]

    private var preferences: NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues:
            Self.preferenceKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }))
    }

    func refresh(configuration: BackendConfiguration?, selectAsDefault: Bool = false) {
        guard !isWorking, !terminating else { return }
        let expected = preferences
        let preferred = defaults.string(forKey: "Xodus.lifecycle.registry")
        let savedRelease = defaults.data(forKey: NativeEngineDefaults.preferenceKey)
            .flatMap { try? JSONDecoder().decode(AdmittedEngineSelection.self, from: $0) }
            .flatMap { $0.inspection.engineName.flatMap(CalimochoRelease.init(rawValue:)) }
        let preferredRelease = selectAsDefault ? (detectedRelease ?? savedRelease) : savedRelease
        let root = root, registries = registries
        state = .checking
        task = Task { [self] in
            do {
                let worker = Task.detached {
                    if let preferredRelease {
                        return (preferredRelease, try CalimochoInstalledRelease.locate(release: preferredRelease,
                            root: root, registries: registries, preferredRegistry: preferred))
                    }
                    do {
                        return (CalimochoRelease.release06, try CalimochoInstalledRelease.locate(
                            root: root, registries: registries, preferredRegistry: preferred))
                    } catch CalimochoInstalledRelease.Failure.notInstalled {
                        return (CalimochoRelease.release04, try CalimochoInstalledRelease.locate(release: .release04,
                            root: root, registries: registries, preferredRegistry: preferred))
                    }
                }
                let (pin, release) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                detectedRelease = pin
                guard let configuration else {
                    if selectAsDefault { throw EngineInspectionError.unsupported }
                    state = .detected
                    task = nil
                    return
                }
                let result = try await inspector.inspect(executable: configuration.executable,
                    registry: release.registry, engine: pin.rawValue,
                    expectedDigest: release.registrySHA256, executableIdentity: configuration.executableIdentity)
                if !result.ready, let failure = result.error { throw EngineInspectionError.rejected(failure) }
                let selection = AdmittedEngineSelection(registryPath: release.registry.path, inspection: result)
                try selection.validate(registryPath: release.registry.path,
                    engineName: pin.rawValue, registryDigest: release.registrySHA256)
                guard result.wineSha256 == pin.wineSHA256,
                      result.wineserverSha256 == pin.wineserverSHA256 else {
                    throw NativeLaunchError.selectionChanged
                }
                try Task.checkCancellation()
                if selectAsDefault {
                    guard preferences == expected else { throw NativeLaunchError.selectionChanged }
                    let bytes = try JSONEncoder().encode(selection)
                    defaults.set(bytes, forKey: NativeEngineDefaults.preferenceKey)
                    defaults.set(bytes, forKey: AdmittedEngineSelection.preferenceKey)
                    defaults.set(release.registry.path, forKey: "Xodus.lifecycle.registry")
                    defaults.set(pin.rawValue, forKey: "Xodus.lifecycle.engine.calimocho")
                    EngineDefaults.setDefaultEngine(.calimocho, defaults)
                }
                state = .verified(selection)
            } catch is CancellationError {
                state = .canceled
            } catch CalimochoInstalledRelease.Failure.notInstalled {
                detectedRelease = nil
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func obtainLatest(configuration: BackendConfiguration, operations: GameOperationsController,
                      cachedArchive: URL? = nil) {
        guard !isWorking, !terminating else { return }
        let expected = preferences
        let previous: AdmittedEngineSelection?
        if case .verified(let selection) = state { previous = selection } else { previous = nil }
        let switchDefault = previous?.inspection.engineName == CalimochoRelease.release04.rawValue
            && EngineDefaults.defaultEngine(defaults) == .calimocho
        do {
            if switchDefault {
                guard let saved = defaults.data(forKey: NativeEngineDefaults.preferenceKey),
                      try JSONDecoder().decode(AdmittedEngineSelection.self, from: saved) == previous else {
                    throw NativeLaunchError.selectionChanged
                }
            }
            try operations.reserveEngineChange()
            reservedOperations = operations
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .obtaining("Preparing Calimocho \(CalimochoRelease.release06.version)")
        task = Task { [self] in
            defer {
                if !installer.hasUnjoinedWork {
                    reservedOperations?.releaseEngineChange()
                    reservedOperations = nil
                }
                task = nil
            }
            do {
                let selection = try await installer.obtain(.release06, root: root, registries: registries,
                    configuration: configuration, cachedArchive: cachedArchive) { [weak self] message in
                        await MainActor.run { self?.state = .obtaining(message) }
                    }
                try Task.checkCancellation()
                guard preferences == expected else { throw NativeLaunchError.selectionChanged }
                if switchDefault {
                    let bytes = try JSONEncoder().encode(selection)
                    defaults.set(bytes, forKey: NativeEngineDefaults.preferenceKey)
                    defaults.set(bytes, forKey: AdmittedEngineSelection.preferenceKey)
                    defaults.set(selection.registryPath, forKey: "Xodus.lifecycle.registry")
                    defaults.set(CalimochoRelease.release06.rawValue, forKey: "Xodus.lifecycle.engine.calimocho")
                }
                detectedRelease = .release06
                state = .verified(selection)
                updateMessage = switchDefault
                    ? "Calimocho updated to \(CalimochoRelease.release06.version). The previous engine and title-specific choices were kept."
                    : "Calimocho \(CalimochoRelease.release06.version) is installed and verified. Your default is unchanged."
            } catch is CancellationError {
                state = .canceled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func checkForUpdates(force: Bool = false) {
        guard updateTask == nil, !terminating else { return }
        let key = "Xodus.calimocho.lastUpdateCheck"
        if !force, let date = defaults.object(forKey: key) as? Date,
           Date().timeIntervalSince(date) >= 0, Date().timeIntervalSince(date) < 86_400 { return }
        checkingUpdates = true
        updateTask = Task { [self] in
            defer { checkingUpdates = false; updateTask = nil }
            do {
                struct Release: Decodable { let tag_name: String; let draft: Bool }
                let url = URL(string: "https://api.github.com/repos/WorkingPrinciple/calimocho/releases?per_page=100")!
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (stream, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
                      http.url?.host == "api.github.com" else { throw CalimochoInstallFailure.archive }
                guard http.statusCode == 200 else {
                    updateMessage = [403, 429].contains(http.statusCode)
                        ? "GitHub's release check is rate limited. Try again later."
                        : "Calimocho updates couldn't be checked (HTTP \(http.statusCode)). Try again."
                    return
                }
                var data = Data()
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard data.count < 1_048_576 else { throw CalimochoInstallFailure.archive }
                    data.append(byte)
                }
                let releases = try JSONDecoder().decode([Release].self, from: data).filter {
                    !$0.draft && $0.tag_name.utf8.count <= 64
                        && $0.tag_name.range(of: "^engine-[0-9]+(\\.[0-9]+){3}$", options: .regularExpression) != nil
                }
                guard let newest = releases.max(by: {
                    $0.tag_name.compare($1.tag_name, options: .numeric) == .orderedAscending
                }) else { throw CalimochoInstallFailure.archive }
                if newest.tag_name.compare(CalimochoRelease.release06.tag, options: .numeric) == .orderedDescending {
                    updateMessage = "\(newest.tag_name) is available and needs a matching Ode to X update. Only this app's pinned Calimocho release can be installed."
                } else if availableUpdate {
                    updateMessage = "Calimocho \(CalimochoRelease.release06.version) is available. Update keeps your previous engine."
                } else {
                    updateMessage = isVerified ? "Your pinned Calimocho release is up to date." : "The pinned Calimocho release is available to download."
                }
                defaults.set(Date(), forKey: key)
            } catch is CancellationError {
                updateMessage = "The update check was canceled."
            } catch {
                updateMessage = "Calimocho updates couldn't be checked: \(error.localizedDescription)"
            }
        }
    }

    func cancel() { task?.cancel() }

    func waitForRefresh() async { await task?.value }

    func waitForUpdateCheck() async { await updateTask?.value }

    func shutdownForApplicationTermination() async -> Bool {
        terminating = true
        task?.cancel()
        updateTask?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while task != nil || updateTask != nil, ContinuousClock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        guard task == nil, updateTask == nil else {
            state = .failed("Calimocho verification hasn't stopped. Keep Ode to X open and retry quitting.")
            return false
        }
        do {
            try await inspector.closeOwnedProcess()
            try await installer.close()
            reservedOperations?.releaseEngineChange()
            reservedOperations = nil
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    func resumeAfterTerminationRefusal() { terminating = false }
}

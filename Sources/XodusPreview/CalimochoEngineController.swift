// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
final class CalimochoEngineController: ObservableObject {
    enum State: Equatable {
        case unchecked, checking, canceled, missing, detected
        case verified(AdmittedEngineSelection)
        case failed(String)

        var label: String {
            switch self {
            case .unchecked: "Not checked"
            case .checking: "Checking"
            case .canceled: "Canceled"
            case .missing: "Not installed"
            case .detected: "Detected"
            case .verified: "Verified"
            case .failed: "Needs attention"
            }
        }
    }

    @Published private(set) var state: State = .unchecked
    private let defaults: UserDefaults
    private let root: URL
    private let registries: URL
    private let inspector = EngineInspectionClient()
    private var task: Task<Void, Never>?
    private var terminating = false

    init(defaults: UserDefaults = .standard,
         root: URL = CalimochoInstalledRelease.enginesRoot,
         registries: URL = CalimochoInstalledRelease.registriesRoot) {
        self.defaults = defaults
        self.root = root
        self.registries = registries
    }

    var isWorking: Bool { task != nil }
    var isVerified: Bool {
        if case .verified = state { return true }
        return false
    }

    private static let preferenceKeys = [
        EngineDefaults.defaultEngineKey, NativeEngineDefaults.preferenceKey,
        AdmittedEngineSelection.preferenceKey, "Xodus.lifecycle.registry", "Xodus.lifecycle.engine.calimocho"
    ]

    private var preferences: NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues:
            Self.preferenceKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }))
    }

    func refresh(configuration: BackendConfiguration?, selectAsDefault: Bool = false) {
        guard task == nil, !terminating else { return }
        let expected = preferences
        let preferred = defaults.string(forKey: "Xodus.lifecycle.registry")
        let root = root, registries = registries
        state = .checking
        task = Task { [self] in
            do {
                let worker = Task.detached {
                    try CalimochoInstalledRelease.locate(root: root, registries: registries,
                                                        preferredRegistry: preferred)
                }
                let release = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let configuration else {
                    if selectAsDefault { throw EngineInspectionError.unsupported }
                    state = .detected
                    task = nil
                    return
                }
                let result = try await inspector.inspect(executable: configuration.executable,
                    registry: release.registry, engine: CalimochoInstalledRelease.engineName,
                    expectedDigest: release.registrySHA256, executableIdentity: configuration.executableIdentity)
                if !result.ready, let failure = result.error { throw EngineInspectionError.rejected(failure) }
                let selection = AdmittedEngineSelection(registryPath: release.registry.path, inspection: result)
                try selection.validate(registryPath: release.registry.path,
                    engineName: CalimochoInstalledRelease.engineName, registryDigest: release.registrySHA256)
                guard result.wineSha256 == CalimochoInstalledRelease.wineSHA256,
                      result.wineserverSha256 == CalimochoInstalledRelease.wineserverSHA256 else {
                    throw NativeLaunchError.selectionChanged
                }
                try Task.checkCancellation()
                if selectAsDefault {
                    guard preferences == expected else { throw NativeLaunchError.selectionChanged }
                    let bytes = try JSONEncoder().encode(selection)
                    defaults.set(bytes, forKey: NativeEngineDefaults.preferenceKey)
                    defaults.set(bytes, forKey: AdmittedEngineSelection.preferenceKey)
                    defaults.set(release.registry.path, forKey: "Xodus.lifecycle.registry")
                    defaults.set(CalimochoInstalledRelease.engineName, forKey: "Xodus.lifecycle.engine.calimocho")
                    EngineDefaults.setDefaultEngine(.calimocho, defaults)
                }
                state = .verified(selection)
            } catch is CancellationError {
                state = .canceled
            } catch CalimochoInstalledRelease.Failure.notInstalled {
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func waitForRefresh() async { await task?.value }

    func shutdownForApplicationTermination() async -> Bool {
        terminating = true
        task?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while task != nil, ContinuousClock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        guard task == nil else {
            state = .failed("Calimocho verification hasn't stopped. Keep Ode to X open and retry quitting.")
            return false
        }
        do {
            try await inspector.closeOwnedProcess()
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    func resumeAfterTerminationRefusal() { terminating = false }
}

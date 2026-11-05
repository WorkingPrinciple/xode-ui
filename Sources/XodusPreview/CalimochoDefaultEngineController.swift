// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
final class CalimochoDefaultEngineController: ObservableObject {
    enum State: Equatable {
        case waiting, skipped, working(CalimochoInstallProgress)
        case ready(AdmittedEngineSelection)
        case failed(String)
    }

    @Published private(set) var state: State = .waiting
    private let service: CalimochoReleaseInstallService
    private let registries: URL
    private let defaults: UserDefaults
    private let inspector = EngineInspectionClient()
    private var task: Task<Void, Never>?
    private var terminating = false

    init(root: URL = CalimochoReleaseEngines.defaultEnginesRoot,
         registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot,
         defaults: UserDefaults = .standard,
         verification: CalimochoVerificationWork = CalimochoVerificationWork()) {
        service = CalimochoReleaseInstallService(root: root, verification: verification)
        self.registries = registries
        self.defaults = defaults
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isWorking: Bool { task != nil }

    static func mayPrepareAutomatically(defaults: UserDefaults, registries: URL) throws -> Bool {
        try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults, registries: registries)
    }

    func prepare(configuration: BackendConfiguration, automatic: Bool = false) {
        guard task == nil, !terminating else { return }
        guard !service.verification.isRunning, !CalimochoExtractionRecovery.shared.hasLiveProcess() else {
            state = .failed(CalimochoInstallError.verificationShutdownFailed.localizedDescription)
            return
        }
        let expected = NativeEngineDefaults.PreferenceSnapshot(defaults)
        let maySave: Bool
        do {
            maySave = try NativeEngineDefaults.mayPrepareAutomatically(
                defaults: defaults, enginesRoot: service.root, registries: registries)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        if automatic {
            guard maySave else {
                state = .skipped
                return
            }
        }
        state = .working(.preparing)
        task = Task { [self] in
            let service = self.service
            do {
                do {
                    _ = try await service.verification.run { cancellation in
                        try CalimochoReleaseEngines.verify(service.pin, root: service.root,
                                                           checkCancellation: cancellation.check)
                    }
                } catch CalimochoReleaseError.notInstalled {
                    try Task.checkCancellation()
                    _ = try await service.install { [weak self] value in
                        await MainActor.run { self?.state = .working(value) }
                    }
                }
                try Task.checkCancellation()
                state = .working(.checkingAdmission)
                let pin = service.pin
                let binding = NativeEngineDefaults.Binding(
                    registryPath: nil, registrySha256: nil, engineName: pin.engineName,
                    wineSha256: pin.wineSha256, wineserverSha256: pin.wineserverSha256)
                let selection = try await binding.inspect(configuration: configuration, inspector: inspector,
                    enginesRoot: service.root, registries: registries, verification: service.verification)
                try Task.checkCancellation()
                if maySave {
                    try NativeEngineDefaults.commitAutomatic(selection, expected: expected, defaults: defaults,
                                                             enginesRoot: service.root, registries: registries)
                }
                state = .ready(selection)
            } catch is CancellationError {
                state = .failed("Calimocho preparation was canceled. Existing engines, games and saves were not changed.")
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func shutdownForApplicationTermination() async -> Bool {
        terminating = true
        let pending = task
        pending?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while task != nil, ContinuousClock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        guard task == nil, !service.verification.isRunning else {
            state = .failed(CalimochoInstallError.verificationShutdownFailed.localizedDescription)
            return false
        }
        do {
            try await inspector.closeOwnedProcess()
            return !CalimochoExtractionRecovery.shared.hasLiveProcess()
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    func resumeAfterTerminationRefusal() { terminating = false }
}

struct CalimochoPreparationControls: View {
    @ObservedObject var controller: CalimochoDefaultEngineController
    let configuration: BackendConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch controller.state {
            case .waiting:
                Text("Waiting for the app's game service before preparing Calimocho.")
            case .skipped:
                Text("Your existing engine choice is unchanged.")
                prepareButton("Prepare Calimocho")
            case .working(let progress):
                if let fraction = progress.fraction {
                    ProgressView(progress.label, value: fraction)
                } else {
                    ProgressView(progress.label)
                }
                Button("Cancel preparation") { controller.cancel() }
            case .ready:
                Text("Calimocho is installed and admitted. This does not verify a game.")
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                prepareButton("Retry Calimocho")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("xodus.calimocho.preparation")
    }

    private func prepareButton(_ title: String) -> some View {
        Button(title) {
            if let configuration { controller.prepare(configuration: configuration) }
        }
        .disabled(configuration == nil || controller.isWorking)
    }
}

struct CalimochoPreparationBanner: View {
    @ObservedObject var controller: CalimochoDefaultEngineController
    let configuration: BackendConfiguration?

    var body: some View {
        switch controller.state {
        case .working, .failed:
            CalimochoPreparationControls(controller: controller, configuration: configuration)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial)
        default:
            EmptyView()
        }
    }
}

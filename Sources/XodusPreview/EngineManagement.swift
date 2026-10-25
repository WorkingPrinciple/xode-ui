// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

enum EngineObservationStatus: String, CaseIterable {
    case notChecked = "Not checked"
    case loading = "Checking"
    case missing = "Missing"
    case detected = "Detected"
    case usable = "Smoke tested"
    case qualified = "Game qualified"
    case unsupported = "Unsupported"
    case error = "Check failed"
}

/// The released Calimocho engine Xode points users to. Presence is a read-only file check;
/// verification and admission belong to the engine-inspection path.
enum CalimochoRelease {
    static let engineID = "calimocho-11.20-4.0b3-01"
    static let getTitle = "Get Calimocho (beta)"
    /// Release tag page. The asset isn't published yet (owner decision); the one place to change it.
    static let downloadURL = URL(string: "https://github.com/dragoshont/calimocho/releases/tag/engine-11.20-4.0b3-01")!

    static func manifest(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Xode/Engines", isDirectory: true)
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent("calimocho-engine.json")
    }

    static func isPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: manifest(home: home).path)
    }
}

enum EngineManagementPolicy {
    static let calimochoSource = URL(string: "https://github.com/dragoshont/calimocho")!

    static func matches(_ entry: NativeEngineRegistry.Entry, provider: RuntimeProviderKind) -> Bool {
        switch provider {
        case .calimocho: entry.provider?.id == "calimocho"
        case .crossover: entry.kind.lowercased() == "crossover"
        case .standaloneWine: entry.kind.lowercased() == "free" && entry.provider?.id != "calimocho"
        case .gptk3, .gptk4: false
        }
    }

    static func status(_ entry: NativeEngineRegistry.Entry,
                       executableExists: (URL) -> Bool = RunnerAvailabilityDetector.isExecutable)
        -> EngineObservationStatus {
        guard ["free", "crossover"].contains(entry.kind.lowercased()), entry.provider?.id != "calimocho" else { return .unsupported }
        guard entry.wine.hasPrefix("/") else { return .error }
        guard executableExists(URL(fileURLWithPath: entry.wine)) else { return .missing }
        guard entry.presentation_validation?.status != "failed",
              entry.smoke_test.status != "failed" else { return .unsupported }
        return entry.smoke_test.status == "pass" ? .usable : .detected
    }
}

@MainActor
final class EngineRegistryObservation: ObservableObject {
    @Published private(set) var entries: [NativeEngineRegistry.Entry] = []
    @Published private(set) var status: EngineObservationStatus = .notChecked
    @Published private(set) var errorMessage: String?
    @Published private(set) var inspections: [String: EngineInspection] = [:]
    @Published private(set) var inspectionMessage: String?
    private let inspector: EngineInspectionClient
    private var revision = UUID()

    init(inspector: EngineInspectionClient = EngineInspectionClient()) {
        self.inspector = inspector
    }

    func refresh(path: String, allowsFileReads: Bool, executable: URL? = nil,
                 executableIdentity: NativeAuthHostBinding? = nil) async {
        let token = UUID()
        revision = token
        entries = []
        errorMessage = nil
        inspections = [:]
        inspectionMessage = nil
        guard allowsFileReads else { status = .notChecked; return }
        guard !path.isEmpty else { status = .missing; return }
        status = .loading
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try NativeEngineRegistry.read(URL(fileURLWithPath: path))
            }.value
            guard token == revision, !Task.isCancelled else { return }
            entries = loaded.engines
            status = entries.isEmpty ? .missing : .detected
            let candidates = entries.filter { $0.provider?.id == "calimocho" }
            guard !candidates.isEmpty else { return }
            guard let executable else {
                inspectionMessage = EngineInspectionError.unsupported.localizedDescription
                return
            }
            guard candidates.count <= 16 else {
                inspectionMessage = "Too many provider records to inspect. Choose a registry with at most 16 Calimocho candidates."
                return
            }
            status = .loading
            for entry in candidates {
                let result = try await inspector.inspect(executable: executable,
                    registry: URL(fileURLWithPath: path), engine: entry.name,
                    expectedDigest: loaded.byteDigest, executableIdentity: executableIdentity)
                guard token == revision, !Task.isCancelled else { return }
                inspections[entry.name] = result
            }
            status = .detected
        } catch {
            guard token == revision, !Task.isCancelled else { return }
            if entries.isEmpty {
                status = .error
                errorMessage = "The engine registry couldn't be read safely. Choose the current registry JSON or retry Refresh."
            } else {
                status = .detected
                inspectionMessage = (error as? EngineInspectionError)?.localizedDescription
                    ?? "Provider inspection failed. Retry Refresh; no provider was admitted."
            }
        }
    }
}

struct EngineProviderOverview: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var inspections: [String: EngineInspection] = [:]
    var allowsCheck = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Calimocho", value: inspections.values.contains(where: {
                    $0.ready && $0.admittedProvider == "calimocho"
                }) ? "Admitted local build" : "Identification unavailable")
                    .font(.headline)
                Link("Calimocho official source", destination: EngineManagementPolicy.calimochoSource)
                    .accessibilityIdentifier("xodus.engines.calimocho.source")
            }
            .accessibilityElement(children: .contain)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("CrossOver", value: crossOverStatus)
                    .font(.headline)
                if case .installed(let app) = settings.crossOverDependency {
                    LabeledContent("Version", value: "\(app.version) (build \(app.buildVersion))")
                    Text(app.location.path).font(.caption).textSelection(.enabled)
                } else {
                    Text(settings.crossOverDependency.explanation).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { crossOverActions }
                    VStack(alignment: .leading, spacing: 8) { crossOverActions }
                }
            }
            .accessibilityElement(children: .contain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var crossOverStatus: String {
        switch settings.crossOverDependency {
        case .notChecked: "Not checked"
        case .checking: "Checking signature"
        case .absent: "Missing"
        case .unverified: "Check failed"
        case .installed: "Detected"
        }
    }

    @ViewBuilder private var crossOverActions: some View {
        Button("Refresh detection") { Task { await settings.refreshCrossOverDependency() } }
            .disabled(!allowsCheck || settings.checkingDependency || settings.planning || settings.applicationTerminating)
            .accessibilityIdentifier("xodus.engines.refresh")
        if !settings.crossOverDependency.isVerified {
            Link("Get CrossOver from CodeWeavers", destination: CrossOverDependencyState.trialDownloadURL)
                .accessibilityIdentifier("xodus.engines.crossover.get")
        }
    }
}

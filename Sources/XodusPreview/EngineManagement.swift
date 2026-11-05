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

enum EngineManagementPolicy {
    static let calimochoSource = URL(string: "https://github.com/dragoshont/calimocho")!
    static let selectionExplanation = """
        Per-game Calimocho choices keep their exact saved registry and artifact identity independently of the default. A conflicting title recipe or unavailable configuration refuses launch without substituting CrossOver, GPTK or generic Wine. No bottle or save is moved.
        """
    static let qualificationExplanation = """
        Detection observes files. Smoke tested means the local record reports a passed smoke test and its executable is present, not that hashes or a game were verified. The launch service validates registered artifacts again. Game qualification belongs to an exact title recipe, never the whole provider.
        """

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
              entry.smoke_test?.status != "failed" else { return .unsupported }
        return entry.smoke_test?.status == "pass" ? .usable : .detected
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
            let candidates = entries.filter { $0.kind.lowercased() == "free" || $0.provider?.id == "calimocho" }
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

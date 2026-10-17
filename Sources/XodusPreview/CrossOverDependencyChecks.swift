// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Security
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
enum CrossOverDependencyChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let location = URL(fileURLWithPath: "/Applications/CrossOver.app")
        let installation = CrossOverInstallation(location: location, version: "26.3", buildVersion: "26.3.0.39832")
        let installed = CrossOverDependencyState.installed(installation)
        let fields: [String: Any] = [
            "CFBundleIdentifier": CrossOverDetector.identifier, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "26.3", "CFBundleVersion": "26.3.0.39832",
            "TeamIdentifier": CrossOverDetector.publisherTeam
        ]
        func metadata(_ fields: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
        }
        let data = try metadata(fields)
        var requirement: SecRequirement?
        check(SecRequirementCreateWithString(CrossOverDetector.requirement as CFString, [], &requirement)
              == errSecSuccess && requirement != nil && !CrossOverDetector.requirement.hasPrefix("="),
              "RT01 Apple Security parses the approved plain requirement without codesign filename syntax")
        check(CrossOverDetector.requirement.contains("anchor apple generic")
              && CrossOverDetector.requirement.contains("com.codeweavers.CrossOver")
              && CrossOverDetector.requirement.contains("9C6B7X7Z8E"),
              "RT01 Publisher identifier, team and Apple Developer ID anchor are fixed independently of candidate metadata")
        check(CrossOverDetector.evaluate(metadata: data, signatureTrusted: true, location: location) == installed,
              "RT01 Neutral verified identity retains distinct observed CrossOver version and build")
        check(CrossOverDetector.evaluate(metadata: data, signatureTrusted: false, location: location) == .unverified,
              "RT01 Candidate self-reported approved team cannot overcome a wrong signer or failed signature")
        var wrong = fields
        wrong["CFBundleIdentifier"] = "invalid.example.other"
        check(CrossOverDetector.evaluate(metadata: try metadata(wrong), signatureTrusted: true, location: location) == .unverified,
              "RT01 Wrong bundle identifier cannot borrow an approved signature observation")
        wrong = fields
        wrong["CFBundleShortVersionString"] = 26
        check(CrossOverDetector.evaluate(metadata: try metadata(wrong), signatureTrusted: true, location: location) == .unverified,
              "RT01 Malformed version metadata is rejected rather than guessed from its build")
        wrong = fields
        wrong.removeValue(forKey: "CFBundleVersion")
        check(CrossOverDetector.evaluate(metadata: try metadata(wrong), signatureTrusted: true, location: location) == .unverified,
              "RT01 Missing build metadata does not fabricate an observed build")
        check(CrossOverDetector.evaluate(metadata: Data(repeating: 0, count: 65_537),
                                         signatureTrusted: true, location: location) == .unverified,
              "RT01 Oversized metadata is bounded before plist parsing")
        check(CrossOverDetector.evaluate(metadata: Data("malformed".utf8),
                                         signatureTrusted: true, location: location) == .unverified,
              "RT01 Invalid plist metadata is an explicit unverified installation")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("XodusCrossOverChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "RT01 Owned neutral metadata test cleanup succeeds") }
        }
        let candidate = root.appendingPathComponent("Neutral.app")
        check(CrossOverDetector.inspect(candidate) == .absent,
              "RT01 Missing approved-location candidate is absent, not installed")
        try FileManager.default.createDirectory(at: candidate.appendingPathComponent("Contents"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let info = candidate.appendingPathComponent("Contents/Info.plist")
        try data.write(to: info)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: info.path)
        check(CrossOverDetector.inspect(candidate) == .unverified,
              "RT01 Actual Apple static-code verification rejects an unsigned neutral app without executing it")
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: candidate)
        check(CrossOverDetector.inspect(link) == .unverified,
              "RT01 Linked app roots cannot satisfy canonical installation admission")
        try FileManager.default.removeItem(at: info)
        let outside = root.appendingPathComponent("metadata.plist")
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: info, withDestinationURL: outside)
        check(CrossOverDetector.inspect(candidate) == .unverified,
              "RT01 Linked bundle metadata fails before a publisher observation")

        let fresh = RuntimeProviderSettings(detectCrossOver: { installed })
        check(fresh.configuration == nil && fresh.crossOverDependency == .notChecked,
              "RT02 A new profile starts unchecked rather than inventing an installation")
        await fresh.refreshCrossOverDependency()
        check(fresh.configuration?.provider == .crossover && fresh.configuration?.providerVersion == "26.3"
              && fresh.configuration?.engine.version == nil && fresh.configuration?.graphics.backend == nil
              && fresh.plan == nil && !fresh.requiresExperimentalAcknowledgement,
              "RT02 Verified official CrossOver defaults only the new provider, never Wine, graphics or a launch plan")
        fresh.select(nil)
        await fresh.refreshCrossOverDependency()
        check(fresh.configuration == nil,
              "RT03 An explicitly cleared provider is not silently restored by dependency refresh")
        for state in [CrossOverDependencyState.absent, .unverified] {
            let missing = RuntimeProviderSettings(detectCrossOver: { state })
            await missing.refreshCrossOverDependency()
            check(missing.configuration == nil && missing.crossOverDependency == state && missing.plan == nil,
                  "RT02 Absent or unverified CrossOver cannot create an installed default")
            missing.select(.crossover)
            missing.makePlan(executable: root.appendingPathComponent("must-not-execute"))
            let missingChild = await missing.hasOwnedPlanningProcess
            check(missing.planningBlocker != nil && missing.errorMessage != nil && !missing.planning
                  && !missingChild,
                  "RT02 Unverified first-release configuration cannot start a planner child")
        }
        var explicit = RuntimeProviderConfiguration.preset(.gptk4)
        explicit.providerVersion = "user-profile"
        explicit.engine.version = "11.0"
        explicit.graphics.version = "4.0"
        let restored = try JSONDecoder().decode(RuntimeProviderConfiguration.self, from: JSONEncoder().encode(explicit))
        let alternative = RuntimeProviderSettings(configuration: restored, detectCrossOver: { installed })
        await alternative.refreshCrossOverDependency()
        await alternative.refreshCrossOverDependency()
        check(alternative.configuration == restored && alternative.requiresExperimentalAcknowledgement
              && alternative.planningBlocker != nil,
              "RT03 A decoded explicit alternative survives startup and repeat refresh without release promotion")
        alternative.makePlan(executable: root.appendingPathComponent("must-not-execute"))
        let alternativeChild = await alternative.hasOwnedPlanningProcess
        check(!alternative.planning && alternative.errorMessage?.contains("Experimental") == true
              && !alternativeChild,
              "RT03 Experimental planning is fenced before explicit acknowledgement, without a child")
        alternative.acknowledgeExperimental(true)
        await alternative.refreshCrossOverDependency()
        check(alternative.experimentalAcknowledged && alternative.planningBlocker == nil,
              "RT03 Unchanged installation refresh preserves a user's accepted experimental profile")
        alternative.update { $0.engine.version = "12.0" }
        check(!alternative.experimentalAcknowledged && alternative.planningBlocker != nil,
              "RT03 Changing an engine component invalidates experimental acknowledgement")
        alternative.acknowledgeExperimental(true)
        alternative.select(.standaloneWine)
        check(!alternative.experimentalAcknowledged && alternative.configuration?.provider == .standaloneWine,
              "RT03 Changing provider invalidates acknowledgement without rewriting the explicit choice")
        let custom = RuntimeProviderSettings(configuration: .preset(.crossover), detectCrossOver: { installed })
        await custom.refreshCrossOverDependency()
        custom.update { $0.graphics = .init(backend: .dxvk, provenance: .crossOverBundled) }
        check(custom.requiresExperimentalAcknowledgement && custom.planningBlocker != nil,
              "RT03 A declared graphics override remains Experimental even when labelled CrossOver bundled")
        let gate = CrossOverObservationGate()
        let pending = RuntimeProviderSettings(detectCrossOver: { await gate.observe() })
        let observation = Task { await pending.refreshCrossOverDependency() }
        try await waitForObservation(gate)
        pending.select(.standaloneWine)
        pending.acknowledgeExperimental(true)
        check(pending.checkingDependency && pending.planningBlocker != nil,
              "RT03 A pending installation observation fences new configuration planning")
        await gate.release(installed)
        await observation.value
        check(pending.configuration?.provider == .standaloneWine && !pending.experimentalAcknowledged,
              "RT03 A late startup observation preserves the newer explicit choice and resets changed-evidence acknowledgement")
        let quitGate = CrossOverObservationGate()
        let quitting = RuntimeProviderSettings(detectCrossOver: { await quitGate.observe() })
        let quitObservation = Task { await quitting.refreshCrossOverDependency() }
        try await waitForObservation(quitGate)
        quitting.beginApplicationTermination()
        await quitGate.release(installed)
        await quitObservation.value
        check(quitting.configuration == nil && !quitting.checkingDependency
              && quitting.crossOverDependency == .notChecked,
              "RT02 A read-only observation completing after Quit cannot adopt a provider")
        for state in [CrossOverDependencyState.absent, .unverified, installed] {
            let presentation = RuntimeProviderSettings(detectCrossOver: { state })
            await presentation.refreshCrossOverDependency()
            check(state.explanation.contains("license") && state.explanation.contains(
                state.isVerified ? "Game readiness is checked separately" : "official"),
                  "RT04 Shared dependency copy distinguishes app identity from license and gameplay evidence")
            for width in [CGFloat(440), CGFloat(560)] {
                let host = NSHostingView(rootView: RuntimeDependencyStatus(settings: presentation,
                    allowsCheck: false, offersSettings: true))
                host.sizingOptions = []
                host.frame = CGRect(x: 0, y: 0, width: width, height: 280)
                host.layoutSubtreeIfNeeded()
                check(host.window == nil && host.frame.width == width,
                      "RT04 Actual shared native dependency view lays out at constrained widths without a window")
            }
        }
        check(RuntimeProviderSettings.providerChoices.first == .crossover
              && RuntimeProviderKind.allCases.filter { $0 != .crossover }.allSatisfy {
                  RuntimeProviderSettings.providerLabel($0).contains("Experimental")
              }, "RT04 First-release provider is first; every alternative is explicitly Experimental")
    }

    private static func waitForObservation(_ gate: CrossOverObservationGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting) {
            guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
            await Task.yield()
        }
    }
}

private actor CrossOverObservationGate {
    private var continuation: CheckedContinuation<CrossOverDependencyState, Never>?
    var waiting: Bool { continuation != nil }
    func observe() async -> CrossOverDependencyState {
        await withCheckedContinuation { continuation = $0 }
    }
    func release(_ state: CrossOverDependencyState) {
        continuation?.resume(returning: state)
        continuation = nil
    }
}

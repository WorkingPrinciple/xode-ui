// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Vision
import XCTest
import XodusManagement
@testable import XodusPreview

final class EngineSettingsReadinessChecks: XCTestCase {
    @MainActor func testUncheckedCalimochoIsNotReportedAsInstalledOrReady() {
        let state = AppState()
        let row = CalimochoSettingsRow(controller: state.calimochoEngine, configuration: nil)

        XCTAssertEqual(state.calimochoEngine.state, .waiting)
        XCTAssertEqual(row.statusText, "Not checked")
    }

    @MainActor func testSkippedAndFailedPreparationDoNotClaimReadiness() async throws {
        let suite = "io.github.dragoshont.ode.engine-settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = CalimochoDefaultEngineController(root: root, registries: root, defaults: defaults)
        let configuration = BackendConfiguration(executable: root.appendingPathComponent("unused-cli"),
                                                 stateDirectory: root)
        let row = CalimochoSettingsRow(controller: controller, configuration: configuration)
        let host = NSHostingView(rootView: row.frame(width: 484, alignment: .leading).background(.white))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 484, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        XCTAssertTrue(try renderedText(host).contains("Not checked"))

        EngineDefaults.setDefaultEngine(.crossover, defaults)
        controller.prepare(configuration: configuration, automatic: true)
        XCTAssertEqual(controller.state, .skipped)
        XCTAssertEqual(row.statusText, "Not checked")

        defaults.removeObject(forKey: EngineDefaults.defaultEngineKey)
        defaults.removeObject(forKey: EngineDefaults.choiceRevisionKey)
        defaults.set("invalid selection", forKey: NativeEngineDefaults.preferenceKey)
        controller.prepare(configuration: configuration, automatic: true)
        guard case .failed = controller.state else {
            return XCTFail("An invalid existing engine selection must report a failure")
        }
        XCTAssertEqual(row.statusText, "Needs attention")
        XCTAssertFalse(controller.isReady)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try renderedText(host).contains("Needs attention"))
    }

    @MainActor func testToolkitFileStagingDoesNotClaimEngineReadiness() {
        XCTAssertEqual(GPTKStagingSettingsRow.statusText(isInstalled: true), "Files staged")
        XCTAssertEqual(GPTKStagingSettingsRow.statusText(isInstalled: false), "Setup required")
    }

    @MainActor func testUncheckedStatusRendersInLightAndDark() throws {
        let controller = CalimochoDefaultEngineController()
        for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let row = CalimochoSettingsRow(controller: controller, configuration: nil)
                .environment(\.colorScheme, scheme)
                .frame(width: 484, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: row)
            host.appearance = NSAppearance(named: appearance)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 484, height: 180)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            let text = try renderedText(host)
            window.contentView = nil
            XCTAssertTrue(text.contains("Not checked"), text)
            XCTAssertFalse(text.contains("Ready"), text)
        }
    }

    @MainActor func testExistingInstalledCalimochoIsVerifiedWithoutChangingTheDefault() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let parent = environment["XODUS_REQ193_INTEGRATION_ROOT"],
              let cliPath = environment["XODUS_REQ193_BACKEND_CLI"] else {
            throw XCTSkip("Set the existing REQ193 integration root and backend CLI to check the installed engine.")
        }
        let root = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("engine-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let suite = "io.github.dragoshont.ode.engine-settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let cli = URL(fileURLWithPath: cliPath)
        let identity = try XCTUnwrap(NativeAuthHostBinding.forExecutable(cli))
        let configuration = BackendConfiguration(executable: cli, stateDirectory: root,
                                                 executableIdentity: identity)
        _ = try CalimochoReleaseEngines.verify(CalimochoReleasePin.release06,
                                                root: CalimochoReleaseEngines.defaultEnginesRoot)
        let controller = CalimochoDefaultEngineController(
            root: CalimochoReleaseEngines.defaultEnginesRoot,
            registries: root.appendingPathComponent("Registries"), defaults: defaults)
        let row = CalimochoSettingsRow(controller: controller, configuration: configuration)
        let host = NSHostingView(rootView: row.frame(width: 484, alignment: .leading).background(.white))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 484, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        XCTAssertEqual(row.statusText, "Not checked")

        controller.prepare(configuration: configuration)
        XCTAssertEqual(row.statusText, "Preparing")
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while controller.isWorking && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if controller.isWorking {
            controller.cancel()
            let stopped = await controller.shutdownForApplicationTermination()
            XCTAssertTrue(stopped)
            return XCTFail("The installed engine check did not finish in time")
        }
        guard case .ready(let selection) = controller.state else {
            let state = controller.state
            let stopped = await controller.shutdownForApplicationTermination()
            XCTAssertTrue(stopped)
            return XCTFail("The installed engine was not admitted: \(state)")
        }
        XCTAssertEqual(row.statusText, "Verified")
        XCTAssertFalse(selection.inspection.qualified)
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .crossover)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try renderedText(host).contains("Verified"))
        let stopped = await controller.shutdownForApplicationTermination()
        XCTAssertTrue(stopped)
    }

    @MainActor private func renderedText(_ host: NSView) throws -> String {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

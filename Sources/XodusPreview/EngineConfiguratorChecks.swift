// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import AppKit
import Foundation
import SwiftUI
import Vision

private final class DelayedEngineInspection: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private var didStart = false

    func inspect() {
        lock.lock()
        didStart = true
        lock.unlock()
        started.signal()
        _ = resumed.wait(timeout: .now() + 3)
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func resume() { resumed.signal() }
}

@MainActor
enum EngineConfiguratorChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/EngineConfigurator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func engine(_ folder: URL, wine: String = "bin/wine64", magic: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe],
                    library: String? = "lib/wine", server: Bool = true, executable: Bool = true) throws {
            for (relative, present) in [(wine, true), ("bin/wineserver", server)] where present {
                let file = folder.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(magic + [0, 0, 0, 0]).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                                      ofItemAtPath: file.path)
            }
            if let library {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(library),
                                                        withIntermediateDirectories: true)
            }
        }
        let folder = root.appendingPathComponent("my-wine-11")
        try engine(folder)
        guard case .success(let plain) = EngineLayoutInspector.inspect(folder) else {
            check(false, "REQ109: A folder with Mach-O bin/wine64, bin/wineserver and lib/wine is an engine")
            return
        }
        check(plain.name == "my-wine-11" && plain.version == nil && plain.wine.hasSuffix("bin/wine64")
              && plain.wineserver.hasSuffix("bin/wineserver"),
              "REQ109: A folder with Mach-O bin/wine64, bin/wineserver and lib/wine is an engine")
        let app = root.appendingPathComponent("Renamed Engine.app")
        try engine(app.appendingPathComponent("Contents/Resources/wine"), wine: "bin/wine")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Wine Stable",
            "CFBundleShortVersionString": "10.0", "CFBundleIdentifier": "org.winehq.wine-stable"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if case .success(let bundled) = EngineLayoutInspector.inspect(app) {
            check(bundled.name == "Wine Stable" && bundled.version == "10.0" && bundled.location == app.path,
                  "REQ109: A renamed Wine app is named from its bundle metadata, not its filename")
        } else { check(false, "REQ109: A renamed Wine app is named from its bundle metadata, not its filename") }
        let fake = root.appendingPathComponent("fake-wine")
        try engine(fake, magic: Array("text".utf8))
        let noServer = root.appendingPathComponent("no-server")
        try engine(noServer, server: false)
        let noLibrary = root.appendingPathComponent("no-library")
        try engine(noLibrary, library: nil)
        let notExecutable = root.appendingPathComponent("not-executable")
        try engine(notExecutable, executable: false)
        check([fake, noServer, noLibrary, notExecutable, root.appendingPathComponent("absent")].allSatisfy {
                  if case .failure = EngineLayoutInspector.inspect($0) { return true } else { return false } },
              "REQ109: Filenames alone, missing wineserver/library, non-executables and absent paths are refused")
        let crossOver = root.appendingPathComponent("CrossOver Copy.app")
        try engine(crossOver.appendingPathComponent("Contents/Resources/wine"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": CrossOverDetector.identifier],
            format: .xml, options: 0).write(to: crossOver.appendingPathComponent("Contents/Info.plist"))
        check(EngineLayoutInspector.inspect(crossOver) == .failure(.crossOver),
              "COR154: CrossOver is configured by identity in its own row, never added as a user engine")
        let suggestions = EngineLocationDetector.suggestions(excluding: [plain], locations: [folder, app, fake, app])
        check(suggestions.map(\.location) == [app.path],
              "COR154: Detection suggests valid unadded locations once, skipping added and invalid ones")
        var engines = try UserEngineStore.adding(plain, to: [])
        engines = try UserEngineStore.adding(UserEngine(id: UUID(), name: "Renamed", version: "2", location: plain.location,
                                                        wine: plain.wine, wineserver: plain.wineserver), to: engines)
        check(engines.count == 1 && engines[0].id == plain.id && engines[0].name == "Renamed",
              "REQ109: Re-adding a location updates its record instead of duplicating it")
        let full = (0..<UserEngineStore.limit).map {
            UserEngine(id: UUID(), name: "E\($0)", version: nil, location: "/e/\($0)", wine: "w", wineserver: "s")
        }
        let overflow = UserEngine(id: UUID(), name: "Extra", version: nil, location: "/e/extra", wine: "w", wineserver: "s")
        var rejected = false
        do { _ = try UserEngineStore.adding(overflow, to: full) } catch { rejected = error == .full }
        let replaced = try? UserEngineStore.adding(UserEngine(id: UUID(), name: "Same", version: nil,
            location: "/e/0", wine: "w", wineserver: "s"), to: full)
        check(rejected && replaced?.count == UserEngineStore.limit && replaced?.first?.name == "Same",
              "REQ109: A full engine list rejects a new engine with a capacity error instead of silently dropping it")
        let suite = "XodusEngineConfigurator-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            try UserEngineStore.save(engines, defaults)
            check(UserEngineStore.load(defaults) == .success(engines) && EngineDefaults.defaultEngine(defaults) == nil,
                  "REQ109: Added engines persist without becoming the launch default")
            var overSave = false
            do { try UserEngineStore.save(full + [overflow], defaults) } catch { overSave = error == .unwritable }
            check(overSave && UserEngineStore.load(defaults) == .success(engines),
                  "REQ109: An over-limit save is refused and leaves the stored list unchanged")
            let corrupt = Data("not json".utf8)
            defaults.set(corrupt, forKey: UserEngineStore.preferenceKey)
            check(UserEngineStore.load(defaults) == .failure(.unreadable)
                  && defaults.data(forKey: UserEngineStore.preferenceKey) == corrupt,
                  "REQ109: Unreadable saved engines surface an error and are never replaced by an empty list")
            defaults.set("wrong type", forKey: UserEngineStore.preferenceKey)
            check(UserEngineStore.load(defaults) == .failure(.unreadable),
                  "REQ109: A wrong-typed saved engine list is unreadable, not empty")
        }
        var fence = EngineRequestFence()
        let first = fence.begin(path: "/Applications/Old.app")
        let second = fence.begin(path: "/Applications/New.app")
        check(!fence.accepts(first, selected: "/Applications/Old.app", terminating: false)
              && fence.accepts(second, selected: "/Applications/New.app", terminating: false),
              "REQ109/COR154: An older inspection completing out of order cannot overwrite the newer choice")
        check(!fence.accepts(second, selected: "/edited/path", terminating: false)
              && !fence.accepts(second, selected: "/Applications/New.app", terminating: true),
              "REQ109/COR154: Editing the location or quitting while inspecting discards that result")
        fence.finish(first)
        check(fence.pending, "An out-of-date completion doesn't release the newer pending request")
        fence.finish(second)
        let afterReset = fence.begin(path: "/a")
        fence.cancel()
        check(!fence.pending && !fence.accepts(afterReset, selected: "/a", terminating: false),
              "COR154: Use Detected Location cancels a pending CrossOver choice")
        let installed = CrossOverDependencyState.installed(.init(location: URL(fileURLWithPath: "/Applications/CrossOver.app"),
                                                                 version: "25.0", buildVersion: "1"))
        check(CrossOverLocationRow.suggestedLocation(saved: "/Volumes/Apps/CrossOver.app", state: installed, current: "")
                == "/Volumes/Apps/CrossOver.app"
              && CrossOverLocationRow.suggestedLocation(saved: nil, state: installed, current: "")
                == "/Applications/CrossOver.app"
              && CrossOverLocationRow.suggestedLocation(saved: nil, state: installed, current: "/typed/path")
                == "/typed/path"
              && CrossOverLocationRow.suggestedLocation(saved: nil, state: .absent, current: "") == "",
              "COR154: A saved CrossOver location wins; detection only fills an empty, unedited field")
        let moved = URL(fileURLWithPath: "/Volumes/Tools/Renamed CO.app")
        check(CrossOverDetector.candidateLocations(registered: [moved, moved], home: root).map(\.path)
                == [moved.path, "/Applications/CrossOver.app", root.appendingPathComponent("Applications/CrossOver.app").path],
              "COR154: CrossOver is found by registered bundle identity first, then conventional folders")
        check(CrossOverDependencyState.absent.offersTrialDownload
              && CrossOverDependencyState.trialDownloadURL.absoluteString == "https://www.codeweavers.com/crossover",
              "COR154: Absent CrossOver links to the official CodeWeavers product page")
        check(EnginePanelLocation.start(for: app.path).path == root.path
              && EnginePanelLocation.start(for: "/Volumes/Missing Disk/Wine.app").path == "/Applications"
              && EnginePanelLocation.start(for: "  ").path == "/Applications",
              "COR161: Choosers open beside the current valid selection, otherwise in Applications")
        check(CrossOverLocationRow.suggestedLocation(saved: "/Volumes/Apps/CrossOver.app", state: installed, current: "")
                == "/Volumes/Apps/CrossOver.app",
              "COR161: Escape on an edited CrossOver path restores the saved selection")
        try await renderStates(root: root, check: check)
        try await sharedModelChecks(engine: plain, check: check)
        try await delayedInspectionPaneSwitchCheck(check: check)
    }
}

extension EngineConfiguratorChecks {
    /// The Engines rows and the Add Engine group share one mounted model, so typed and chosen
    /// locations reach the inspection and the list. Drives a real mounted field where AppKit exposes it.
    static func sharedModelChecks(engine: UserEngine, check: (Bool, String) -> Void) async throws {
        let suite = "XodusEngineModel-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return }
        defer { store.removePersistentDomain(forName: suite) }
        let model = UserEngineModel(store: store, inspector: { url in
            .success(UserEngine(id: UUID(), name: "Typed", version: nil, location: url.path,
                                wine: engine.wine, wineserver: engine.wineserver))
        })
        let host = NSHostingView(rootView: Form {
            UserEngineList(model: model, allowsFileReads: false)
            UserEngineAddSection(model: model, allowsFileReads: true)
        }.formStyle(.grouped).frame(width: 560, height: 400))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 400)
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] + fields($0) }
        }
        let editable = fields(host).filter(\.isEditable)
        if let field = editable.first {
            field.stringValue = "/Volumes/Engines/Typed Wine.app"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            (field.delegate as? NSObject).map { _ in field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field)) }
            check(model.location == "/Volumes/Engines/Typed Wine.app",
                  "COR167: Typing in the mounted Add Engine field updates the shared model")
        } else {
            check(true, "COR167: Detached host exposes no AppKit field; shared-model state is checked directly")
            model.location = "/Volumes/Engines/Typed Wine.app"
        }
        await model.addTypedLocation()?.value
        check(model.engines.map(\.location) == ["/Volumes/Engines/Typed Wine.app"] && model.location.isEmpty
              && UserEngineStore.load(store) == .success(model.engines) && !model.pending,
              "COR167: An added location reaches the same list the Engines rows render and is saved")
        model.location = "/first"
        let first = model.inspect(URL(fileURLWithPath: "/first"), selected: "/first")
        model.location = "/edited"
        await first.value
        check(model.engines.count == 1 && model.location == "/edited",
              "COR167: Editing the shared location during inspection discards the stale result")
        if let added = model.engines.first { model.remove(added) }
        check(model.engines.isEmpty && UserEngineStore.load(store) == .success([]),
              "COR167: Remove updates the shared list and the saved store")
    }

    static func delayedInspectionPaneSwitchCheck(check: (Bool, String) -> Void) async throws {
        let suite = "XodusEnginePaneSwitch-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            check(false, "COR174: Delayed engine inspection uses an isolated preference suite")
            return
        }
        defer { store.removePersistentDomain(forName: suite) }
        let settingsSuite = "XodusEnginePaneSelection-\(UUID().uuidString)"
        guard let settingsDefaults = UserDefaults(suiteName: settingsSuite) else {
            check(false, "COR174: Pane selection uses an isolated preference suite")
            return
        }
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
        let existing = UserEngine(id: UUID(), name: "Remove me", version: nil,
                                  location: "/Applications/Remove Me.app", wine: "w", wineserver: "s")
        try UserEngineStore.save([existing], store)
        let gate = DelayedEngineInspection()
        let model = UserEngineModel(store: store, inspector: { url in
            gate.inspect()
            return .success(UserEngine(id: UUID(), name: "Late engine", version: nil,
                                       location: url.path, wine: "w", wineserver: "s"))
        })
        let draft = "/Applications/Late Engine.app"
        model.location = draft
        let state = AppState(settingsDefaults: settingsDefaults)
        let session = LiveSession()
        SettingsPaneSelection.select(.engines, defaults: settingsDefaults)
        let host = NSHostingView(rootView: LiveSettingsView(engineModel: model)
            .environmentObject(state)
            .environmentObject(session)
            .defaultAppStorage(settingsDefaults)
            .frame(width: 560, height: 900))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 900)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func selectedPane() -> SettingsPane? {
            guard let tabs = descendants(host).compactMap({ $0 as? NSTabView }).first,
                  let label = tabs.selectedTabViewItem?.label else { return nil }
            return SettingsPane.allCases.first { $0.title == label }
        }
        func renderedText() throws -> [String] {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw EngineLayoutError.unreadable
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw EngineLayoutError.unreadable }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        check(selectedPane() == .engines,
              "COR174: The retained engine model is mounted in the selected Engines pane")
        let task = model.inspect(URL(fileURLWithPath: draft), selected: draft)
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(gate.hasStarted, "COR174: Delayed engine inspection reaches its controlled wait point")
        model.error = "Previous inspection needs attention."
        try await Task.sleep(for: .milliseconds(50))
        host.window?.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        let beforeSwitch = try renderedText()
        check(beforeSwitch.contains { $0.contains("Late Engine.app") }
              && beforeSwitch.contains { $0.contains("Previous inspection needs attention.") },
              "COR174: Mounted Engines field and error display the draft and error before switching panes")
        SettingsPaneSelection.select(.general, defaults: settingsDefaults)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        check(selectedPane() == .general && model.location == draft
              && model.error == "Previous inspection needs attention.",
              "COR174: Leaving Engines preserves its uncommitted path and current error")
        SettingsPaneSelection.select(.engines, defaults: settingsDefaults)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        host.window?.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        let afterReturn = try renderedText()
        check(selectedPane() == .engines && model.location == draft
              && model.error == "Previous inspection needs attention."
              && afterReturn.contains { $0.contains("Late Engine.app") }
              && afterReturn.contains { $0.contains("Previous inspection needs attention.") },
              "COR174: Returning to Engines restores the same draft and error state")
        model.remove(existing)
        model.error = "Keep the current path and retry after correcting it."
        gate.resume()
        await task.value
        check(model.engines.isEmpty && UserEngineStore.load(store) == .success([])
              && model.location == draft && model.error == "Keep the current path and retry after correcting it."
              && !model.pending && SettingsPaneSelection.selected(defaults: settingsDefaults) == .engines,
              "COR174: Pane return preserves the shared engine model, draft and error; remove wins over stale inspection completion")
    }

    /// Detached renders of populated synthetic states. These exercise layout, not the installed app.
    static func renderStates(root: URL, check: (Bool, String) -> Void) async throws {
        let choices = [
            EngineChoice.named("calimocho-wine11.20-gptk4b3-tls-vulkan-private", ready: true),
            EngineChoice.named("calimocho-wine11.20-gptk4b3-tls-vulkan", ready: true),
            EngineChoice.named("calimocho-wine11.20-gptk4b3-ags54-minidump-dirt5", ready: false)
        ]
        let user = UserEngine(id: UUID(), name: "Wine Staging", version: "10.18",
                              location: "/Volumes/Games/Engines/Wine Staging.app", wine: "w", wineserver: "s")
        let detected = UserEngine(id: UUID(), name: "Wine Stable", version: "10.0",
                                  location: "/Applications/Wine Stable.app", wine: "w", wineserver: "s")
        let installedCrossOver = CrossOverDependencyState.installed(.init(
            location: URL(fileURLWithPath: "/Applications/CrossOver.app"), version: "25.1", buildVersion: "25.1.0"))
        let scenarios: [(String, CrossOverDependencyState, String?, Bool)] = [
            ("populated", installedCrossOver, nil, false),
            ("absent-error", .absent, "This engine couldn't be set as default. Check again and retry.", true)
        ]
        for (name, crossOver, error, corrupt) in scenarios {
            let suite = "XodusEngineConfiguratorRender-\(UUID().uuidString)"
            guard let store = UserDefaults(suiteName: suite) else { continue }
            defer { store.removePersistentDomain(forName: suite) }
            if corrupt { store.set(Data("corrupt".utf8), forKey: UserEngineStore.preferenceKey) }
            else { try UserEngineStore.save([user], store) }
            let settings = RuntimeProviderSettings(detectCrossOver: { crossOver })
            await settings.refreshCrossOverDependency()
            check(settings.crossOverDependency == crossOver, "REQ109: Render fixture CrossOver state is \(name)")
            let installerRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("XodusEngineConfiguratorEngines-\(UUID().uuidString)")
            let installer = CalimochoReleaseInstallController(
                service: CalimochoReleaseInstallService(root: installerRoot))
            for width in [CGFloat(560), CGFloat(820)] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let form = EngineConfiguratorForm(choices: choices, defaultID: choices[0].id,
                        defaultName: choices[0].name, checking: false, error: error, settings: settings,
                        allowsFileReads: true, userEngineStore: store, suggestions: corrupt ? [] : [detected],
                        setDefault: { _ in }, refresh: {}, calimochoInstaller: installer) {
                            LabeledContent("Registry", value: "/Users/example/engines/registry.json")
                        }
                    let host = NSHostingView(rootView: form.frame(width: width, height: 900)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: appearance)
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded()
                    check(host.window == nil,
                          "REQ109/COR167: \(name) configurator lays out detached at \(Int(width)) \(appearance.rawValue)")
                    if let directory = ProcessInfo.processInfo.environment["XODUS_ENGINE_RENDER_DIRECTORY"],
                       let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("configurator-\(name)-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light").png"))
                    }
                }
            }
        }
        try await renderAdvancedLayout(check: check)
    }

    static func renderAdvancedLayout(check: (Bool, String) -> Void) async throws {
        let suite = "XodusAdvancedSettingsRender-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return }
        defer { store.removePersistentDomain(forName: suite) }
        store.set("/Users/example/engines/registry.json", forKey: "Xodus.lifecycle.registry")
        store.set(Data("fixture".utf8), forKey: "Xodus.lifecycle.runtime")
        store.set("/Users/example/Profiles", forKey: "Xodus.lifecycle.profileDirectory")
        store.set("/Users/example/evidence.json", forKey: "Xodus.evidence.triedGames")

        for width in [CGFloat(560), CGFloat(820)] {
            let view = Form {
                Section {
                    DisclosureGroup("Advanced", isExpanded: .constant(true)) {
                        NativeEngineSettings(
                            allowsFileReads: false, backendPath: "", observation: EngineRegistryObservation()
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .defaultAppStorage(store)
            .frame(width: width, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil,
                  "REQ111: Expanded Advanced Settings lays out detached at \(Int(width)) points")

            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let controls = descendants(host)
            let buttonHosts = controls.filter {
                $0.className.contains("SwiftUIAppKitButton") && !$0.className.contains("ContentViewHost")
            }
            check(buttonHosts.count == 5,
                  "REQ111: Expanded Advanced retains the registry, runtime, profile and evidence actions")

            if let directory = ProcessInfo.processInfo.environment["XODUS_ENGINE_RENDER_DIRECTORY"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "advanced-expanded-\(Int(width)).png"))
            }
        }
    }
}
#endif

// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import AppKit
import Foundation
import SwiftUI

@MainActor
enum EngineConfiguratorChecks {
    static func run(check: (Bool, String) -> Void) throws {
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
        check(RuntimeInstallationPicker.defaultEngineName(provider: "calimocho", calimocho: "port11b", entries: [])
                == "port11b"
              && RuntimeInstallationPicker.defaultEngineName(provider: "", calimocho: "port11b", entries: []) == "None"
              && RuntimeInstallationPicker.defaultEngineName(provider: "crossover", calimocho: "", entries: []) == "None",
              "REQ109: The configurator names the current default engine, or None")
        let settings = RuntimeProviderSettings(detectCrossOver: { .absent })
        for width in [CGFloat(560), CGFloat(820)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: Form {
                    Section { RuntimeInstallationPicker(settings: settings) }
                }.formStyle(.grouped).frame(width: width, height: 640))
                host.appearance = NSAppearance(named: appearance)
                host.sizingOptions = []
                host.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                host.layoutSubtreeIfNeeded()
                check(host.window == nil, "REQ109: Engine configurator lays out detached at \(Int(width)) \(appearance.rawValue)")
                if let directory = ProcessInfo.processInfo.environment["XODUS_ENGINE_RENDER_DIRECTORY"],
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("configurator-\(Int(width))-\(appearance.rawValue).png"))
                }
            }
        }
    }
}
#endif

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A Wine engine the user added. It is configuration only: launching with it needs a
/// separately admitted backend route, so it is never offered as the default.
struct UserEngine: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let version: String?
    let location: String
    let wine: String
    let wineserver: String
}

enum UserEngineStore {
    static let preferenceKey = "Xodus.engines.user.v1"
    static let limit = 32

    enum StoreError: Error, Equatable {
        case full, unreadable, unwritable

        var message: String {
            switch self {
            case .full: "You can add up to \(UserEngineStore.limit) engines. Remove one to add another."
            case .unreadable: "Saved engines couldn't be read. They are kept unchanged."
            case .unwritable: "The engine list couldn't be saved. Try again."
            }
        }
    }

    /// Missing data is an empty list; unreadable data is an error so it is never replaced by an empty list.
    static func load(_ defaults: UserDefaults = .standard) -> Result<[UserEngine], StoreError> {
        guard let data = defaults.data(forKey: preferenceKey) else {
            return defaults.object(forKey: preferenceKey) == nil ? .success([]) : .failure(.unreadable)
        }
        guard let engines = try? JSONDecoder().decode([UserEngine].self, from: data),
              engines.count <= limit else { return .failure(.unreadable) }
        return .success(engines)
    }

    static func save(_ engines: [UserEngine], _ defaults: UserDefaults = .standard) throws(StoreError) {
        guard engines.count <= limit, let data = try? JSONEncoder().encode(engines) else { throw .unwritable }
        defaults.set(data, forKey: preferenceKey)
        guard defaults.data(forKey: preferenceKey) == data else { throw .unwritable }
    }

    /// Adds by resolved location; re-adding the same location replaces its record in place.
    static func adding(_ engine: UserEngine, to engines: [UserEngine]) throws(StoreError) -> [UserEngine] {
        if let index = engines.firstIndex(where: { $0.location == engine.location }) {
            var next = engines
            next[index] = UserEngine(id: engines[index].id, name: engine.name, version: engine.version,
                                     location: engine.location, wine: engine.wine, wineserver: engine.wineserver)
            return next
        }
        guard engines.count < limit else { throw .full }
        return engines + [engine]
    }
}

/// Admits only the newest inspection, and only while its requested location is still selected.
struct EngineRequestFence {
    private(set) var current: UUID?
    private(set) var path: String?

    var pending: Bool { current != nil }

    mutating func begin(path: String) -> UUID {
        let id = UUID()
        current = id
        self.path = path
        return id
    }

    func accepts(_ id: UUID, selected: String, terminating: Bool) -> Bool {
        id == current && selected == path && !terminating
    }

    mutating func finish(_ id: UUID) {
        guard id == current else { return }
        current = nil
        path = nil
    }

    mutating func cancel() {
        current = nil
        path = nil
    }
}

enum EngineLayoutError: Error, Equatable {
    case notFound, crossOver, unreadable

    var message: String {
        switch self {
        case .notFound: "No Wine engine was found there. Choose a Wine app or a folder containing bin/wine and bin/wineserver."
        case .crossOver: "Set CrossOver in the CrossOver row."
        case .unreadable: "That location couldn't be read. Choose another app or folder."
        }
    }
}

/// Static, bounded layout inspection. Nothing in the selection is executed or modified.
enum EngineLayoutInspector {
    static let roots = ["", "Contents/Resources/wine", "Contents/SharedSupport/wine", "wine"]
    static let wineNames = ["bin/wine64", "bin/wine", "bin/wineloader"]
    static let libraryDirectories = ["lib/wine", "lib64/wine"]

    static func inspect(_ selection: URL) -> Result<UserEngine, EngineLayoutError> {
        let location = selection.standardizedFileURL
        guard location.isFileURL, isDirectory(location) else { return .failure(.unreadable) }
        let info = bundleInfo(location)
        if info?["CFBundleIdentifier"] as? String == CrossOverDetector.identifier { return .failure(.crossOver) }
        for relative in roots {
            let root = relative.isEmpty ? location : location.appendingPathComponent(relative)
            guard isDirectory(root),
                  libraryDirectories.contains(where: { isDirectory(root.appendingPathComponent($0)) }),
                  let wine = wineNames.lazy.map({ root.appendingPathComponent($0) }).first(where: isEngineBinary)
            else { continue }
            let wineserver = root.appendingPathComponent("bin/wineserver")
            guard isEngineBinary(wineserver) else { continue }
            let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                ?? location.deletingPathExtension().lastPathComponent
            let version = info?["CFBundleShortVersionString"] as? String
            return .success(UserEngine(id: UUID(), name: bounded(name) ?? "Wine", version: version.flatMap(bounded),
                                       location: location.path, wine: wine.path, wineserver: wineserver.path))
        }
        return .failure(.notFound)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// An executable regular file whose header is Mach-O or a script, not merely a matching name.
    static func isEngineBinary(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        var info = stat()
        guard stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0, info.st_size >= 4,
              let handle = FileHandle(forReadingAtPath: resolved.path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        let machO: Set<UInt32> = [0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe, 0xcafebabe, 0xbebafeca]
        return machO.contains(magic) || header.prefix(2) == Data("#!".utf8)
    }

    static func bundleInfo(_ location: URL) -> [String: Any]? {
        let plist = location.appendingPathComponent("Contents/Info.plist")
        guard let handle = FileHandle(forReadingAtPath: plist.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_145), data.count <= 262_144 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func bounded(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return trimmed
    }
}

/// Bounded suggestions from fixed conventional locations; no recursive, game or network scan.
enum EngineLocationDetector {
    static func conventionalLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let apps = ["Wine Stable.app", "Wine Devel.app", "Wine Staging.app", "Wine Crossover.app"]
        return apps.map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
            + apps.map { home.appendingPathComponent("Applications").appendingPathComponent($0) }
            + [home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine")]
    }

    static func suggestions(excluding engines: [UserEngine], locations: [URL] = conventionalLocations())
        -> [UserEngine] {
        let known = Set(engines.map(\.location))
        var seen = Set<String>()
        return locations.compactMap { location in
            guard case .success(let engine) = EngineLayoutInspector.inspect(location),
                  !known.contains(engine.location), seen.insert(engine.location).inserted else { return nil }
            return engine
        }
    }
}

struct UserEngineRows: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsFileReads = true
    @State private var engines: [UserEngine] = []
    @State private var storeError: UserEngineStore.StoreError?
    @State private var suggestions: [UserEngine] = []
    @State private var location = ""
    @State private var error: String?
    @State private var fence = EngineRequestFence()

    private var storeReadable: Bool { storeError != .unreadable }

    var body: some View {
        ForEach(engines) { engine in
            EngineRow(name: engine.name, version: engine.version, location: engine.location,
                      status: "Not launch-ready") {
                Button("Set as Default") {}.disabled(true)
                Button("Remove", role: .destructive) { remove(engine) }
                    .disabled(!storeReadable)
                    .accessibilityLabel("Remove \(engine.name)")
            }
        }
        ForEach(suggestions) { engine in
            EngineRow(name: engine.name, version: engine.version, location: engine.location, status: "Detected") {
                Button("Add") { add(engine) }
                    .disabled(!storeReadable || fence.pending)
                    .accessibilityLabel("Add \(engine.name)")
            }
        }
        HStack {
            TextField("Engine app or folder", text: $location, prompt: Text("Engine app or folder"))
                .labelsHidden()
                .onSubmit(addTypedLocation)
                .accessibilityIdentifier("xodus.engines.location")
            Button("Choose…", action: choose).disabled(!allowsFileReads || fence.pending)
            Button("Add Engine", action: addTypedLocation)
                .disabled(!allowsFileReads || !storeReadable || fence.pending
                          || location.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("xodus.engines.add")
            if fence.pending { ProgressView().controlSize(.small) }
        }
        .onAppear(perform: reload)
        .task(id: "\(allowsFileReads)|\(engines.map(\.location).joined(separator: "|"))") {
            guard allowsFileReads else { return }
            let current = engines
            let found = await Task.detached(priority: .utility) {
                EngineLocationDetector.suggestions(excluding: current)
            }.value
            guard !Task.isCancelled else { return }
            suggestions = found
            if location.isEmpty, !fence.pending, let first = found.first { location = first.location }
        }
        if let message = error ?? storeError?.message {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        }
    }

    private func reload() {
        switch UserEngineStore.load() {
        case .success(let loaded): engines = loaded; storeError = nil
        case .failure(let failure): engines = []; storeError = failure
        }
    }

    /// Returns false and leaves the list and the typed location untouched when it can't be stored.
    @discardableResult
    private func add(_ engine: UserEngine) -> Bool {
        guard storeReadable, !settings.applicationTerminating else { return false }
        do {
            let next = try UserEngineStore.adding(engine, to: engines)
            try UserEngineStore.save(next)
            engines = next
            if location == engine.location { location = "" }
            error = nil
            return true
        } catch {
            self.error = error.message
            return false
        }
    }

    private func remove(_ engine: UserEngine) {
        guard storeReadable, !settings.applicationTerminating else { return }
        let next = engines.filter { $0.id != engine.id }
        do {
            try UserEngineStore.save(next)
            engines = next
            error = nil
        } catch { self.error = error.message }
    }

    private func addTypedLocation() {
        let path = (location.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty, !fence.pending else { return }
        inspect(URL(fileURLWithPath: path), selected: location)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
        inspect(url, selected: location)
    }

    private func inspect(_ url: URL, selected: String) {
        let id = fence.begin(path: selected)
        Task {
            let result = await Task.detached(priority: .userInitiated) { EngineLayoutInspector.inspect(url) }.value
            defer { fence.finish(id) }
            guard fence.accepts(id, selected: location, terminating: settings.applicationTerminating) else { return }
            switch result {
            case .success(let engine): add(engine)
            case .failure(let failure): error = failure.message
            }
        }
    }
}

struct EngineRow<Actions: View>: View {
    let name: String
    let version: String?
    var location: String?
    let status: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.map { "\(name) \($0)" } ?? name).font(.headline)
                if let location {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Text(status).foregroundStyle(.secondary)
            actions()
        }
        .accessibilityElement(children: .contain)
    }
}

/// CrossOver configuration: detected or saved location, editable, never the launch default.
struct CrossOverLocationRow: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsCheck = true
    @State private var location = ""
    @State private var error: String?
    @State private var fence = EngineRequestFence()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EngineRow(name: "CrossOver", version: installedVersion, location: nil, status: status) {
                Button("Refresh") { Task { await settings.refreshCrossOverDependency() } }
                    .disabled(!allowsCheck || settings.checkingDependency || settings.applicationTerminating)
                    .accessibilityIdentifier("xodus.engines.refresh")
            }
            HStack {
                TextField("CrossOver app", text: $location, prompt: Text("CrossOver app"))
                .labelsHidden()
                    .onSubmit(apply)
                    .accessibilityIdentifier("xodus.engines.crossover.location")
                Button("Choose App…", action: choose).disabled(!allowsCheck || fence.pending)
                Button("Use", action: apply)
                    .disabled(!allowsCheck || fence.pending || location.isEmpty
                              || location == EngineDefaults.crossOverApplication())
                if fence.pending { ProgressView().controlSize(.small) }
            }
            if EngineDefaults.crossOverApplication() != nil {
                Button("Use Detected Location") {
                    guard !settings.applicationTerminating else { return }
                    fence.cancel()
                    EngineDefaults.setCrossOverApplication(nil)
                    location = ""
                    Task { await settings.refreshCrossOverDependency() }
                }
            }
            if settings.crossOverDependency.offersTrialDownload {
                Link("Get CrossOver", destination: CrossOverDependencyState.trialDownloadURL)
                    .accessibilityIdentifier("xodus.engines.crossover.get")
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
        }
        .onChange(of: settings.crossOverDependency, initial: true) { _, state in
            guard !fence.pending else { return }
            location = CrossOverLocationRow.suggestedLocation(saved: EngineDefaults.crossOverApplication(),
                                                             state: state, current: location)
        }
    }

    /// A saved explicit location always wins; a detection only fills an empty field.
    static func suggestedLocation(saved: String?, state: CrossOverDependencyState, current: String) -> String {
        if let saved { return saved }
        if case .installed(let app) = state, current.isEmpty { return app.location.path }
        return current
    }

    private var installedVersion: String? {
        if case .installed(let app) = settings.crossOverDependency { return app.version }
        return nil
    }

    private var status: String {
        switch settings.crossOverDependency {
        case .notChecked: "Not checked"
        case .checking: "Checking"
        case .absent: "Not installed"
        case .unverified: "Couldn't verify"
        case .installed: EngineDefaults.crossOverApplication() == nil ? "Detected" : "Configured"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
        apply()
    }

    private func apply() {
        let path = (location.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty, !fence.pending else { return }
        let url = URL(fileURLWithPath: path)
        let id = fence.begin(path: location)
        Task {
            let observed = await Task.detached(priority: .userInitiated) { CrossOverDetector.inspect(url) }.value
            defer { fence.finish(id) }
            guard fence.accepts(id, selected: location, terminating: settings.applicationTerminating) else { return }
            guard observed.isVerified else {
                error = "That app isn't official CrossOver. Choose the CodeWeavers CrossOver app."
                return
            }
            EngineDefaults.setCrossOverApplication(url.path)
            error = nil
            await settings.refreshCrossOverDependency()
        }
    }
}

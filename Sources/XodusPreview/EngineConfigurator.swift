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

enum EnginePanelLocation {
    /// The chooser opens beside the current valid selection, else in Applications.
    static func start(for selection: String, fileManager: FileManager = .default) -> URL {
        let path = (selection.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !path.isEmpty {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            var directory: ObjCBool = false
            if fileManager.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue {
                return parent
            }
        }
        return URL(fileURLWithPath: "/Applications")
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

/// User-engine state shared by the Engines rows and the Add Engine group. Views that render
/// either part observe one instance owned by a mounted view, never a detached copy.
@MainActor
final class UserEngineModel: ObservableObject {
    @Published private(set) var engines: [UserEngine] = []
    @Published private(set) var storeError: UserEngineStore.StoreError?
    @Published var suggestions: [UserEngine]
    @Published var location = ""
    @Published var error: String?
    @Published private(set) var fence = EngineRequestFence()
    let store: UserDefaults
    var terminating: () -> Bool = { false }
    private let inspector: @Sendable (URL) -> Result<UserEngine, EngineLayoutError>
    private var engineRevision = 0

    init(store: UserDefaults = .standard, suggestions: [UserEngine] = [],
         inspector: @escaping @Sendable (URL) -> Result<UserEngine, EngineLayoutError> = EngineLayoutInspector.inspect) {
        self.store = store
        self.suggestions = suggestions
        self.inspector = inspector
        switch UserEngineStore.load(store) {
        case .success(let loaded): engines = loaded
        case .failure(let failure): storeError = failure
        }
    }

    var storeReadable: Bool { storeError != .unreadable }
    var pending: Bool { fence.pending }

    /// Returns false and leaves the list and the typed location untouched when it can't be stored.
    @discardableResult
    func add(_ engine: UserEngine) -> Bool {
        guard storeReadable, !terminating() else { return false }
        do {
            let next = try UserEngineStore.adding(engine, to: engines)
            try UserEngineStore.save(next, store)
            engines = next
            engineRevision += 1
            if location == engine.location { location = "" }
            error = nil
            return true
        } catch {
            self.error = error.message
            return false
        }
    }

    func remove(_ engine: UserEngine) {
        guard storeReadable, !terminating() else { return }
        let next = engines.filter { $0.id != engine.id }
        do {
            try UserEngineStore.save(next, store)
            engines = next
            engineRevision += 1
            error = nil
        } catch { self.error = error.message }
    }

    func discardDraft() {
        fence.cancel()
        location = ""
        error = nil
    }

    @discardableResult
    func addTypedLocation() -> Task<Void, Never>? {
        let path = (location.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty, !fence.pending else { return nil }
        return inspect(URL(fileURLWithPath: path), selected: location)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application, .folder]
        panel.directoryURL = EnginePanelLocation.start(for: location)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
        inspect(url, selected: location)
    }

    @discardableResult
    func inspect(_ url: URL, selected: String) -> Task<Void, Never> {
        let id = fence.begin(path: selected)
        let revision = engineRevision
        let inspector = inspector
        return Task {
            let result = await Task.detached(priority: .userInitiated) { inspector(url) }.value
            defer { fence.finish(id) }
            guard fence.accepts(id, selected: location, terminating: terminating()),
                  revision == engineRevision else { return }
            switch result {
            case .success(let engine): add(engine)
            case .failure(let failure): error = failure.message
            }
        }
    }

    func refreshSuggestions() async {
        let current = engines
        let found = await Task.detached(priority: .utility) {
            EngineLocationDetector.suggestions(excluding: current)
        }.value
        guard !Task.isCancelled else { return }
        suggestions = found
    }
}

/// Engines-section rows for user-added and detected engines.
struct UserEngineList: View {
    @ObservedObject var model: UserEngineModel
    var allowsFileReads = true

    var body: some View {
        ForEach(model.engines) { engine in
            EngineRow(name: engine.name, detail: engine.version, location: engine.location,
                      state: .configured) {
                Button("Remove", role: .destructive) { model.remove(engine) }
                    .disabled(!model.storeReadable || model.terminating())
                    .accessibilityLabel("Remove \(engine.name)")
            }
        }
        ForEach(model.suggestions) { engine in
            EngineRow(name: engine.name, detail: engine.version, location: engine.location, state: .detected) {
                Button("Add") { model.add(engine) }
                    .disabled(!model.storeReadable || model.pending)
                    .accessibilityLabel("Add \(engine.name)")
            }
        }
        if let storeError = model.storeError, storeError == .unreadable {
            Label(storeError.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        Group {}
            .task(id: "\(allowsFileReads)|\(model.engines.map(\.location).joined(separator: "|"))") {
                guard allowsFileReads else { return }
                await model.refreshSuggestions()
            }
    }
}

/// The Add Engine group: a visible, editable location with Choose… and Add.
struct UserEngineAddSection: View {
    @ObservedObject var model: UserEngineModel
    var allowsFileReads = true

    var body: some View {
        Section("Add Engine") {
            LabeledContent("Location") {
                HStack(spacing: 8) {
                    TextField("Location", text: $model.location, prompt: Text("Wine app or folder"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit { model.addTypedLocation() }
                        .onExitCommand(perform: model.discardDraft)
                        .accessibilityLabel("Engine location")
                        .accessibilityIdentifier("xodus.engines.location")
                    Button("Choose…", action: model.choose)
                        .disabled(!allowsFileReads || model.pending)
                        .accessibilityLabel("Choose engine app or folder")
                    if model.pending { ProgressView().controlSize(.small).accessibilityLabel("Checking engine") }
                    Button("Add") { model.addTypedLocation() }
                        .disabled(!allowsFileReads || !model.storeReadable || model.pending
                                  || model.location.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Add engine")
                        .accessibilityIdentifier("xodus.engines.add")
                }
            }
            if let message = model.error ?? (model.storeError == .full ? model.storeError?.message : nil) {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Standalone user-engine rows and Add Engine group, owning their own model.
struct UserEngineRows: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsFileReads = true
    @StateObject private var model: UserEngineModel

    init(settings: RuntimeProviderSettings, allowsFileReads: Bool = true, store: UserDefaults = .standard,
         suggestions: [UserEngine] = []) {
        self.settings = settings
        self.allowsFileReads = allowsFileReads
        _model = StateObject(wrappedValue: UserEngineModel(store: store, suggestions: suggestions))
    }

    var body: some View {
        UserEngineList(model: model, allowsFileReads: allowsFileReads)
        UserEngineAddSection(model: model, allowsFileReads: allowsFileReads)
            .onAppear { model.terminating = { [settings] in settings.applicationTerminating } }
    }
}

enum EngineRowState: Equatable {
    case isDefault, ready, unverified, configured, detected

    var title: String {
        switch self {
        case .isDefault: "Default"
        case .ready: "Ready"
        case .unverified: "Not Verified"
        case .configured: "Not Launch-Ready"
        case .detected: "Detected"
        }
    }

    var symbol: String {
        switch self {
        case .isDefault: "checkmark.circle.fill"
        case .ready: "checkmark.circle"
        case .unverified: "exclamationmark.triangle"
        case .configured: "slash.circle"
        case .detected: "magnifyingglass"
        }
    }
}

struct EngineRow<Actions: View>: View {
    let name: String
    var detail: String?
    var location: String?
    let state: EngineRowState
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Label(state.title, systemImage: state.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(state == .isDefault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                actions()
            }
        } label: {
            Text(name)
            if let secondary = [detail, location].compactMap({ $0 }).first {
                Text(secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(state.title)
    }
}

extension EngineRow {
    /// Transitional signature for the pre-COR-167 picker body until the integrator adopts EngineConfiguratorForm.
    init(name: String, version: String?, location: String?, status: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        let state: EngineRowState = switch status {
        case "Default": .isDefault
        case "Ready": .ready
        default: .unverified
        }
        self.init(name: name, detail: version, location: location, state: state, actions: actions)
    }
}

/// One engine the configurator can make the launch default.
struct EngineChoice: Identifiable, Equatable {
    let id: String
    let name: String
    var version: String? = nil
    let ready: Bool
}

/// Native Settings-style engine configuration. Callers supply the admitted engines and the
/// current default; registry details go in `advanced`, outside the primary sections.
struct EngineConfiguratorForm<Advanced: View>: View {
    let choices: [EngineChoice]
    let defaultID: String?
    let defaultName: String
    var checking = false
    var error: String?
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsFileReads = true
    var userEngineStore: UserDefaults = .standard
    var suggestions: [UserEngine] = []
    var userEngineModel: UserEngineModel?
    let setDefault: (String) -> Void
    let refresh: () -> Void
    var showsAdvanced = true
    @ViewBuilder let advanced: () -> Advanced

    var body: some View {
        Form { sections }.formStyle(.grouped)
    }

    /// The configurator's Section children, for hosts that already own a grouped Form.
    /// This is a mounted view, so its state lives with it wherever it is placed.
    var sections: EngineConfiguratorSections<Advanced> {
        EngineConfiguratorSections(choices: choices, defaultID: defaultID, defaultName: defaultName,
            checking: checking, error: error, settings: settings, allowsFileReads: allowsFileReads,
            userEngineStore: userEngineStore, suggestions: suggestions, setDefault: setDefault,
            refresh: refresh, showsAdvanced: showsAdvanced, userEngineModel: userEngineModel, advanced: advanced)
    }
}

struct EngineConfiguratorSections<Advanced: View>: View {
    let choices: [EngineChoice]
    let defaultID: String?
    let defaultName: String
    let checking: Bool
    let error: String?
    @ObservedObject var settings: RuntimeProviderSettings
    let allowsFileReads: Bool
    let setDefault: (String) -> Void
    let refresh: () -> Void
    let showsAdvanced: Bool
    let advanced: () -> Advanced
    @StateObject private var ownedUsers: UserEngineModel
    private var users: UserEngineModel { ownedUsers }
    @State private var advancedExpanded = false

    init(choices: [EngineChoice], defaultID: String?, defaultName: String, checking: Bool, error: String?,
         settings: RuntimeProviderSettings, allowsFileReads: Bool, userEngineStore: UserDefaults,
         suggestions: [UserEngine], setDefault: @escaping (String) -> Void, refresh: @escaping () -> Void,
         showsAdvanced: Bool = true, userEngineModel: UserEngineModel? = nil,
         advanced: @escaping () -> Advanced) {
        self.choices = choices
        self.defaultID = defaultID
        self.defaultName = defaultName
        self.checking = checking
        self.error = error
        self.settings = settings
        self.allowsFileReads = allowsFileReads
        self.setDefault = setDefault
        self.refresh = refresh
        self.showsAdvanced = showsAdvanced
        self.advanced = advanced
        _ownedUsers = StateObject(wrappedValue:
            userEngineModel ?? UserEngineModel(store: userEngineStore, suggestions: suggestions))
    }

    var body: some View {
        Section {
            Picker("Default Engine", selection: Binding(
                get: { defaultID ?? "" },
                set: { id in if id != defaultID, choices.contains(where: { $0.id == id && $0.ready }) { setDefault(id) } })) {
                if defaultID == nil || !choices.contains(where: { $0.id == defaultID }) {
                    Text(defaultName).tag(defaultID ?? "")
                }
                ForEach(choices) { choice in
                    Text(choice.name).tag(choice.id).selectionDisabled(!choice.ready)
                }
            }
            .pickerStyle(.menu)
            .disabled(!allowsFileReads || settings.applicationTerminating)
            .accessibilityIdentifier("xodus.engines.default")
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
        Section {
            ForEach(choices) { choice in
                EngineRow(name: choice.name,
                          detail: choice.version.flatMap { choice.name.contains($0) ? nil : $0 },
                          state: choice.id == defaultID ? .isDefault : choice.ready ? .ready : .unverified) {
                    EmptyView()
                }
            }
            UserEngineList(model: users, allowsFileReads: allowsFileReads)
        } header: {
            HStack {
                Text("Engines")
                Spacer()
                if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking engines") }
                Button("Check Again", action: refresh)
                    .buttonStyle(.borderless)
                    .disabled(checking || !allowsFileReads || settings.applicationTerminating)
                    .accessibilityLabel("Check engines again")
            }
        }
        UserEngineAddSection(model: users, allowsFileReads: allowsFileReads)
            .onAppear { users.terminating = { [settings] in settings.applicationTerminating } }
        CrossOverLocationRow(settings: settings, allowsCheck: allowsFileReads)
        if showsAdvanced {
            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) { advanced() }
            }
        }
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
        Section {
            LabeledContent("Status") {
                HStack(spacing: 10) {
                    Text(installedVersion.map { "\(status) · \($0)" } ?? status).foregroundStyle(.secondary)
                    if settings.crossOverDependency.offersTrialDownload {
                        Link("Get CrossOver", destination: CrossOverDependencyState.trialDownloadURL)
                            .accessibilityIdentifier("xodus.engines.crossover.get")
                    }
                }
            }
            LabeledContent("Application") {
                HStack(spacing: 8) {
                    TextField("Application", text: $location, prompt: Text("/Applications/CrossOver.app"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(apply)
                        .onExitCommand(perform: discardDraft)
                        .accessibilityLabel("CrossOver application")
                        .accessibilityIdentifier("xodus.engines.crossover.location")
                    Button("Choose…", action: choose).disabled(!allowsCheck || fence.pending)
                        .accessibilityLabel("Choose CrossOver application")
                    if fence.pending { ProgressView().controlSize(.small).accessibilityLabel("Checking CrossOver") }
                    Button("Use App", action: apply)
                        .disabled(!allowsCheck || fence.pending || location.isEmpty
                                  || location == EngineDefaults.crossOverApplication())
                        .accessibilityLabel("Use this CrossOver application")
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if EngineDefaults.crossOverApplication() != nil {
                HStack {
                    Spacer()
                    Button("Use Detected Location") {
                        guard !settings.applicationTerminating else { return }
                        fence.cancel()
                        EngineDefaults.setCrossOverApplication(nil)
                        location = ""
                        Task { await settings.refreshCrossOverDependency() }
                    }
                }
            }
        } header: {
            HStack {
                Text("CrossOver")
                Spacer()
                Button("Check Again") { Task { await settings.refreshCrossOverDependency() } }
                    .buttonStyle(.borderless)
                    .disabled(!allowsCheck || settings.checkingDependency || settings.applicationTerminating)
                    .accessibilityLabel("Check for CrossOver again")
                    .accessibilityIdentifier("xodus.engines.refresh")
            }
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

    /// Escape discards an unapplied edit and shows the saved or detected location again.
    private func discardDraft() {
        fence.cancel()
        location = Self.suggestedLocation(saved: EngineDefaults.crossOverApplication(),
                                          state: settings.crossOverDependency, current: "")
        error = nil
    }

    private var installedVersion: String? {
        if case .installed(let app) = settings.crossOverDependency { return app.version }
        return nil
    }

    private var status: String {
        switch settings.crossOverDependency {
        case .notChecked: "Not Checked"
        case .checking: "Checking"
        case .absent: "Not Installed"
        case .unverified: "Couldn't Verify"
        case .installed: EngineDefaults.crossOverApplication() == nil ? "Detected" : "Configured"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = EnginePanelLocation.start(for: location)
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

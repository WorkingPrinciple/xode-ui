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
        case full, unreadable, unwritable, duplicate

        var message: String {
            switch self {
            case .duplicate: "This engine is already added."
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

    /// The path with `~`, `.`/`..`, trailing slashes and symlinks resolved.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// QA E8: the same engine — the same resolved folder or the same resolved Wine binary — is
    /// refused rather than listed twice.
    static func adding(_ engine: UserEngine, to engines: [UserEngine]) throws(StoreError) -> [UserEngine] {
        let location = resolved(engine.location), wine = resolved(engine.wine)
        if engines.contains(where: { resolved($0.location) == location || resolved($0.wine) == wine }) {
            throw .duplicate
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
    /// The user engine – removes; nil when the list is used without +/– controls.
    var selection: Binding<UUID?>? = nil
    var info: ((UserEngine) -> Void)? = nil

    var body: some View {
        ForEach(model.engines) { engine in
            let selected = selection?.wrappedValue == engine.id
            EngineRow(name: engine.name, detail: engine.version,
                      location: engine.location, state: .testingOnly, info: info.map { show in { show(engine) } }) {
                if selection == nil {
                    Button("Remove", role: .destructive) { model.remove(engine) }
                        .disabled(!model.storeReadable || model.terminating())
                        .accessibilityLabel("Remove \(engine.name)")
                }
            }
            .contentShape(Rectangle())
            .listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
            .onTapGesture { selection?.wrappedValue = selected ? nil : engine.id }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onDeleteCommand { if selection != nil { model.remove(engine); selection?.wrappedValue = nil } }
        }
        if selection == nil {
            ForEach(model.suggestions) { engine in
                EngineRow(name: engine.name, detail: EngineRowState.subtitle([engine.version, "Found on This Mac"]),
                          location: engine.location, state: .testingOnly) {
                    Button("Add") { model.add(engine) }
                        .disabled(!model.storeReadable || model.pending)
                        .accessibilityLabel("Add \(engine.name)")
                }
            }
        }
        if let storeError = model.storeError, storeError == .unreadable || storeError == .full {
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

/// Advanced engine settings in a sheet (COR-279 step 8), not an inline disclosure.
struct EngineAdvancedSheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Advanced").font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Form { content() }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620)
        .frame(minHeight: 240, idealHeight: 360, maxHeight: 640)
    }
}

/// +/– under the Engines list (Login Items pattern, COR-279 step 6). + offers Add Engine… (an open panel)
/// and engines found on this Mac; – removes the selected user engine. Add errors appear as an alert.
struct EngineListControls: View {
    @ObservedObject var model: UserEngineModel
    var allowsFileReads = true
    @Binding var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Add Engine…", action: model.choose)
                if !model.suggestions.isEmpty {
                    Section("Found on This Mac") {
                        ForEach(model.suggestions) { engine in
                            Button([engine.name, engine.version].compactMap { $0 }.joined(separator: " ")) {
                                model.add(engine)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!allowsFileReads || !model.storeReadable || model.pending)
            .accessibilityLabel("Add Engine")
            .accessibilityIdentifier("xodus.engines.add")
            Divider().frame(height: 16).padding(.horizontal, 6)
            Button {
                guard let id = selection, let engine = model.engines.first(where: { $0.id == id }) else { return }
                model.remove(engine)
                selection = nil
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(selection == nil || !model.storeReadable || model.terminating())
            .accessibilityLabel("Remove Engine")
            .accessibilityIdentifier("xodus.engines.remove")
            if model.pending { ProgressView().controlSize(.small).padding(.leading, 8).accessibilityLabel("Checking engine") }
            Spacer()
        }
        .alert("Couldn't Add Engine", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.discardDraft() } })) {
            Button("OK") { model.discardDraft() }
        } message: {
            Text(model.error ?? "")
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

/// The one status vocabulary for every engine row (COR-279). "Default" is a subtitle suffix, not a status.
enum EngineRowState: Equatable, CaseIterable {
    case ready, updateAvailable, notInstalled, verifying, couldntVerify, notQualified, testingOnly

    var title: String {
        switch self {
        case .ready: "Ready"
        case .updateAvailable: "Update Available"
        case .notInstalled: "Not Installed"
        case .verifying: "Verifying"
        case .couldntVerify: "Couldn't Verify"
        case .notQualified: "Not Qualified"
        case .testingOnly: "Testing Only"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .updateAvailable: "arrow.down.circle"
        case .notInstalled: "minus.circle"
        case .verifying: "clock"
        case .couldntVerify: "exclamationmark.triangle"
        case .notQualified: "slash.circle"
        case .testingOnly: "flask"
        }
    }

    /// Subtitle with the default marker appended, so readiness stays visible on the default engine.
    static func subtitle(_ parts: [String?], isDefault: Bool = false) -> String? {
        (parts + [isDefault ? "Default" : nil]).compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

struct EngineRow<Actions: View>: View {
    let name: String
    var detail: String?
    var location: String?
    /// nil shows no badge: nothing has been checked yet, so no status is claimed.
    let state: EngineRowState?
    /// Opens the engine's detail sheet (COR-279 step 3); nil hides the ⓘ button.
    var info: (() -> Void)? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let state {
                    Label(state.title, systemImage: state.symbol)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(state == .ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                actions()
                if let info {
                    Button(action: info) { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("Details")
                        .accessibilityLabel("Details for \(name)")
                }
            }
        } label: {
            Text(name)
            if let secondary = [detail, location].compactMap({ $0 }).first {
                Text(secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue([state?.title, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

extension EngineRow {
    /// Transitional signature for the pre-COR-167 picker body until the integrator adopts EngineConfiguratorForm.
    init(name: String, version: String?, location: String?, status: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        let state: EngineRowState = ["Default", "Ready"].contains(status) ? .ready : .couldntVerify
        self.init(name: name, detail: EngineRowState.subtitle([version], isDefault: status == "Default"),
                  location: location, state: state, actions: actions)
    }
}

/// User-facing engine names. Display only: engine IDs, registry names and saved selections are unchanged.
enum EngineDisplayName {
    struct Presentation: Equatable {
        let name: String
        let detail: String?
        let titleSpecific: Bool
    }

    private static let titles: [(marker: String, title: String)] = [("dirt5", "DIRT 5"), ("witcher", "The Witcher"),
                                                                    ("fh6", "Forza Horizon 6")]

    static func presentation(for id: String?) -> Presentation {
        guard let id else { return Presentation(name: "Calimocho", detail: nil, titleSpecific: false) }
        let lowered = id.lowercased()
        guard lowered.hasPrefix("calimocho") else { return Presentation(name: id, detail: nil, titleSpecific: false) }
        let parts = lowered.split(separator: "-").map(String.init)
        // The managed release is plainly "Calimocho"; any other release keeps its version so no two rows match.
        let base = parts.count >= 4 ? parts[0..<4].joined(separator: "-") : nil
        let baseFacts = base.flatMap(releaseVersion)
        let otherRelease = base.map { $0 != CalimochoRelease.engineID.lowercased() } ?? false
        if parts.count == 4, let facts = baseFacts {
            return Presentation(name: otherRelease ? "Calimocho \(facts.version)" : "Calimocho", detail: facts.detail,
                                titleSpecific: false)
        }
        let wine = wineVersion(lowered).map { "Wine \($0)" } ?? baseFacts.map { $0.detail }
        if let match = titles.first(where: { lowered.contains($0.marker) }) {
            let version = baseFacts.flatMap { otherRelease ? " (\($0.version))" : nil } ?? ""
            return Presentation(name: "Calimocho for \(match.title)\(version)",
                                detail: [wine, "Tuned for \(match.title) only"].compactMap { $0 }.joined(separator: " · "),
                                titleSpecific: true)
        }
        if lowered.hasSuffix("-private") {
            return Presentation(name: "Calimocho (developer build)", detail: wine, titleSpecific: false)
        }
        if lowered.contains("tls-vulkan") {
            return Presentation(name: "Calimocho (alternate build)", detail: wine, titleSpecific: false)
        }
        return Presentation(name: "Calimocho (\(id))", detail: wine, titleSpecific: false)
    }

    static func name(_ id: String?) -> String { presentation(for: id).name }

    /// Release engine version: 0.<Wine major+minor>.<GPTK major>.<our build>.
    /// "calimocho-11.20-4.0b3-02" → version "0.1120.4.2", detail "Wine 11.20 · GPTK 4.0 beta 3".
    static func releaseVersion(_ id: String) -> (version: String, detail: String)? {
        let parts = id.lowercased().split(separator: "-").map(String.init)
        guard parts.count == 4, parts[0] == "calimocho",
              let wine = parts[1].wholeMatch(of: #/([0-9]+)\.([0-9]+)/#),
              let gptk = parts[2].wholeMatch(of: #/([0-9]+)\.([0-9]+)(?:b([0-9]+))?/#),
              let build = Int(parts[3]), build > 0 else { return nil }
        let beta = gptk.output.3.map { " beta \($0)" } ?? ""
        return ("0.\(wine.output.1)\(wine.output.2).\(gptk.output.1).\(build)",
                "Wine \(parts[1]) · GPTK \(gptk.output.1).\(gptk.output.2)\(beta)")
    }

    private static func wineVersion(_ id: String) -> String? {
        guard let range = id.range(of: #"wine[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return String(id[range].dropFirst(4))
    }
}

/// Whether Play has a launch-ready Calimocho. `release` is the local release verification
/// (`CalimochoAvailability.verifiedRelease()`, run off the main actor; `.checking` while it runs,
/// nil before it has run). Until a check completes the state is `.notChecked`. A verified release
/// that backend admission hasn't enabled yet stays neutral, never "invalid".
enum CalimochoAvailability: Equatable, Sendable {
    case notChecked, checking, ready, pendingVerification, missing, invalid(String)

    static func from(choices: [EngineChoice], checking: Bool, release: CalimochoAvailability?) -> Self {
        if choices.contains(where: \.ready) { return .ready }
        if checking { return .checking }
        switch release {
        case .ready?, .pendingVerification?: return .pendingVerification
        case .missing?: return .missing
        case .invalid(let reason)?: return .invalid(reason)
        case .checking?: return .checking
        case .notChecked?, nil: return .notChecked
        }
    }

    /// Runs the active pin's raw release verification off the main actor (it reads and hashes the engine).
    /// `status(results:verification:)` applies the engine check's admission and rejection.
    static func verifyReleaseInBackground(
        _ pin: CalimochoReleasePin = CalimochoReleasePin.all.last!,
        admission: EngineInspection?, root: URL = CalimochoReleaseEngines.defaultEnginesRoot
    ) async -> Self {
        await Task.detached(priority: .utility) {
            CalimochoAvailability.verifiedRelease(pin, root: root, admission: admission)
        }.value
    }

    static var rejectedReason: String {
        "\(AppBrand.displayName)'s engine check couldn't confirm it. Choose Check Again, or reinstall Calimocho."
    }

    /// "Not admitted" is neutral only while no completed check has rejected this pin; a rejection stays invalid.
    static func neutralizingAdmission(_ status: Self, rejected: Bool) -> Self {
        guard status == .invalid(notAdmittedReason) else { return status }
        return rejected ? .invalid(rejectedReason) : .pendingVerification
    }

    /// True when a completed engine check failed the active pinned release.
    @MainActor static func rejected(in results: some EngineCheckResults) -> Bool {
        results.failedEngineOverrides.contains(CalimochoRelease.engineID)
    }

    /// The engine choices a completed check produced.
    @MainActor static func choices(in results: some EngineCheckResults) -> [EngineChoice] {
        results.availableEngineOverrides.compactMap { selection in
            selection.inspection.engineName.map {
                EngineChoice.named($0, ready: true,
                                   playable: EngineChoice.playsInBeta(admittedProvider: selection.inspection.admittedProvider))
            }
        }
            + results.failedEngineOverrides.sorted().map { EngineChoice.named($0, ready: false) }
    }

    /// The status the Engines pane and readiness show, from the engine check and the raw release verification.
    @MainActor static func status(results: some EngineCheckResults, verification: Self?, checking: Bool = false) -> Self {
        from(choices: choices(in: results), checking: checking || results.checkingEngineOverrides,
             release: verification.map { neutralizingAdmission($0, rejected: rejected(in: results)) })
    }

    /// The backend inspection for the active pinned release, if the engine check has one.
    @MainActor static func admission(in results: some EngineCheckResults) -> EngineInspection? {
        results.availableEngineOverrides.first { $0.inspection.engineName == CalimochoRelease.engineID }?.inspection
    }

    var needsDownload: Bool {
        switch self {
        case .missing, .invalid: true
        case .notChecked, .checking, .ready, .pendingVerification: false
        }
    }

    /// Shown in place of an empty engine list, so the section is never a bare header.
    var emptyListMessage: String? {
        switch self {
        case .notChecked: "Engines are checked once your account and game connection are ready."
        case .checking: "Checking engines…"
        case .ready, .pendingVerification, .missing, .invalid: nil
        }
    }

    /// The reason shown under the Calimocho row: only what its status and action don't already say.
    var rowReason: String? {
        switch self {
        case .invalid, .pendingVerification: message
        case .missing, .notChecked, .checking, .ready: nil
        }
    }

    var message: String? {
        switch self {
        case .missing:
            "Calimocho isn't installed. Get it to use games pinned to this release."
        case .invalid(let reason): "Calimocho couldn't be verified. \(reason)"
        case .pendingVerification:
            "Calimocho is installed. It will be ready once \(AppBrand.displayName) verifies it."
        case .notChecked, .checking, .ready: nil
        }
    }
}

/// What a completed engine check found; InstalledGamesController provides it, checks use a fake.
@MainActor protocol EngineCheckResults {
    var availableEngineOverrides: [AdmittedEngineSelection] { get }
    var failedEngineOverrides: Set<String> { get }
    var checkingEngineOverrides: Bool { get }
}

extension InstalledGamesController: EngineCheckResults {}

struct CalimochoReleaseInstallControls: View {
    @ObservedObject var installer: CalimochoReleaseInstallController
    var isBusy: @MainActor @Sendable () -> Bool = { true }
    var refreshAdmission: @MainActor () async -> Bool = { false }
    var allowsRemoval = true
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = installer.progress {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Calimocho download progress")
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Text(progress.label).foregroundStyle(.secondary)
                    Spacer()
                    if progress != .checkingAdmission && progress != .removing {
                        Button("Cancel", action: installer.cancel)
                            .accessibilityIdentifier("xodus.engines.calimocho.cancel")
                    }
                }
                .accessibilityIdentifier("xodus.engines.calimocho.progress")
            } else if !installer.hasEngineFolder && !installer.offersPinnedUpdate {
                if CalimochoRelease.downloadPublished {
                    HStack {
                        Button(CalimochoRelease.getTitle) {
                            installer.install(refreshAdmission: refreshAdmission)
                        }
                        .accessibilityIdentifier("xodus.engines.calimocho.get")
                        Text(downloadSize).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(CalimochoRelease.unpublishedNotice)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("xodus.engines.calimocho.unpublished")
                }
            }
            if let error = installer.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.engines.calimocho.error")
            }
            if let notice = installer.notice {
                Label(notice, systemImage: installer.noticeSymbol)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.engines.calimocho.notice")
            }
            if installer.hasEngineFolder {
                Text(installer.engineURL.path)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("xodus.engines.calimocho.location")
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([installer.engineURL])
                    }
                    .accessibilityIdentifier("xodus.engines.calimocho.show")
                    if allowsRemoval {
                        Button("Remove Calimocho…", role: .destructive) { confirmingRemoval = true }
                            .disabled(isBusy() || installer.isWorking)
                            .help("Quit any running game and finish active operations before removing Calimocho.")
                            .accessibilityIdentifier("xodus.engines.calimocho.remove")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Move Calimocho to the Trash?", isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                installer.remove(isBusy: isBusy, refreshAdmission: { _ = await refreshAdmission() })
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the pinned Calimocho engine folder will be moved. Game prefixes and saves won't be changed.")
        }
    }

    private var downloadSize: String {
        guard let pin = CalimochoReleasePin.all.last,
              let archive = pin.archiveByteCount, let expanded = pin.expandedByteCount else { return "" }
        return "\(ByteCountFormatter.string(fromByteCount: archive, countStyle: .file)) download · about \(ByteCountFormatter.string(fromByteCount: expanded, countStyle: .file)) installed"
    }
}

enum EnginesCopy {
    static let lead = "Engines run Windows games on your Mac. You can add your own Wine engines for testing; in this beta, games play with Calimocho."
    /// Why a non-Calimocho engine can't be the default (REQ-109/COR-201: custom-engine launching isn't in 0.2.0).
    static let testingOnly = "Saved for testing. In this beta, games play with Calimocho."
    static let listFooter = "Calimocho is built in and runs every game unless a game needs a specific engine."
    static let listFooterPending = "Once Calimocho is ready, it runs every game unless a game needs a specific engine."
    static let defaultFooter = "New games use this engine. Change a game's engine from its menu in the Library."
    static let crossOver = "CrossOver is reserved for No Man's Sky once it qualifies; every other game plays with Calimocho."
    static let crossOverLicense = "Use your own licensed copy of CrossOver; \(AppBrand.displayName) doesn't include it."
}

/// One engine the configurator can make the launch default.
struct EngineChoice: Identifiable, Equatable {
    let id: String
    let name: String
    var version: String? = nil
    let ready: Bool
    /// Whether Play can use it in this beta: only engines the backend admits as Calimocho.
    var playable = true

    /// The default and per-game choices offer only engines Play uses, so a choice is never ignored.
    static func playsInBeta(admittedProvider: String?) -> Bool { admittedProvider == "calimocho" }

    /// Any names still shared after display naming get their engine ID appended, so no two rows or
    /// Default choices read the same (review 03188939).
    static func disambiguated(_ choices: [EngineChoice]) -> [EngineChoice] {
        let counts = Dictionary(grouping: choices, by: \.name).mapValues(\.count)
        return choices.map { choice in
            guard counts[choice.name, default: 0] > 1 else { return choice }
            return EngineChoice(id: choice.id, name: "\(choice.name) (\(choice.id))", version: choice.version,
                                ready: choice.ready, playable: choice.playable)
        }
    }

    /// A choice named from its engine ID, with the secondary line users see under it.
    static func named(_ id: String, ready: Bool, playable: Bool = true) -> Self {
        let presentation = EngineDisplayName.presentation(for: id)
        return EngineChoice(id: id, name: presentation.name, version: presentation.detail, ready: ready,
                            playable: playable)
    }
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
    /// Host-supplied Calimocho state; nil derives it from the choices alone.
    var calimochoStatus: CalimochoAvailability? = nil
    var calimochoInstaller: CalimochoReleaseInstallController? = nil
    var engineRemovalBusy: @MainActor @Sendable () -> Bool = { true }
    var refreshReleaseAdmission: @MainActor () async -> Bool = { false }
    var showsCalimochoUpdates = false
    var checkCalimochoUpdatesOnOpen = false
    var beginCalimochoUpdate: @MainActor (LocalCalimochoRelease) -> Void = { _ in }
    var removeOldCalimocho: @MainActor () -> Void = {}
    /// Backend executable for read-only provider verdicts (Highball); empty means none.
    var backendPath = ""
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
            refresh: refresh, showsAdvanced: showsAdvanced, userEngineModel: userEngineModel,
            calimochoStatus: calimochoStatus, calimochoInstaller: calimochoInstaller,
            engineRemovalBusy: engineRemovalBusy, refreshReleaseAdmission: refreshReleaseAdmission,
            showsCalimochoUpdates: showsCalimochoUpdates, beginCalimochoUpdate: beginCalimochoUpdate,
            removeOldCalimocho: removeOldCalimocho,
            checkCalimochoUpdatesOnOpen: checkCalimochoUpdatesOnOpen,
            backendPath: backendPath,
            advanced: advanced)
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
    let calimochoStatus: CalimochoAvailability?
    let engineRemovalBusy: @MainActor @Sendable () -> Bool
    let refreshReleaseAdmission: @MainActor () async -> Bool
    let showsCalimochoUpdates: Bool
    let beginCalimochoUpdate: @MainActor (LocalCalimochoRelease) -> Void
    let removeOldCalimocho: @MainActor () -> Void
    let checkCalimochoUpdatesOnOpen: Bool
    let backendPath: String
    let advanced: () -> Advanced
    @State private var providerRefresh = 0
    @StateObject private var ownedUsers: UserEngineModel
    @StateObject private var ownedCalimochoInstaller: CalimochoReleaseInstallController
    private var users: UserEngineModel { ownedUsers }
    private var calimochoInstaller: CalimochoReleaseInstallController { ownedCalimochoInstaller }
    /// nil until detection has run; Highball is never called Not Installed without one.
    @State private var highball: HighballState?
    @State private var detail: EngineDetail?
    @State private var selectedUserEngine: UUID?
    @State private var showingAdvanced = false

    init(choices: [EngineChoice], defaultID: String?, defaultName: String, checking: Bool, error: String?,
         settings: RuntimeProviderSettings, allowsFileReads: Bool, userEngineStore: UserDefaults,
         suggestions: [UserEngine], setDefault: @escaping (String) -> Void, refresh: @escaping () -> Void,
         showsAdvanced: Bool = true, userEngineModel: UserEngineModel? = nil,
         calimochoStatus: CalimochoAvailability? = nil,
         calimochoInstaller: CalimochoReleaseInstallController? = nil,
         engineRemovalBusy: @escaping @MainActor @Sendable () -> Bool = { true },
         refreshReleaseAdmission: @escaping @MainActor () async -> Bool = { false },
         showsCalimochoUpdates: Bool = false,
         beginCalimochoUpdate: @escaping @MainActor (LocalCalimochoRelease) -> Void = { _ in },
         removeOldCalimocho: @escaping @MainActor () -> Void = {},
         checkCalimochoUpdatesOnOpen: Bool = false,
         backendPath: String = "",
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
        self.calimochoStatus = calimochoStatus
        self.engineRemovalBusy = engineRemovalBusy
        self.refreshReleaseAdmission = refreshReleaseAdmission
        self.showsCalimochoUpdates = showsCalimochoUpdates
        self.beginCalimochoUpdate = beginCalimochoUpdate
        self.removeOldCalimocho = removeOldCalimocho
        self.checkCalimochoUpdatesOnOpen = checkCalimochoUpdatesOnOpen
        self.backendPath = backendPath
        self.advanced = advanced
        _ownedUsers = StateObject(wrappedValue:
            userEngineModel ?? UserEngineModel(store: userEngineStore, suggestions: suggestions))
        _ownedCalimochoInstaller = StateObject(wrappedValue:
            calimochoInstaller ?? CalimochoReleaseInstallController())
    }

    private var calimocho: CalimochoAvailability {
        calimochoStatus ?? .from(choices: choices, checking: checking, release: nil)
    }
    private var checkingAny: Bool { checking || settings.checkingDependency }

    @ViewBuilder private var enginesList: some View {
        Section {
            if choices.isEmpty, let placeholder = calimocho.emptyListMessage {
                Text(placeholder).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.engines.empty")
            }
            CalimochoEngineRow(installer: calimochoInstaller, availability: calimocho,
                               isDefault: defaultID == CalimochoRelease.engineID || defaultID == nil,
                               showsUpdates: showsCalimochoUpdates,
                               refreshAdmission: refreshReleaseAdmission, beginUpdate: beginCalimochoUpdate,
                               showDetails: { detail = .calimocho })
            if let reason = calimocho.rowReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.engines.calimocho.status")
            }
            ForEach(choices.filter { $0.id != CalimochoRelease.engineID }) { choice in
                EngineRow(name: choice.name,
                          detail: EngineRowState.subtitle([choice.version.flatMap { choice.name.contains($0) ? nil : $0 }],
                                                          isDefault: choice.id == defaultID),
                          state: Self.state(for: choice, checking: checking),
                          info: { detail = .engine(choice) }) {
                    EmptyView()
                }
            }
            CrossOverEngineRow(presentation: CrossOverEngineRow.presentation(state: settings.crossOverDependency)) {
                detail = .crossOver
            }
            HighballEngineRow(state: highball) { detail = .highball }
            UserEngineList(model: users, allowsFileReads: allowsFileReads, selection: $selectedUserEngine) { detail = .user($0) }
            EngineListControls(model: users, allowsFileReads: allowsFileReads, selection: $selectedUserEngine)
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Engines")
                Spacer()
                if checkingAny { ProgressView().controlSize(.small).accessibilityLabel("Checking engines") }
                Button("Check Again") {
                    refresh()
                    providerRefresh += 1
                    Task { await settings.refreshCrossOverDependency() }
                }
                .controlSize(.small)
                .disabled(checkingAny || calimochoInstaller.isWorking || !allowsFileReads || settings.applicationTerminating)
                .accessibilityLabel("Check engines and CrossOver again")
                .accessibilityIdentifier("xodus.engines.refresh")
            }
        } footer: {
            Text(choices.contains(where: { $0.ready && $0.playable }) ? EnginesCopy.listFooter : EnginesCopy.listFooterPending)
                .multilineTextAlignment(.leading)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("xodus.engines.footer")
        }
        .task(id: "\(allowsFileReads):\(providerRefresh)") { await refreshHighball() }
        .task(id: checkCalimochoUpdatesOnOpen) {
            guard showsCalimochoUpdates, checkCalimochoUpdatesOnOpen, allowsFileReads else { return }
            await calimochoInstaller.checkForUpdates(automatic: true)
        }
        .sheet(item: $detail) { item in
            EngineDetailSheet(detail: item, settings: settings, highball: highball, users: users,
                              defaultID: defaultID, allowsFileReads: allowsFileReads,
                              calimocho: .init(installer: calimochoInstaller, isBusy: engineRemovalBusy,
                                               refreshAdmission: refreshReleaseAdmission,
                                               showsUpdates: showsCalimochoUpdates,
                                               beginUpdate: beginCalimochoUpdate, removeOld: removeOldCalimocho)) {
                detail = nil
            }
        }
    }

    /// The plain Default row: the saved default's name, with its state when it isn't ready (review 7c5beadb M1).
    static func defaultValue(choices: [EngineChoice], defaultID: String?, defaultName: String,
                             calimocho: CalimochoAvailability, checking: Bool) -> String {
        guard let defaultID else { return "None Ready" }
        func suffixed(_ state: EngineRowState?) -> String {
            guard let state, state != .ready, state != .updateAvailable else { return defaultName }
            return "\(defaultName) · \(state.title)"
        }
        if defaultID == CalimochoRelease.engineID {
            return suffixed(CalimochoEngineRow.presentation(availability: calimocho, hasFolder: false, progress: nil,
                                                            updateAvailable: false, downloadPublished: true,
                                                            isDefault: true).state)
        }
        guard let choice = choices.first(where: { $0.id == defaultID }) else {
            // Before any engine check there is nothing to report; while one runs, say so.
            if checking { return suffixed(.verifying) }
            return calimocho == .notChecked ? defaultName : suffixed(.notInstalled)
        }
        return suffixed(state(for: choice, checking: checking))
    }

    /// Default Engine offers only engines Play can use; with one or none it is a plain value (COR-279 step 7).
    static func selectableDefaults(_ choices: [EngineChoice]) -> [EngineChoice] {
        choices.filter { $0.ready && $0.playable }
    }

    static func state(for choice: EngineChoice, checking: Bool) -> EngineRowState {
        if !choice.ready { return checking ? .verifying : .couldntVerify }
        return choice.playable ? .ready : .testingOnly
    }

    @ViewBuilder private var defaultSection: some View {
        let selectable = Self.selectableDefaults(choices)
        Section {
            if selectable.count > 1 {
                Picker("Default Engine", selection: Binding(
                    get: { defaultID ?? "" },
                    set: { id in
                        if id != defaultID, selectable.contains(where: { $0.id == id }) { setDefault(id) }
                    })) {
                    if defaultID == nil || !selectable.contains(where: { $0.id == defaultID }) {
                        Text(defaultName).tag(defaultID ?? "")
                    }
                    ForEach(selectable) { choice in Text(choice.name).tag(choice.id) }
                }
                .pickerStyle(.menu)
                .disabled(!allowsFileReads || settings.applicationTerminating || calimochoInstaller.isWorking)
                .accessibilityIdentifier("xodus.engines.default")
            } else {
                LabeledContent("Default Engine") {
                    Text(Self.defaultValue(choices: choices, defaultID: defaultID, defaultName: defaultName,
                                           calimocho: calimocho, checking: checkingAny))
                }
                .accessibilityIdentifier("xodus.engines.default")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        } footer: {
            Text(EnginesCopy.defaultFooter)
                .multilineTextAlignment(.leading)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refreshHighball() async {
        guard allowsFileReads else { return }
        let inspect: (@MainActor () async -> HighballState?)?
        if backendPath.isEmpty {
            inspect = nil
        } else {
            let settings = settings, backendPath = backendPath
            inspect = { await settings.inspectHighball(backendPath: backendPath) }
        }
        if let resolved = await HighballSection.resolve(inspect: inspect) { highball = resolved }
    }

    var body: some View {
        defaultSection
        enginesList
            .onAppear { users.terminating = { [settings] in settings.applicationTerminating } }
        if showsAdvanced {
            Section {
                HStack {
                    Spacer()
                    Button("Advanced…") { showingAdvanced = true }
                        .accessibilityIdentifier("xodus.engines.advanced")
                }
            }
            .sheet(isPresented: $showingAdvanced) {
                EngineAdvancedSheet(content: advanced) { showingAdvanced = false }
            }
        }
    }
}

/// CrossOver in the Engines list (REQ-109, COR-279): always listed, scoped to No Man's Sky, never a default choice.
/// Its ⓘ opens the detail sheet, which holds the location controls.
struct CrossOverEngineRow: View {
    struct Presentation: Equatable {
        let state: EngineRowState?
        let detail: String
    }

    static let scope = "No Man's Sky only"

    let presentation: Presentation
    let showDetails: () -> Void

    var body: some View {
        EngineRow(name: "CrossOver", detail: presentation.detail, state: presentation.state, info: showDetails) {
            if presentation.state == .notInstalled {
                Link("Get…", destination: CrossOverDependencyState.trialDownloadURL).accessibleLink()
                    .accessibilityLabel("Get CrossOver")
                    .accessibilityIdentifier("xodus.engines.crossover.row.get")
            }
        }
        .accessibilityIdentifier("xodus.engines.crossover.row")
    }

    static func presentation(state: CrossOverDependencyState) -> Presentation {
        switch state {
        case .installed(let app): Presentation(state: .ready, detail: "\(app.version) · \(scope)")
        case .absent: Presentation(state: .notInstalled, detail: "\(scope) · from CodeWeavers")
        case .unverified: Presentation(state: .couldntVerify, detail: scope)
        case .checking: Presentation(state: .verifying, detail: scope)
        case .notChecked: Presentation(state: nil, detail: scope)
        }
    }
}

/// CrossOver configuration: detected or saved location, editable, never the launch default.
struct CrossOverLocationRow: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsCheck = true
    /// The detail sheet shows status once, in its Version section.
    var showsStatus = true
    @State private var location = ""
    @State private var error: String?
    @State private var fence = EngineRequestFence()

    var body: some View {
        Section {
            if showsStatus { LabeledContent("Status") {
                let row = CrossOverEngineRow.presentation(state: settings.crossOverDependency)
                Text(row.state?.title ?? "—").foregroundStyle(.secondary)
                    .accessibilityIdentifier("xodus.engines.crossover.status")
            } }
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
                    if Self.offersUseApp(location: location, saved: EngineDefaults.crossOverApplication(),
                                         state: settings.crossOverDependency) {
                        Button("Use App", action: apply)
                            .disabled(!allowsCheck || fence.pending)
                            .accessibilityLabel("Use this CrossOver application")
                    }
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
            Text("Location")
        }
        .onChange(of: settings.crossOverDependency, initial: true) { _, state in
            guard !fence.pending else { return }
            location = CrossOverLocationRow.suggestedLocation(saved: EngineDefaults.crossOverApplication(),
                                                             state: state, current: location)
        }
    }

    /// Use App appears only when the field names an app other than the one already in use.
    static func offersUseApp(location: String, saved: String?, state: CrossOverDependencyState) -> Bool {
        let path = (location.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let saved { return standardized != URL(fileURLWithPath: saved).standardizedFileURL.path }
        if case .installed(let app) = state { return standardized != app.location.standardizedFileURL.path }
        return true
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

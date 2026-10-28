// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import OSLog
import XodusCore
import XodusManagement

enum WindowsProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case win7, win8, win81, win10, win11
    case win1124h2 = "win11-24h2"
    var id: String { rawValue }
    var build: UInt32 {
        switch self {
        case .win7: 7601
        case .win8: 9200
        case .win81: 9600
        case .win10: 19045
        case .win11: 22000
        case .win1124h2: 26100
        }
    }
    var label: String { NativeWindowsVersion(build: build, profile: rawValue).label }
}

enum WindowsProfileFailure: String, Error, LocalizedError, CaseIterable, Codable {
    case contract = "WINDOWS_PROFILE_CONTRACT_UNSUPPORTED"
    case operation = "WINDOWS_PROFILE_OPERATION_UNSUPPORTED"
    case unsupported = "WINDOWS_PROFILE_UNSUPPORTED"
    case unowned = "WINDOWS_PROFILE_PREFIX_UNOWNED"
    case mismatch = "WINDOWS_PROFILE_PREFIX_MISMATCH"
    case inUse = "WINDOWS_PROFILE_PREFIX_IN_USE"
    case unreadable = "WINDOWS_PROFILE_PREFIX_UNREADABLE"
    case engineChanged = "WINDOWS_PROFILE_ENGINE_CHANGED"
    case applyFailed = "WINDOWS_PROFILE_APPLY_FAILED"
    case shadowed = "WINDOWS_PROFILE_SHADOWED"
    case incomplete = "WINDOWS_PROFILE_PREFIX_SETUP_INCOMPLETE"
    case receipt = "WINDOWS_PROFILE_RECEIPT_INVALID"

    var errorDescription: String? {
        switch self {
        case .contract, .operation: "The bundled engine needs an update to manage Windows version profiles. Update \(AppBrand.displayName), then try again."
        case .unsupported: "This engine doesn't support that Windows profile. Refresh and choose one of its supported profiles."
        case .unowned: "This prefix isn't owned by \(AppBrand.displayName). Its Windows profile wasn't changed."
        case .mismatch: "This prefix doesn't match this game. Its Windows profile wasn't changed."
        case .inUse: "This prefix is in use. Finish playing and wait for its current operation to stop, then try again."
        case .unreadable: "This prefix couldn't be read or locked. Check its availability and permissions before retrying."
        case .engineChanged: "The engine or registry changed. Refresh Engines and inspect the Windows profile again."
        // 1327a6e4 nit: as a refusal (before the run step started) nothing was changed; the partial-change outcome
        // for a started set is WindowsProfilePartialChange.
        case .applyFailed: "The engine couldn't start the Windows profile change. Nothing was changed."
        case .shadowed: "This executable has its own Windows version setting, which overrides the prefix's profile. Choose the profile it already uses, or nothing can be changed here."
        case .incomplete: "This prefix's setup never completed or failed. Changing its Windows profile won't repair it. Use a fresh prefix."
        case .receipt: "The Windows profile result couldn't be verified. Inspect it again before playing; no successful change is claimed."
        }
    }
}

/// 908606e9 M2 / 1327a6e4 MAJ-1, m-1, m-3: prefixes whose Windows profile set didn't verify, keyed by prefix path and
/// kept in user defaults across relaunches. Play refuses for a marked prefix; only a verified set, a pure refusal that
/// found it unmarked, or an inspect reporting the prefix idle (inUse false) clears it.
@MainActor
final class WindowsProfileUnverifiedMarks: ObservableObject {
    static let key = "Xodus.windowsProfileUnverifiedPrefixes.v1"
    static let copy = "This game's Windows profile may have changed partly. Open Engine → Windows version… and let it read the profile before playing."
    static let stillInUseCopy = "The prefix is still in use, so the Windows profile can't be confirmed yet. Wait for the engine to stop, then use Refresh; Play stays unavailable until then."
    private let defaults: UserDefaults
    @Published private(set) var prefixes: Set<String>
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefixes = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
    func contains(prefix: String) -> Bool { prefixes.contains(Self.normal(prefix)) }
    func mark(prefix: String) { prefixes.insert(Self.normal(prefix)); save() }
    func clear(prefix: String) { prefixes.remove(Self.normal(prefix)); save() }
    private func save() { defaults.set(prefixes.sorted(), forKey: Self.key) }
    private static func normal(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}

/// Play refused because the launch's prefix carries an unverified Windows profile mark.
struct WindowsProfilePlayHeld: Error, Equatable {
    static let copy = "This game's Windows profile may have changed partly. Open Engine → Windows version… and let it read the profile before playing."
}

/// 908606e9 M1/M2: a set that reached the prefix but didn't verify (status "failed" with any code, or the app's own
/// timeout). The prefix may have changed partly; Play stays blocked for that game until an inspect succeeds.
struct WindowsProfilePartialChange: Error, LocalizedError, Equatable {
    let code: WindowsProfileFailure?
    static let copy = "The Windows profile may have changed partly. Inspect it again before playing; no successful change is claimed."
    var errorDescription: String? {
        switch code {
        case .unreadable?: "The prefix couldn't be read after the change. " + Self.copy
        case .receipt?: "The engine's result couldn't be verified. " + Self.copy
        case .applyFailed?: "The engine couldn't apply and verify the Windows profile. " + Self.copy
        case nil: "The change didn't finish in time. " + Self.copy
        default: Self.copy
        }
    }
}

struct WindowsProfileBinding: Equatable, Sendable {
    let product: String
    let folder: String
    let prefix: String
    let engine: String
    let registry: String
    let digest: String

    func arguments(profile: WindowsProfile? = nil) -> [String] {
        ["prefix-windows-profile", profile == nil ? "inspect" : "set", "--contract-version", "1",
         "--product", product, "--game-dir", folder, "--prefix", prefix,
         "--registry", registry, "--engine", engine, "--expected-registry-sha256", digest]
            + (profile.map { ["--profile", $0.rawValue] } ?? [])
    }
}

struct WindowsProfileReceipt: Decodable, Sendable {
    struct Engine: Decodable, Sendable { let name: String; let registrySha256: String }
    struct Failure: Decodable, Sendable { let code: WindowsProfileFailure; let message: String }
    struct Bound: Decodable, Sendable { let ownership: String; let productBound: Bool }
    struct Named: Decodable, Sendable { let name: String }
    struct ExecutableProfile: Decodable, Sendable { let profile: Named?; let shadowsGlobal: Bool }
    struct Observed: Decodable, Sendable {
        let profile: WindowsProfile?
        let reportedBuild: UInt32
        var label: String { NativeWindowsVersion(build: reportedBuild, profile: profile?.rawValue).label }
    }
    let schemaVersion: Int
    let operation: String
    let status: String
    let product: String
    let executable: String?
    let appDefaultsName: String?
    let prefix: String
    let engine: Engine
    let error: Failure?
    let checkedAt: String
    let binding: Bound?
    let windowsSetup: String?
    let inUse: Bool?
    let supportedProfiles: [WindowsProfile]?
    let effective: Observed?
    let perExecutable: ExecutableProfile?
    let requestedProfile: WindowsProfile?
    let previous: Observed?
    let resulting: Observed?
    let savesPreserved: Bool?
    let packageRequiredMinimum: UInt32?
    let meetsPackageMinimum: Bool?
    let requestedBelowPackageMinimum: Bool?

    var changeBlock: WindowsProfileFailure? { changeBlock(for: nil) }
    /// 908606e9 nit: the producer allows a set whose target equals the executable's own AppDefaults value.
    func changeBlock(for target: WindowsProfile?) -> WindowsProfileFailure? {
        if inUse == true { return .inUse }
        if perExecutable?.shadowsGlobal == true {
            let own = perExecutable?.profile?.name
            if let target, let own, own.caseInsensitiveCompare(target.rawValue) == .orderedSame {} else { return .shadowed }
        }
        if windowsSetup != "none", windowsSetup != "applied" { return .incomplete }
        return nil
    }

    static func decode(_ data: Data, exitCode: Int32, binding: WindowsProfileBinding,
                       requested: WindowsProfile? = nil) throws -> Self {
        let json = try JSONValue.decodeUnique(data, maximumBytes: 32_768)
        try validateShape(json, changing: requested != nil)
        let result = try json.decode(Self.self)
        guard result.schemaVersion == 1, result.operation == (requested == nil ? "inspect" : "set"),
              result.product == binding.product, result.prefix == binding.prefix,
              result.engine.name == binding.engine, result.engine.registrySha256 == binding.digest,
              ISO8601DateFormatter().date(from: result.checkedAt) != nil else { throw WindowsProfileFailure.receipt }
        if requested != nil, result.requestedProfile != requested { throw WindowsProfileFailure.receipt }
        if let failure = result.error {
            guard exitCode != 0, !failure.message.isEmpty,
                  result.status == "refused" || (requested != nil && result.status == "failed") else {
                throw requested != nil ? WindowsProfilePartialChange(code: .receipt) : WindowsProfileFailure.receipt
            }
            // 908606e9 M1: "failed" means the run step started, whatever the code.
            if result.status == "failed" { throw WindowsProfilePartialChange(code: failure.code) }
            throw failure.code
        }
        guard exitCode == 0, result.executable?.isEmpty == false, result.appDefaultsName?.isEmpty == false else {
            throw WindowsProfileFailure.receipt
        }
        if let requested {
            guard ["applied", "unchanged"].contains(result.status), result.requestedProfile == requested,
                  result.savesPreserved == true, result.previous != nil,
                  result.resulting?.profile == requested,
                  result.resulting.map({ $0.reportedBuild >= requested.build }) == true,
                  result.requestedBelowPackageMinimum == result.packageRequiredMinimum.map({ requested.build < $0 }),
                  result.status != "unchanged" || result.previous?.reportedBuild == result.resulting?.reportedBuild
            else { throw WindowsProfileFailure.receipt }
        } else {
            guard result.status == "ok", result.binding?.ownership == "owned", result.binding?.productBound == true,
                  let profiles = result.supportedProfiles, !profiles.isEmpty, Set(profiles).count == profiles.count,
                  let effective = result.effective, result.inUse != nil,
                  ["none", "applied", "pending", "failed", "invalid", "incomplete"].contains(result.windowsSetup ?? ""),
                  result.meetsPackageMinimum == result.packageRequiredMinimum.map({ effective.reportedBuild >= $0 })
            else { throw WindowsProfileFailure.receipt }
        }
        return result
    }

    private static func validateShape(_ json: JSONValue, changing: Bool) throws {
        func exact(_ value: JSONValue?, _ keys: Set<String>) throws {
            guard let object = value?.object, Set(object.keys) == keys else { throw WindowsProfileFailure.receipt }
        }
        func observed(_ value: JSONValue?, source: Bool = false) throws {
            guard value != .null else { return }
            try exact(value, source ? ["profile", "reportedBuild", "source"] : ["profile", "reportedBuild"])
            guard value?["reportedBuild"]?.uint64 != nil else { throw WindowsProfileFailure.receipt }
            if source, !["appDefaults", "global", "currentBuildNumber"].contains(value?["source"]?.string ?? "") {
                throw WindowsProfileFailure.receipt
            }
        }
        func namedProfile(_ value: JSONValue?) throws {
            guard value != .null else { return }
            try exact(value, ["name", "known"])
            guard value?["name"]?.string?.isEmpty == false,
                  let known = value?["known"]?.boolean,
                  known == (WindowsProfile(rawValue: value?["name"]?.string ?? "") != nil)
            else { throw WindowsProfileFailure.receipt }
        }
        let base: Set<String> = ["schemaVersion", "operation", "status", "product", "executable",
            "appDefaultsName", "prefix", "engine", "error", "checkedAt"]
        let set: Set<String> = ["requestedProfile", "previous", "resulting", "savesPreserved",
                               "packageRequiredMinimum", "requestedBelowPackageMinimum"]
        let inspect: Set<String> = ["binding", "windowsSetup", "inUse", "supportedProfiles", "global",
            "perExecutable", "currentBuildNumber", "effective", "packageRequiredMinimum", "meetsPackageMinimum"]
        let success = ["ok", "applied", "unchanged"].contains(json["status"]?.string ?? "")
        try exact(json, base.union(changing ? set : success ? inspect : []))
        try exact(json["engine"], ["name", "registrySha256"])
        if json["error"] != .null { try exact(json["error"], ["code", "message"]) }
        if changing {
            try observed(json["previous"])
            try observed(json["resulting"])
        } else if success {
            try exact(json["binding"], ["ownership", "productBound"])
            try exact(json["global"], ["profile"])
            try exact(json["perExecutable"], ["profile", "shadowsGlobal"])
            guard json["perExecutable"]?["shadowsGlobal"]?.boolean != nil,
                  json["currentBuildNumber"] == .null || json["currentBuildNumber"]?.uint64 != nil
            else { throw WindowsProfileFailure.receipt }
            try namedProfile(json["global"]?["profile"])
            try namedProfile(json["perExecutable"]?["profile"])
            try observed(json["effective"], source: true)
        }
    }
}

@MainActor
final class WindowsProfileSettingsModel: ObservableObject {
    @Published private(set) var receipt: WindowsProfileReceipt?
    @Published private(set) var busy = false
    @Published private(set) var changing = false
    @Published private(set) var message: String?
    @Published private(set) var appliedBelowMinimum = false
    private var binding: WindowsProfileBinding?
    private let client: EngineInspectionClient
    init(client: EngineInspectionClient = EngineInspectionClient()) { self.client = client }

    func unavailable() {
        receipt = nil
        binding = nil
        message = "The bundled engine isn't available. Reconnect it before reading or changing the Windows profile."
    }

    func load(game: InstalledGame, library: InstalledGamesController, configuration: BackendConfiguration) async {
        guard !busy else { return }
        busy = true
        receipt = nil
        binding = nil
        message = nil
        let target: WindowsProfileBinding
        do {
            let launch = try await library.windowsProfileLaunch(for: game, configuration: configuration)
            guard let digest = launch.admittedSelection?.inspection.registrySha256 else { throw NativeLaunchError.engineUnavailable }
            target = WindowsProfileBinding(product: game.storeId, folder: game.folder,
                prefix: launch.prefix.path, engine: launch.engine, registry: launch.registry.path, digest: digest)
        } catch {
            busy = false
            message = Self.failureMessage(error)
            return
        }
        busy = false
        await load(target: target, configuration: configuration, marks: library.windowsProfileMarks)
    }

    /// The inspect itself (also driven directly by checks through a fake CLI).
    func load(target: WindowsProfileBinding, configuration: BackendConfiguration, marks: WindowsProfileUnverifiedMarks) async {
        guard !busy else { return }
        busy = true
        receipt = nil
        binding = nil
        message = nil
        defer { busy = false }
        do {
            let output = try await client.windowsProfile(configuration: configuration, arguments: target.arguments(), changing: false)
            let inspected = try WindowsProfileReceipt.decode(output.0, exitCode: output.1, binding: target)
            receipt = inspected
            binding = target
            // 1327a6e4 MAJ-1: only an inspect that reports the prefix idle clears the mark; leftover engine processes
            // from a timed-out or cancelled set may still be writing it.
            if inspected.inUse == false { marks.clear(prefix: target.prefix) }
            else if marks.contains(prefix: target.prefix) { message = WindowsProfileUnverifiedMarks.stillInUseCopy }
        } catch { message = Self.failureMessage(error) }
    }

    func apply(_ profile: WindowsProfile, game: InstalledGame, library: InstalledGamesController,
               configuration: BackendConfiguration) async {
        guard !busy, let binding, receipt?.supportedProfiles?.contains(profile) == true else { return }
        if let block = receipt?.changeBlock(for: profile) { message = block.localizedDescription; return }
        guard library.runningGameID == nil else { message = WindowsProfileFailure.inUse.localizedDescription; return }
        do { try library.reserveWindowsProfileChange() } catch { message = Self.failureMessage(error); return }
        defer { library.releaseWindowsProfileChange() }
        do {
            let current = try await library.windowsProfileLaunch(for: game, configuration: configuration)
            guard binding == WindowsProfileBinding(product: game.storeId, folder: game.folder, prefix: current.prefix.path,
                engine: current.engine, registry: current.registry.path,
                digest: current.admittedSelection?.inspection.registrySha256 ?? "") else { throw WindowsProfileFailure.engineChanged }
        } catch {
            receipt = nil
            self.binding = nil
            message = Self.failureMessage(error)
            return
        }
        await apply(profile, target: binding, configuration: configuration, marks: library.windowsProfileMarks)
    }

    /// The set itself (also driven directly by checks through a fake CLI).
    func apply(_ profile: WindowsProfile, target binding: WindowsProfileBinding, configuration: BackendConfiguration,
               marks: WindowsProfileUnverifiedMarks) async {
        guard !busy else { return }
        busy = true
        changing = true
        message = nil
        appliedBelowMinimum = false
        defer { busy = false; changing = false }
        let wasMarked = marks.contains(prefix: binding.prefix)
        do {
            // From here the prefix may change: any unverified outcome blocks Play until an idle inspect.
            marks.mark(prefix: binding.prefix)
            let result: WindowsProfileReceipt
            do {
                let output = try await client.windowsProfile(configuration: configuration,
                    arguments: binding.arguments(profile: profile), changing: true)
                result = try WindowsProfileReceipt.decode(output.0, exitCode: output.1, binding: binding, requested: profile)
            } catch let error as WindowsProfileFailure where error != .receipt {
                // A refusal: the producer changed nothing, so the mark returns to what it was before this set.
                if !wasMarked { marks.clear(prefix: binding.prefix) }
                throw error
            } catch let error as WindowsProfilePartialChange { throw error }
            catch {
                if case EngineInspectionError.timedOut = error { throw WindowsProfilePartialChange(code: nil) }
                throw WindowsProfilePartialChange(code: .receipt)
            }
            guard let resulting = result.resulting else { throw WindowsProfilePartialChange(code: .receipt) }
            appliedBelowMinimum = result.requestedBelowPackageMinimum == true
            let applied = result.status == "unchanged" ? "The prefix already reports \(resulting.label)."
                : "The prefix now reports \(resulting.label)."
            message = applied
            marks.clear(prefix: binding.prefix)
            let refreshed = await Self.refreshAfterSet(applied: applied) {
                let inspection = try await self.client.windowsProfile(configuration: configuration,
                    arguments: binding.arguments(), changing: false)
                return try WindowsProfileReceipt.decode(inspection.0, exitCode: inspection.1, binding: binding)
            }
            receipt = refreshed.receipt
            message = refreshed.message
            if refreshed.receipt == nil { self.binding = nil }
        } catch {
            receipt = nil
            self.binding = nil
            if !(error is WindowsProfilePartialChange) { appliedBelowMinimum = false }
            message = Self.failureMessage(error)
        }
    }

    /// 908606e9 m3: a verified set stands even if the follow-up inspect fails; the message keeps what was applied
    /// and adds that the refresh failed. `appliedBelowMinimum` is the set's and isn't touched here.
    static func refreshAfterSet<Receipt>(applied: String, inspect: () async throws -> Receipt)
        async -> (receipt: Receipt?, message: String) {
        do { return (try await inspect(), applied) }
        catch { return (nil, applied + " The Windows profile couldn't be refreshed afterwards; use Refresh to read it again.") }
    }

    private static func failureMessage(_ error: Error) -> String {
        Logger(subsystem: "io.github.dragoshont.xodus", category: "WindowsProfile")
            .error("Windows profile operation: \(error.localizedDescription, privacy: .public)")
        if let error = error as? WindowsProfilePartialChange { return error.localizedDescription }
        if let error = error as? WindowsProfileFailure { return error.localizedDescription }
        if let error = error as? NativeLaunchError { return error.localizedDescription }
        if let error = error as? GameScriptError, case .busy = error {
            return "Your Library is busy. Finish its current operation, then refresh the Windows profile."
        }
        if error is EngineInspectionError {
            return "The Windows profile operation couldn't be completed. This app engine may need an update. Refresh the profile before trying again; no successful change is claimed."
        }
        return "The Windows profile result couldn't be read. Refresh the profile before trying again; no successful change is claimed."
    }
}

struct WindowsProfileSettings: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame
    @EnvironmentObject private var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WindowsProfileSettingsModel()
    @State private var selected: WindowsProfile?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Windows version for \(game.title)").font(.title2.weight(.semibold))
            if let receipt = model.receipt {
                Form {
                    LabeledContent("Engine", value: InstalledGamesController.readableEngineName(receipt.engine.name))
                    LabeledContent("Reported Windows version", value: receipt.effective?.label ?? "Not reported")
                    if let minimum = receipt.packageRequiredMinimum {
                        LabeledContent("Game requires", value: "Windows build \(minimum)")
                    }
                    Picker("Windows version profile", selection: $selected) {
                        Text("Choose a profile").tag(Optional<WindowsProfile>.none)
                        ForEach(receipt.supportedProfiles ?? []) { profile in Text(profile.label).tag(Optional(profile)) }
                    }
                }.formStyle(.grouped)
                if let block = receipt.changeBlock(for: selected) {
                    Text(block.localizedDescription).foregroundStyle(.secondary)
                } else if library.runningGameID != nil {
                    Text("Quit the running game before applying a Windows profile.").foregroundStyle(.secondary)
                } else if library.mutationActive {
                    Text("Wait for the current Library operation to finish before applying a Windows profile.")
                        .foregroundStyle(.secondary)
                }
                if receipt.meetsPackageMinimum == false {
                    Label("This prefix reports a Windows build below the game's minimum.", systemImage: "exclamationmark.triangle")
                }
                if let selected, let minimum = receipt.packageRequiredMinimum, selected.build < minimum {
                    Label("The selected profile is below the game's minimum Windows build. The game may refuse to start.",
                          systemImage: "exclamationmark.triangle")
                }
                Button("Apply Windows profile…") { confirming = true }
                    .disabled(model.busy || selected == nil || receipt.changeBlock(for: selected) != nil
                              || library.runningGameID != nil || library.mutationActive)
            }
            if model.busy { ProgressView(model.changing ? "Applying Windows profile" : "Reading Windows profile") }
            if let message = model.message { Text(message).fixedSize(horizontal: false, vertical: true) }
            if model.appliedBelowMinimum {
                Label("The requested profile is below the game's minimum Windows build. The game may refuse to start.",
                      systemImage: "exclamationmark.triangle")
            }
            Text("Only Apply changes an existing prefix. This uses the engine's supported Windows profile, not manual registry edits.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh") { Task { await load() } }.disabled(model.busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.changing)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(model.changing)
        .task { await load() }
        .confirmationDialog("Change the Windows profile for \(game.title)?", isPresented: $confirming) {
            Button("Apply \(selected?.label ?? "profile")") {
                guard let selected, let configuration = session.nativeInstallStatusConfiguration else {
                    model.unavailable()
                    return
                }
                Task { await model.apply(selected, game: game, library: library, configuration: configuration) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the existing prefix through its engine. It doesn't create a fresh prefix. Save files are checked by the engine before success is reported.")
        }
    }

    private func load() async {
        selected = nil
        guard let configuration = session.nativeInstallStatusConfiguration else {
            model.unavailable()
            return
        }
        await model.load(game: game, library: library, configuration: configuration)
    }
}

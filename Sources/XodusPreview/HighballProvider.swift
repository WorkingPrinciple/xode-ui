import AppKit
import Foundation
import Security
import SwiftUI

/// Highball as a user-installed, read-only engine provider. Qualification comes only from the
/// backend `highball-inspect` contract; this file never decides it.
enum HighballState: Equatable {
    case missing
    /// App present. `blocker` is the backend error code, or nil when no backend verdict is available.
    case detected(version: String?, blocker: String?)
    case qualified(version: String?, productID: String)

    var statusText: String {
        switch self {
        case .missing: "Not Installed"
        case .detected(_, let blocker): blocker == nil ? "Detected" : "Not Qualified"
        case .qualified: "Qualified"
        }
    }
    var isQualified: Bool { if case .qualified = self { true } else { false } }
    var offersGet: Bool { self == .missing }
}

enum HighballContract {
    static let bundleID = "app.highball.Highball"
    static let teamID = "B95M7DARU4"
    static let repository = URL(string: "https://github.com/gauthierpiarrette/highball")!
    static let applicationPath = "/Applications/Highball.app"
    static let engineID = "x64-crossover26.3-r27"
    /// The one title the backend `highball-inspect` contract can qualify (Brotato).
    static let qualifiedProductID = "9P9VNSQK1W3K"
    static let qualifiedTitle = "Brotato"
    static let maximumBytes = 65_536
    static let requirement = """
        identifier "app.highball.Highball" and anchor apple generic \
        and certificate leaf[subject.OU] = "B95M7DARU4"
        """

    private struct Candidate: Decodable { let version: String? }
    private struct Failure: Decodable { let code: String? }
    private struct Inspection: Decodable {
        let schemaVersion: Int
        let capability: String
        let state: String
        let qualified: Bool
        let admitted: Bool
        let ready: Bool
        let productID: String?
        let providerID: String?
        let candidate: Candidate?
        let error: Failure?
    }

    /// Strict decode of `highball-inspect` stdout. Anything inconsistent is never "qualified".
    /// When supplied, the requested product and the exit status (0 only when qualified) must agree.
    static func decode(_ data: Data, product: String? = nil, exitCode: Int32? = nil) -> HighballState? {
        guard data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(Inspection.self, from: data),
              value.schemaVersion == 1, value.capability == "highballAdmissionV1",
              value.providerID == "highball" else { return nil }
        if let product, value.productID != product { return nil }
        if let exitCode, (exitCode == 0) != (value.state == "qualified") { return nil }
        switch value.state {
        case "missing":
            return value.qualified || value.admitted || value.ready ? nil : .missing
        case "detected":
            guard !value.qualified, !value.admitted, !value.ready else { return nil }
            return .detected(version: value.candidate?.version, blocker: value.error?.code ?? "UNKNOWN")
        case "qualified":
            guard value.qualified, value.admitted, value.ready, value.error == nil,
                  let product = value.productID, !product.isEmpty else { return nil }
            return .qualified(version: value.candidate?.version, productID: product)
        default:
            return nil
        }
    }

    /// The backend verdict wins when it is available; otherwise the local read-only detection stands
    /// with no verdict, which is never shown as qualified.
    static func reconcile(local: HighballState, backend: HighballState?) -> HighballState {
        backend ?? local
    }

    /// Read-only presence check: identity and publisher signature, no execution, no writes.
    static func detect(at location: URL = URL(fileURLWithPath: applicationPath)) -> HighballState {
        var info = stat()
        guard lstat(location.path, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            return .detected(version: nil, blocker: "HIGHBALL_PATH_INVALID")
        }
        let plist = location.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist, options: .mappedIfSafe), data.count < 1_048_576,
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              dictionary["CFBundleIdentifier"] as? String == bundleID else {
            return .detected(version: nil, blocker: "HIGHBALL_IDENTITY_UNAVAILABLE")
        }
        let version = dictionary["CFBundleShortVersionString"] as? String
        var code: SecStaticCode?, required: SecRequirement?
        guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
              let required,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), required) == errSecSuccess
        else { return .detected(version: version, blocker: "HIGHBALL_SIGNATURE_INVALID") }
        return .detected(version: version, blocker: nil)
    }
}

extension HighballContract {
    static let engineName = "highball-x64-crossover26.3-r27"
    static let wineSha256 = "8cce786bce298f601a415f2e2952a82512c02243689df5b40e0af8e6e63991ca"
    static let wineserverSha256 = "7f842c62de7cb8a0409440cafa183d7177c820bc01d117683bd7d84f311d0709"

    static func engineRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Highball/engines/\(engineID)", isDirectory: true)
    }

    struct RegistryEntry: Codable, Equatable {
        struct Provider: Codable, Equatable { let id: String; let contract_version: Int }
        struct SmokeTest: Codable, Equatable { let status: String; let evidence: String }
        let name, kind, version, renderer, install_path, wine, wineserver, sha256, wineserver_sha256: String
        let provider: Provider
        let local_only: Bool
        let environment: [String: String]
        let smoke_test: SmokeTest
    }

    /// Registry bytes for a qualified verdict's own engine entry, checked against the pinned engine.
    /// The backend re-checks the entry at engine-inspect and again before launch.
    static func registryData(verdict: Data, product: String, exitCode: Int32,
                             home: String = NSHomeDirectory()) throws -> Data {
        guard case .qualified = decode(verdict, product: product, exitCode: exitCode) else {
            throw NativeLaunchError.providerNotAdmitted
        }
        struct Envelope: Decodable { let registryEntry: RegistryEntry }
        let entry = try JSONDecoder().decode(Envelope.self, from: verdict).registryEntry
        let root = engineRoot(home: home)
        guard entry.name == engineName, entry.provider == .init(id: "highball", contract_version: 1),
              entry.sha256 == wineSha256, entry.wineserver_sha256 == wineserverSha256,
              entry.install_path == root.path,
              entry.wine == root.appendingPathComponent("engine/bin/wine").path,
              entry.wineserver == root.appendingPathComponent("engine/bin/wineserver").path,
              entry.environment.count <= 32 else { throw NativeLaunchError.providerNotAdmitted }
        struct Registry: Encodable {
            let schema_version = 1
            let blocked: [String] = []
            let engines: [RegistryEntry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(Registry(engines: [entry]))
    }
}

enum HighballCopy {
    static func blockerText(_ code: String?) -> String? {
        switch code {
        case "HIGHBALL_SIGNATURE_INVALID": "Signature couldn't be verified"
        case "HIGHBALL_PATH_INVALID", "HIGHBALL_IDENTITY_UNAVAILABLE": "Not a usable Highball app"
        default: nil
        }
    }
    static let explanation = "Highball is a separate app you install yourself. \(AppBrand.displayName) only reads it and never installs or changes it."
    static let license = "Highball is GPL-3.0 and is not part of \(AppBrand.displayName). Its Wine and graphics components are separately licensed; \(AppBrand.displayName) doesn't accept their licences for you."
    static func detail(_ state: HighballState) -> String? {
        switch state {
        case .missing: nil
        case .detected(let version, let blocker):
            [version, blocker == nil ? "Not qualified" : blockerText(blocker)]
                .compactMap { $0 }.joined(separator: " · ")
        case .qualified(let version, let product):
            [version, product == HighballContract.qualifiedProductID
                ? "Qualified for \(HighballContract.qualifiedTitle) only" : "Qualified for one title"]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

struct HighballRow: View {
    var state: HighballState

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 10) {
                    Text([state.statusText, HighballCopy.detail(state)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if state.offersGet {
                        Link("Get Highball", destination: HighballContract.repository)
                            .accessibilityIdentifier("xodus.engines.highball.get")
                    }
                }
            }
        } header: {
            Text("Highball")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(HighballCopy.explanation)
                Text(HighballCopy.license)
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("xodus.engines.highball.explanation")
        }
    }
}

/// Detects off the main thread; the verdict stays "Detected" until a backend inspection supplies one.
struct HighballSection: View {
    /// Backend `highball-inspect`; nil or a nil result means no verdict is available.
    var inspect: (@MainActor () async -> HighballState?)? = nil
    var refreshID = 0
    @State private var state: HighballState = .missing

    var body: some View {
        HighballRow(state: state)
            .task(id: refreshID) {
                let local = await Task.detached(priority: .utility) { HighballContract.detect() }.value
                guard !Task.isCancelled else { return }
                state = local
                guard let inspect else { return }
                let verdict = await inspect()
                guard !Task.isCancelled else { return }
                state = HighballContract.reconcile(local: local, backend: verdict)
            }
    }
}

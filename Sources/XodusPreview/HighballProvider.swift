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
    static func decode(_ data: Data) -> HighballState? {
        guard data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(Inspection.self, from: data),
              value.schemaVersion == 1, value.capability == "highballAdmissionV1",
              value.providerID == "highball" else { return nil }
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

enum HighballCopy {
    static let explanation = "Highball is a separate app you install yourself. X Ode only reads it and never installs, changes, or switches to it. It is used only for titles the backend has qualified."
    static let license = "Highball is GPL-3.0 and is not part of X Ode. Its Wine and graphics components are separately licensed; Apple's Game Porting Toolkit is not accepted."
    static func detail(_ state: HighballState) -> String? {
        switch state {
        case .missing: nil
        case .detected(let version, let blocker):
            [version, blocker == nil ? "Not yet qualified for X Ode" : "Not qualified for this title"]
                .compactMap { $0 }.joined(separator: " · ")
        case .qualified(let version, _): [version, "One qualified title"].compactMap { $0 }.joined(separator: " · ")
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
    @State private var state: HighballState = .missing

    var body: some View {
        HighballRow(state: state)
            .task { state = await Task.detached(priority: .utility) { HighballContract.detect() }.value }
    }
}

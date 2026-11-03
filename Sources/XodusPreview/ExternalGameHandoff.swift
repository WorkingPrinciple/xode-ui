// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Security

/// Provider-owned launchers are not Wine engine admissions or Xbox launch recipes.
enum ExternalGameProvider: String, Codable, CaseIterable, Sendable {
    case highball, portingKit, heroic

    var label: String {
        switch self {
        case .highball: "Highball"
        case .portingKit: "Porting Kit"
        case .heroic: "Heroic Games Launcher"
        }
    }
    var applicationName: String { self == .heroic ? "Heroic" : label }
    var bundleIdentifier: String {
        switch self {
        case .highball: "app.highball.Highball"
        case .portingKit: "com.paulthetall.portingkit"
        case .heroic: "com.heroicgameslauncher.hgl"
        }
    }
    var signingRequirement: String {
        let team = switch self {
        case .highball: "B95M7DARU4"
        case .portingKit: "45WEPZ3433"
        case .heroic: "DLB2RYLUDX"
        }
        return """
            identifier "\(bundleIdentifier)" and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(team)"
            """
    }
    var website: URL {
        switch self {
        case .highball: URL(string: "https://github.com/gauthierpiarrette/highball")!
        case .portingKit: URL(string: "https://www.portingkit.com/download")!
        case .heroic: URL(string: "https://heroicgameslauncher.com/")!
        }
    }
}

enum ExternalHandoffError: Error, LocalizedError {
    case invalidLink, invalidHeroicLink, invalidWrapper, appMissing, appUnverified, noSelection

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            "Use a Highball game link for Steam, Epic or an existing pinned program. Launcher-install links, credentials, query parameters and command arguments aren't accepted."
        case .invalidHeroicLink:
            "Use a Heroic launch link with an explicit store runner (legendary, gog, nile or sideload) and game ID. Extra arguments, alternate executables, credentials and unspecified stores aren't accepted."
        case .invalidWrapper:
            "Choose an existing Porting Kit game app with a WineskinLauncher executable and its own Wine prefix. The app must remain at its selected location."
        case .appMissing:
            "The external app isn't installed in Applications. Install it from its official website, configure your game there, then try again."
        case .appUnverified:
            "The external app's identity or signature couldn't be checked. Restore the official app before trying again."
        case .noSelection:
            "No external game is configured. Choose the game's existing Highball or Heroic link, or Porting Kit wrapper first."
        }
    }
}

struct ExternalApplication: Equatable, Sendable {
    let location: URL
    let version: String
}

enum ExternalApplicationState: Equatable, Sendable {
    case notChecked, checking, missing, unverified
    case detected(ExternalApplication)

    var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking"
        case .missing: "Not found in Applications"
        case .unverified: "App identity could not be checked"
        case .detected(let app): "App detected: \(app.version)"
        }
    }
}

enum ExternalApplicationDetector {
    static func detect(_ provider: ExternalGameProvider) -> ExternalApplicationState {
        let locations = [
            URL(fileURLWithPath: "/Applications/\(provider.applicationName).app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(provider.applicationName).app")
        ]
        var unverified = false
        for location in locations {
            let state = inspect(location, provider: provider)
            if case .detected = state { return state }
            if state == .unverified { unverified = true }
        }
        return unverified ? .unverified : .missing
    }

    static func inspect(_ location: URL, provider: ExternalGameProvider) -> ExternalApplicationState {
        guard FileManager.default.fileExists(atPath: location.path) else { return .missing }
        do {
            let fields = try applicationMetadata(location)
            guard fields["CFBundleIdentifier"] as? String == provider.bundleIdentifier,
                  let version = fields["CFBundleShortVersionString"] as? String,
                  validText(version, maximum: 64) else { return .unverified }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess,
                  let code else { return .unverified }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(provider.signingRequirement as CFString, [], &requirement)
                == errSecSuccess, let requirement else { return .unverified }
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return .unverified }
            return .detected(.init(location: location, version: version))
        } catch { return .unverified }
    }

    static func applicationMetadata(_ location: URL) throws -> [String: Any] {
        guard location.isFileURL, location.pathExtension == "app",
              location.standardizedFileURL == location,
              location.resolvingSymlinksInPath() == location else { throw ExternalHandoffError.appUnverified }
        try GameScriptFiles.checkPath(location)
        let metadata = location.appendingPathComponent("Contents/Info.plist")
        try GameScriptFiles.checkPath(metadata)
        let bytes = try InstalledGameFiles.readRegular(metadata, maximumBytes: 65_536)
        guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              fields["CFBundlePackageType"] as? String == "APPL",
              let executable = fields["CFBundleExecutable"] as? String,
              validText(executable, maximum: 255), !executable.contains("/"),
              executable != ".", executable != ".." else { throw ExternalHandoffError.appUnverified }
        let binary = location.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        try GameScriptFiles.checkPath(binary)
        try InstalledGameFiles.checkLauncher(binary)
        return fields
    }

    static func validText(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct ExternalGameHandoff: Codable, Equatable, Sendable {
    let provider: ExternalGameProvider
    let target: String

    func validate() throws {
        switch provider {
        case .highball: _ = try Self.highballURL(target)
        case .heroic: _ = try Self.heroicURL(target)
        case .portingKit:
            guard target.hasPrefix("/"), target.utf8.count <= 4_096,
                  !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  URL(fileURLWithPath: target).pathExtension == "app" else {
                throw ExternalHandoffError.invalidWrapper
            }
        }
    }

    // The installed Highball 0.10.22 contract supports these three game targets.
    // No launch-token is read: Highball keeps its normal confirmation boundary.
    static func highballURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 2_048,
              let parts = URLComponents(string: text), parts.scheme == "highball", parts.host == "play",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("//") else { throw ExternalHandoffError.invalidLink }
        let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "", segments.count >= 3 else { throw ExternalHandoffError.invalidLink }
        let decoded = try segments.dropFirst().map { segment -> String in
            guard let value = String(segment).removingPercentEncoding,
                  ExternalApplicationDetector.validText(value, maximum: 512),
                  !value.contains("/"), !value.contains("\\"),
                  value != ".", value != ".." else { throw ExternalHandoffError.invalidLink }
            return value
        }
        switch decoded[0] {
        case "steam":
            guard decoded.count == 2, decoded[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let appID = Int(decoded[1]), appID > 0 else { throw ExternalHandoffError.invalidLink }
        case "epic":
            guard decoded.count == 2 else { throw ExternalHandoffError.invalidLink }
        case "pin":
            guard decoded.count == 3, UUID(uuidString: decoded[2]) != nil else {
                throw ExternalHandoffError.invalidLink
            }
        default: throw ExternalHandoffError.invalidLink
        }
        guard let url = parts.url else { throw ExternalHandoffError.invalidLink }
        return url
    }

    static func portingKitWrapper(_ location: URL) throws -> URL {
        do {
            let fields = try ExternalApplicationDetector.applicationMetadata(location)
            guard fields["CFBundleExecutable"] as? String == "WineskinLauncher" else {
                throw ExternalHandoffError.invalidWrapper
            }
            let prefixes = ["Contents/SharedSupport/prefix", "Contents/Resources"]
            guard prefixes.contains(where: { RunnerAvailabilityDetector.isPrefix(location.appendingPathComponent($0)) })
            else { throw ExternalHandoffError.invalidWrapper }
            return location
        } catch { throw ExternalHandoffError.invalidWrapper }
    }

    static func heroicURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 2_048,
              let parts = URLComponents(string: text), parts.scheme == "heroic", parts.host == "launch",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else { throw ExternalHandoffError.invalidHeroicLink }
        let runner: String
        let gameID: String
        if parts.path.isEmpty || parts.path == "/" {
            guard let items = parts.queryItems, items.count == 2,
                  Set(items.map(\.name)) == ["appName", "runner"],
                  let appName = items.first(where: { $0.name == "appName" })?.value,
                  let store = items.first(where: { $0.name == "runner" })?.value else {
                throw ExternalHandoffError.invalidHeroicLink
            }
            runner = store
            gameID = appName
        } else {
            let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.query == nil, segments.count == 3, segments[0] == "" else {
                throw ExternalHandoffError.invalidHeroicLink
            }
            runner = String(segments[1])
            gameID = String(segments[2])
        }
        guard ["legendary", "gog", "nile", "sideload"].contains(runner),
              ExternalApplicationDetector.validText(gameID, maximum: 512),
              gameID != ".", gameID != "..",
              gameID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              let url = URL(string: "heroic://launch/\(runner)/\(gameID)") else {
            throw ExternalHandoffError.invalidHeroicLink
        }
        return url
    }

    @MainActor func open(isCurrent: @MainActor () -> Bool) async throws {
        try validate()
        switch provider {
        case .highball, .heroic:
            let provider = provider
            let state = await Task.detached(priority: .utility) {
                ExternalApplicationDetector.detect(provider)
            }.value
            guard case .detected(let app) = state else {
                throw state == .missing ? ExternalHandoffError.appMissing : ExternalHandoffError.appUnverified
            }
            let url = try provider == .highball ? Self.highballURL(target) : Self.heroicURL(target)
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.location,
                                                  configuration: NSWorkspace.OpenConfiguration())
        case .portingKit:
            let target = target
            let wrapper = try await Task.detached(priority: .utility) {
                try Self.portingKitWrapper(URL(fileURLWithPath: target))
            }.value
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            // Launch the selected wrapper normally; Gatekeeper and provider prompts remain in charge.
            _ = try await NSWorkspace.shared.openApplication(at: wrapper, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

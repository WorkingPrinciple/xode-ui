// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import Security
import SwiftUI

struct CrossOverInstallation: Equatable, Sendable {
    let location: URL
    let version: String
    let buildVersion: String
}

enum CrossOverDependencyState: Equatable, Sendable {
    case notChecked, checking, absent, unverified
    case installed(CrossOverInstallation)

    var isVerified: Bool {
        if case .installed = self { return true }
        return false
    }
    static let trialDownloadURL = URL(string: "https://www.codeweavers.com/crossover")!

    var offersTrialDownload: Bool { self == .absent || self == .unverified }

    var title: String {
        switch self {
        case .notChecked: "CrossOver installation not checked"
        case .checking: "Checking the CrossOver app"
        case .absent: "CrossOver is not installed"
        case .unverified: "CrossOver installation could not be verified"
        case .installed(let app): "Official CrossOver \(app.version) detected"
        }
    }

    var explanation: String {
        switch self {
        case .notChecked, .checking:
            "Only approved app locations and signed bundle metadata are checked. No license, bottle, game or save is inspected."
        case .absent:
            "CrossOver is needed only for games configured to use it. Get the official app from CodeWeavers, then check again. Other engine routes remain separate; this check does not establish a license or game compatibility."
        case .unverified:
            "The app location, bounded metadata or approved publisher signature could not be verified. Install the official app and check again; this does not say whether you own a license."
        case .installed(let app):
            "App build \(app.buildVersion) has the approved signature. This does not verify its license or any game's compatibility. Game readiness is checked separately; \(AppBrand.displayName) does not bundle CrossOver."
        }
    }
}

enum CrossOverDetector {
    static let identifier = "com.codeweavers.CrossOver"
    static let publisherTeam = "9C6B7X7Z8E"
    // Pinned from the user's approved official installation, not candidate metadata.
    static let requirement = """
        identifier "com.codeweavers.CrossOver" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "9C6B7X7Z8E"
        """

    static func detect() -> CrossOverDependencyState {
        if let path = EngineDefaults.crossOverApplication() {
            return inspect(URL(fileURLWithPath: path))
        }
        let locations = candidateLocations(
            registered: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier))
        var sawUnverified = false
        for location in locations {
            let state = inspect(location)
            if state.isVerified { return state }
            if state == .unverified { sawUnverified = true }
        }
        return sawUnverified ? .unverified : .absent
    }

    /// Registered bundle locations first, so a renamed or moved app is found by identity,
    /// then the conventional Applications folders. Bounded and deduplicated.
    static func candidateLocations(registered: [URL],
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var seen = Set<String>()
        return (registered.prefix(8).map(\.standardizedFileURL)
            + [URL(fileURLWithPath: "/Applications/CrossOver.app"),
               home.appendingPathComponent("Applications/CrossOver.app")])
            .filter { seen.insert($0.path).inserted }
    }

    static func inspect(_ location: URL) -> CrossOverDependencyState {
        var before = stat()
        guard lstat(location.path, &before) == 0 else {
            return errno == ENOENT ? .absent : .unverified
        }
        guard location.isFileURL, location.standardizedFileURL == location,
              location.resolvingSymlinksInPath() == location,
              before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == 0 || before.st_uid == getuid(), before.st_mode & 0o022 == 0 else {
            return .unverified
        }
        do {
            let metadata = location.appendingPathComponent("Contents/Info.plist")
            let data = try readMetadata(metadata)
            var code: SecStaticCode?
            var required: SecRequirement?
            guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
                  let required else { return .unverified }
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            let trusted = SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess
            var after = stat()
            guard lstat(location.path, &after) == 0, before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino, before.st_mode == after.st_mode,
                  before.st_uid == after.st_uid,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  data == (try readMetadata(metadata)) else { return .unverified }
            return evaluate(metadata: data, signatureTrusted: trusted, location: location)
        } catch { return .unverified }
    }

    static func evaluate(metadata: Data, signatureTrusted: Bool, location: URL) -> CrossOverDependencyState {
        guard signatureTrusted, !metadata.isEmpty, metadata.count <= 65_536,
              let value = try? PropertyListSerialization.propertyList(from: metadata, format: nil),
              let fields = value as? [String: Any],
              fields["CFBundleIdentifier"] as? String == identifier,
              fields["CFBundlePackageType"] as? String == "APPL",
              let version = fields["CFBundleShortVersionString"] as? String,
              let build = fields["CFBundleVersion"] as? String,
              validVersion(version), validVersion(build) else {
            return .unverified
        }
        return .installed(.init(location: location, version: version, buildVersion: build))
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e }
    }

    private static func readMetadata(_ path: URL) throws -> Data {
        guard path.resolvingSymlinksInPath() == path else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == 0 || before.st_uid == getuid(), before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65_537) ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, bytes.count == before.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}

struct RuntimeDependencyStatus: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var allowsCheck = true
    var offersSettings = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(settings.crossOverDependency.title, systemImage: settings.crossOverDependency.isVerified
                  ? "shippingbox" : "exclamationmark.circle")
                .font(.headline).accessibilityIdentifier("ode.runtime.dependency")
            if settings.crossOverDependency == .checking { ProgressView("Checking app signature").controlSize(.small) }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            DisclosureGroup("Runtime information") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(settings.crossOverDependency.explanation)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Use the engine required by the game's launch recipe. Detecting an engine does not qualify it for every game; graphics toolkits are separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private var actions: some View {
        Group {
            Button("Check CrossOver app") { Task { await settings.refreshCrossOverDependency() } }
                .disabled(!allowsCheck || settings.checkingDependency || settings.applicationTerminating || settings.planning)
            if !settings.crossOverDependency.isVerified {
                Link("Install CrossOver or start a trial",
                     destination: CrossOverDependencyState.trialDownloadURL).accessibleLink()
                    .accessibilityIdentifier("ode.runtime.installCrossOver")
                Text("Opens CodeWeavers in your browser. Install CrossOver in Applications, then return here. \(AppBrand.displayName) checks again when you return; licensing stays with CodeWeavers.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if offersSettings { Button("Open Settings", action: openSettings.callAsFunction) }
        }
    }
}

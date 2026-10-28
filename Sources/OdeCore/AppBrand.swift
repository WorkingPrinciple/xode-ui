// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The one source for user-visible product identity.
///
/// Display strings only: bundle identifiers, executables, module names, preference keys,
/// Keychain service identifiers and file-system paths keep their historical Ode names.
public enum AppBrand {
    public static let displayName = "X Ode"
    /// The word set beneath the X mark in the logo lockup; the lockup as a whole reads "X Ode".
    public static let wordmark = "Ode"
    public static let company = "Working Principle"
    /// Not shown anywhere until the domain resolves; kept here for when it's live.
    public static let website = "xode.win"
    /// The running app's version, read from its bundle. Nothing here hard-codes a version number.
    public static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary) }
    public static var channel: String { current.channel }

    /// "X Ode Beta"
    public static var nameWithChannel: String { "\(displayName) \(channel)" }
    /// "0.2.0 (Beta)", or "Development build" for an unpackaged run.
    public static var versionLabel: String { current.label }
    /// "© Working Principle"
    public static var copyright: String { "© \(company)" }
    public static var supportTitle: String { "\(nameWithChannel) Support" }

    /// Earlier display names that must not appear in user-visible copy.
    public static let retiredNames = ["Ode to X", "Ode to X Local Candidate", "X-Ode", "Xode"]
}

/// Version facts from a bundle's Info.plist. Packaging writes them; X Ode only reads them.
/// - CFBundleShortVersionString: X Ode's own version, three integers (e.g. 0.2.0), independent of Wine and GPTK.
/// - CFBundleVersion: build number, digits only, increasing on every build.
/// - XodeReleaseChannel: "Beta" (defaults to Beta when absent).
public struct AppVersion: Equatable, Sendable {
    public static let developmentLabel = "Development build"
    public let version: String?
    public let build: String?
    public let channel: String

    public init(info: [String: Any]?) {
        let version = info?["CFBundleShortVersionString"] as? String
        self.version = version.flatMap { $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil ? $0 : nil }
        let build = info?["CFBundleVersion"] as? String
        self.build = build.flatMap { $0.range(of: #"^[0-9]{1,9}$"#, options: .regularExpression) != nil ? $0 : nil }
        let channel = (info?["XodeReleaseChannel"] as? String)?.trimmingCharacters(in: .whitespaces)
        self.channel = channel.flatMap {
            $0.range(of: #"^[A-Za-z][A-Za-z0-9 ]{0,19}$"#, options: .regularExpression) != nil ? $0 : nil
        } ?? "Beta"
    }

    /// "0.2.0 (Beta)" for Settings and Support.
    public var label: String { version.map { "\($0) (\(channel))" } ?? Self.developmentLabel }
    /// "0.2.0 Beta" for the About panel, which adds the build number as "(412)".
    public var aboutVersion: String { version.map { "\($0) \(channel)" } ?? Self.developmentLabel }
}

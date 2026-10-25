// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The one source for user-visible product identity.
///
/// Display strings only: bundle identifiers, executables, module names, preference keys,
/// Keychain service identifiers and file-system paths keep their historical Xodus names.
public enum AppBrand {
    public static let displayName = "Xode"
    public static let company = "Working Principle"
    public static let website = "xode.win"
    public static let version = "0.11.4"
    public static let channel = "Beta"

    /// "Xode Beta"
    public static var nameWithChannel: String { "\(displayName) \(channel)" }
    /// "0.11.4 Beta"
    public static var versionLabel: String { "\(version) \(channel)" }
    /// "© Working Principle · xode.win"
    public static var copyright: String { "© \(company) · \(website)" }
    public static var supportTitle: String { "\(nameWithChannel) Support" }

    /// Earlier display names that must not appear in user-visible copy.
    public static let retiredNames = ["Ode to X", "Ode to X Local Candidate", "X-Ode"]
}

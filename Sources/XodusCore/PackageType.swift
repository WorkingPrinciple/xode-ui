// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The detected Microsoft Store / Windows package family of an installed game.
///
/// This is a neutral *format* fact derived from on-disk package, manifest and
/// file evidence — never a capability or support verdict. Detecting a type says
/// nothing about whether Xodus can install or run that title.
public enum PackageType: String, Codable, Sendable, CaseIterable {
    case msixvc, win32, appx, eappx, uwp, unknown

    public var label: String {
        switch self {
        case .msixvc: "MSIXVC"
        case .win32: "Win32"
        case .appx: "Appx"
        case .eappx: "EAppx"
        case .uwp: "UWP"
        case .unknown: "Unknown"
        }
    }
}

/// Serializable facts gathered from an installed game folder. This is the only
/// input to `PackageType.classify`; keeping it a pure value makes classification
/// deterministic and fixture-testable without touching the filesystem.
public struct PackageTypeEvidence: Equatable, Codable, Sendable {
    /// A root `MicrosoftGame.config` exists. This does not establish a container format.
    public var hasMicrosoftGameConfig: Bool
    public var hasMSIXVCHeader: Bool
    /// An `AppxManifest.xml` exists (packaged MSIX/APPX/UWP app).
    public var hasAppxManifest: Bool
    /// A bounded encrypted-APPX header was observed; a filename is not evidence.
    public var encryptedPackageMarker: Bool
    /// Target device families declared by the manifest's `<Dependencies>`.
    public var targetDeviceFamilies: [String]
    /// The manifest declares a full-trust application (`Windows.FullTrustApplication`,
    /// a `runFullTrust` restricted capability, or a `desktop:` extension). Such a
    /// package is a packaged Win32 app, not a sandboxed UWP app.
    public var declaresFullTrustEntryPoint: Bool
    public var declaresUWPApplication: Bool
    /// A plain Win32 PE executable is present without packaging metadata.
    public var hasWin32Executable: Bool

    public init(hasMicrosoftGameConfig: Bool = false, hasMSIXVCHeader: Bool = false, hasAppxManifest: Bool = false,
                encryptedPackageMarker: Bool = false, targetDeviceFamilies: [String] = [],
                declaresFullTrustEntryPoint: Bool = false, declaresUWPApplication: Bool = false,
                hasWin32Executable: Bool = false) {
        self.hasMicrosoftGameConfig = hasMicrosoftGameConfig
        self.hasMSIXVCHeader = hasMSIXVCHeader
        self.hasAppxManifest = hasAppxManifest
        self.encryptedPackageMarker = encryptedPackageMarker
        self.targetDeviceFamilies = targetDeviceFamilies
        self.declaresFullTrustEntryPoint = declaresFullTrustEntryPoint
        self.declaresUWPApplication = declaresUWPApplication
        self.hasWin32Executable = hasWin32Executable
    }

    enum CodingKeys: String, CodingKey {
        case hasMicrosoftGameConfig, hasMSIXVCHeader, hasAppxManifest, encryptedPackageMarker
        case targetDeviceFamilies, declaresFullTrustEntryPoint, declaresUWPApplication, hasWin32Executable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasMicrosoftGameConfig = try values.decode(Bool.self, forKey: .hasMicrosoftGameConfig)
        hasMSIXVCHeader = try values.decodeIfPresent(Bool.self, forKey: .hasMSIXVCHeader) ?? false
        hasAppxManifest = try values.decode(Bool.self, forKey: .hasAppxManifest)
        encryptedPackageMarker = try values.decode(Bool.self, forKey: .encryptedPackageMarker)
        targetDeviceFamilies = try values.decode([String].self, forKey: .targetDeviceFamilies)
        declaresFullTrustEntryPoint = try values.decode(Bool.self, forKey: .declaresFullTrustEntryPoint)
        declaresUWPApplication = try values.decodeIfPresent(Bool.self, forKey: .declaresUWPApplication) ?? false
        hasWin32Executable = try values.decode(Bool.self, forKey: .hasWin32Executable)
    }
}

extension PackageType {
    /// Pure classification from gathered evidence. Precedence is strongest-signal
    /// first: container header, encrypted package, application-model manifest,
    /// then a verified Win32 executable. GDK configuration and device targeting
    /// alone establish neither a container format nor an application model.
    public static func classify(_ evidence: PackageTypeEvidence) -> PackageType {
        if evidence.hasMSIXVCHeader { return .msixvc }
        if evidence.encryptedPackageMarker { return .eappx }
        if evidence.hasAppxManifest {
            return evidence.declaresUWPApplication && !evidence.declaresFullTrustEntryPoint ? .uwp : .appx
        }
        if evidence.hasWin32Executable { return .win32 }
        return .unknown
    }

    public static func hasMSIXVCHeader(_ bytes: Data) -> Bool {
        bytes.count >= 4096 && bytes.subdata(in: 0x200..<0x208) == Data("msft-xvd".utf8)
    }

    public static func hasPEHeader(_ bytes: Data) -> Bool {
        guard bytes.count >= 64, bytes.prefix(2) == Data([0x4d, 0x5a]) else { return false }
        let offset = (0..<4).reduce(0) { $0 | (Int(bytes[0x3c + $1]) << ($1 * 8)) }
        guard offset >= 64, offset <= bytes.count - 4 else { return false }
        return bytes.subdata(in: offset..<(offset + 4)) == Data([0x50, 0x45, 0, 0])
    }

    /// Signature recognition only, not decryption, signature or package-integrity verification.
    public static func hasEncryptedAppxHeader(_ bytes: Data) -> Bool {
        guard bytes.count >= 64, bytes.prefix(4) == Data("EXPH".utf8) else { return false }
        let headerSize = Int(bytes[4]) | (Int(bytes[5]) << 8)
        return headerSize >= 64 && headerSize <= bytes.count
    }
}

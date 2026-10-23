// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

public enum RuntimeProviderKind: String, CaseIterable, Codable, Sendable {
    case gptk3, gptk4, crossover, standaloneWine

    public var label: String {
        switch self {
        case .gptk3: "Apple GPTK3"
        case .gptk4: "Apple GPTK4"
        case .crossover: "User-installed CrossOver"
        case .standaloneWine: "Standalone / source-built Wine"
        }
    }
}

public enum RuntimeEngineProvenance: String, CaseIterable, Codable, Sendable {
    case appleToolkit, userInstalledCrossOver, userSelectedWine, userSelectedSourceBuild

    public var label: String {
        switch self {
        case .appleToolkit: "Apple toolkit"
        case .userInstalledCrossOver: "User-installed CrossOver"
        case .userSelectedWine: "User-selected Wine"
        case .userSelectedSourceBuild: "User-selected source build"
        }
    }
}

public enum RuntimeGraphicsBackend: String, CaseIterable, Codable, Sendable {
    case d3dMetal, dxvk, wineD3d

    public var label: String {
        switch self {
        case .d3dMetal: "D3DMetal"
        case .dxvk: "DXVK"
        case .wineD3d: "WineD3D"
        }
    }
}

public enum RuntimeGraphicsProvenance: String, CaseIterable, Codable, Sendable {
    case appleToolkit, crossOverBundled, engineBundled, userSelected
}

public struct RuntimeEngineConfiguration: Equatable, Codable, Sendable {
    public var kind = "wine"
    public var provenance: RuntimeEngineProvenance
    public var version: String?
    public var artifactSha256: String?

    public init(
        provenance: RuntimeEngineProvenance, version: String? = nil, artifactSha256: String? = nil
    ) {
        self.provenance = provenance
        self.version = version
        self.artifactSha256 = artifactSha256
    }

    enum CodingKeys: String, CodingKey { case kind, provenance, version, artifactSha256 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        provenance = try values.decode(RuntimeEngineProvenance.self, forKey: .provenance)
        version = try values.decode(String?.self, forKey: .version)
        artifactSha256 = try values.decode(String?.self, forKey: .artifactSha256)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(provenance, forKey: .provenance)
        try values.encode(version, forKey: .version)
        try values.encode(artifactSha256, forKey: .artifactSha256)
    }
}

public struct RuntimeGraphicsConfiguration: Equatable, Codable, Sendable {
    public var backend: RuntimeGraphicsBackend?
    public var provenance: RuntimeGraphicsProvenance?
    public var version: String?
    public var artifactSha256: String?

    public init(
        backend: RuntimeGraphicsBackend? = nil, provenance: RuntimeGraphicsProvenance? = nil,
        version: String? = nil, artifactSha256: String? = nil
    ) {
        self.backend = backend
        self.provenance = provenance
        self.version = version
        self.artifactSha256 = artifactSha256
    }

    enum CodingKeys: String, CodingKey { case backend, provenance, version, artifactSha256 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decode(RuntimeGraphicsBackend?.self, forKey: .backend)
        provenance = try values.decode(RuntimeGraphicsProvenance?.self, forKey: .provenance)
        version = try values.decode(String?.self, forKey: .version)
        artifactSha256 = try values.decode(String?.self, forKey: .artifactSha256)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backend, forKey: .backend)
        try values.encode(provenance, forKey: .provenance)
        try values.encode(version, forKey: .version)
        try values.encode(artifactSha256, forKey: .artifactSha256)
    }
}

public struct RuntimeProviderConfiguration: Equatable, Codable, Sendable {
    public var version = 1
    public var provider: RuntimeProviderKind
    public var providerVersion: String?
    public var engine: RuntimeEngineConfiguration
    public var graphics: RuntimeGraphicsConfiguration

    public init(
        provider: RuntimeProviderKind, providerVersion: String? = nil,
        engine: RuntimeEngineConfiguration, graphics: RuntimeGraphicsConfiguration
    ) {
        self.provider = provider
        self.providerVersion = providerVersion
        self.engine = engine
        self.graphics = graphics
    }

    public static func preset(_ provider: RuntimeProviderKind) -> Self {
        let provenance: RuntimeEngineProvenance =
            switch provider {
            case .gptk3, .gptk4: .appleToolkit
            case .crossover: .userInstalledCrossOver
            case .standaloneWine: .userSelectedWine
            }
        return Self(
            provider: provider, engine: .init(provenance: provenance),
            graphics: provider == .gptk3 || provider == .gptk4
                ? .init(backend: .d3dMetal, provenance: .appleToolkit) : .init())
    }

    enum CodingKeys: String, CodingKey { case version, provider, providerVersion, engine, graphics }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        provider = try values.decode(RuntimeProviderKind.self, forKey: .provider)
        providerVersion = try values.decode(String?.self, forKey: .providerVersion)
        engine = try values.decode(RuntimeEngineConfiguration.self, forKey: .engine)
        graphics = try values.decode(RuntimeGraphicsConfiguration.self, forKey: .graphics)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(provider, forKey: .provider)
        try values.encode(providerVersion, forKey: .providerVersion)
        try values.encode(engine, forKey: .engine)
        try values.encode(graphics, forKey: .graphics)
    }

    public func identity() throws -> String {
        func quoted(_ value: String?) throws -> String {
            guard let value else { return "null" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let bytes = try Data(
            ("""
            {"version":\(version),"provider":\(quoted(provider.rawValue)),"providerVersion":\(quoted(providerVersion)),"engine":{"kind":\(quoted(engine.kind)),"provenance":\(quoted(engine.provenance.rawValue)),"version":\(quoted(engine.version)),"artifactSha256":\(quoted(engine.artifactSha256))},"graphics":{"backend":\(quoted(graphics.backend?.rawValue)),"provenance":\(quoted(graphics.provenance?.rawValue)),"version":\(quoted(graphics.version)),"artifactSha256":\(quoted(graphics.artifactSha256))}}
            """).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RuntimeInstallationEvidence: String, Codable, Sendable { case notInspected }
public enum RuntimeDeviceEvidence: String, Codable, Sendable { case notPerformed }
public enum RuntimeGameEvidence: String, Codable, Sendable { case notVerified }

public struct RuntimeConfigurationPlan: Equatable, Codable, Sendable {
    public let version: Int
    public let configuration: RuntimeProviderConfiguration
    public let generationID: String
    public let prefixRelativePath: String
    public let installation: RuntimeInstallationEvidence
    public let devicePreflight: RuntimeDeviceEvidence
    public let gameVerification: RuntimeGameEvidence
    public let launchable: Bool
}

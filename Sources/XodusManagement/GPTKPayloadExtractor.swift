// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import XodusCore

public enum GPTKError: LocalizedError, Equatable {
    case fileNotFound(String)
    case notADiskImage(String)
    case mountFailed(String)
    case unmountFailed(String)
    case missingRedistributables(String)
    case extractionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .notADiskImage(let path):
            return "The selected file is not an Apple disk image (.dmg): \(path)"
        case .mountFailed(let reason):
            return "Failed to mount Apple Game Porting Toolkit image: \(reason)"
        case .unmountFailed(let reason):
            return "Failed to unmount disk image: \(reason)"
        case .missingRedistributables(let reason):
            return "The disk image is missing required GPTK components: \(reason)"
        case .extractionFailed(let reason):
            return "Failed to extract GPTK components: \(reason)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

public protocol GPTKProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data, stderr: Data)
}

public struct DefaultGPTKProcessRunner: GPTKProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                process.terminationHandler = { proc in
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    continuation.resume(returning: (proc.terminationStatus, outData, errData))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public struct GPTKInspection: Equatable, Sendable {
    public let dmgURL: URL?
    public let mountPoint: URL
    public let version: String
    public let frameworkURL: URL
    public let d3dsharedURL: URL
    public let licenseURL: URL
    public let licenseRTFData: Data
    public let requiresUnmount: Bool

    public init(
        dmgURL: URL?,
        mountPoint: URL,
        version: String,
        frameworkURL: URL,
        d3dsharedURL: URL,
        licenseURL: URL,
        licenseRTFData: Data,
        requiresUnmount: Bool
    ) {
        self.dmgURL = dmgURL
        self.mountPoint = mountPoint
        self.version = version
        self.frameworkURL = frameworkURL
        self.d3dsharedURL = d3dsharedURL
        self.licenseURL = licenseURL
        self.licenseRTFData = licenseRTFData
        self.requiresUnmount = requiresUnmount
    }
}

public struct GPTKExtractionReceipt: Equatable, Sendable {
    public let destinationURL: URL
    public let frameworkURL: URL
    public let d3dsharedURL: URL
    public let licenseURL: URL
    public let version: String
    public let date: Date
    public let sha256: String?

    public init(
        destinationURL: URL,
        frameworkURL: URL,
        d3dsharedURL: URL,
        licenseURL: URL,
        version: String,
        date: Date = Date(),
        sha256: String? = nil
    ) {
        self.destinationURL = destinationURL
        self.frameworkURL = frameworkURL
        self.d3dsharedURL = d3dsharedURL
        self.licenseURL = licenseURL
        self.version = version
        self.date = date
        self.sha256 = sha256
    }
}

public final class GPTKPayloadExtractor: Sendable {
    private let processRunner: GPTKProcessRunning

    public init(processRunner: GPTKProcessRunning = DefaultGPTKProcessRunner()) {
        self.processRunner = processRunner
    }

    private var fileManager: FileManager { FileManager.default }

    /// Inspects an Apple GPTK DMG or an already mounted volume.
    public func inspect(url: URL) async throws -> GPTKInspection {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw GPTKError.fileNotFound(url.path)
        }

        if isDir.boolValue {
            // Already a directory / volume
            return try inspectDirectory(url, dmgURL: nil, requiresUnmount: false)
        }

        guard url.pathExtension.lowercased() == "dmg" else {
            throw GPTKError.notADiskImage(url.path)
        }

        // Mount headlessly via hdiutil attach -nobrowse -readonly -plist <path>
        let result = try await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", url.path]
        )

        guard result.status == 0 else {
            let errorText = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GPTKError.mountFailed(errorText.isEmpty ? "Exit code \(result.status)" : errorText)
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw GPTKError.mountFailed("Could not parse hdiutil plist output.")
        }

        var mountPoint: String?
        for entity in entities {
            if let mount = entity["mount-point"] as? String {
                mountPoint = mount
                break
            }
        }

        guard let mountPoint, fileManager.fileExists(atPath: mountPoint) else {
            throw GPTKError.mountFailed("Mount point entity not found in disk image.")
        }

        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
        do {
            return try inspectDirectory(mountURL, dmgURL: url, requiresUnmount: true)
        } catch {
            _ = try? await detach(mountPoint: mountURL)
            throw error
        }
    }

    private func inspectDirectory(_ dir: URL, dmgURL: URL?, requiresUnmount: Bool) throws -> GPTKInspection {
        let frameworkCandidates = [
            dir.appendingPathComponent("redist/lib/external/D3DMetal.framework"),
            dir.appendingPathComponent("redist/external/D3DMetal.framework"),
            dir.appendingPathComponent("redist/D3DMetal.framework"),
            dir.appendingPathComponent("lib/external/D3DMetal.framework")
        ]

        guard let frameworkURL = frameworkCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw GPTKError.missingRedistributables("D3DMetal.framework not found in volume.")
        }

        let sharedLibCandidates = [
            dir.appendingPathComponent("redist/lib/external/libd3dshared.dylib"),
            dir.appendingPathComponent("redist/external/libd3dshared.dylib"),
            dir.appendingPathComponent("redist/libd3dshared.dylib"),
            dir.appendingPathComponent("lib/external/libd3dshared.dylib")
        ]

        guard let d3dsharedURL = sharedLibCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw GPTKError.missingRedistributables("libd3dshared.dylib not found in volume.")
        }

        let licenseCandidates = [
            dir.appendingPathComponent("License.rtf"),
            dir.appendingPathComponent("redist/License.rtf"),
            dir.appendingPathComponent("License.txt"),
            dir.appendingPathComponent("License.pdf")
        ]

        guard let licenseURL = licenseCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw GPTKError.missingRedistributables("License file not found in volume.")
        }

        let licenseData = try Data(contentsOf: licenseURL)

        var version = "4.0"
        let volName = dir.lastPathComponent
        if let match = volName.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) {
            version = String(volName[match])
        }

        return GPTKInspection(
            dmgURL: dmgURL,
            mountPoint: dir,
            version: version,
            frameworkURL: frameworkURL,
            d3dsharedURL: d3dsharedURL,
            licenseURL: licenseURL,
            licenseRTFData: licenseData,
            requiresUnmount: requiresUnmount
        )
    }

    /// Detaches the mounted disk image cleanly.
    public func detach(mountPoint: URL) async throws {
        let result = try await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path]
        )
        if result.status != 0 {
            let forceResult = try await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", "-force", mountPoint.path]
            )
            if forceResult.status != 0 {
                let err = String(decoding: forceResult.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw GPTKError.unmountFailed(err)
            }
        }
    }

    /// Extracts verified GPTK assets to target destination and cleans up.
    public func extract(
        inspection: GPTKInspection,
        destination: URL
    ) async throws -> GPTKExtractionReceipt {
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            let destFramework = destination.appendingPathComponent("D3DMetal.framework")
            let destShared = destination.appendingPathComponent("libd3dshared.dylib")
            let destLicense = destination.appendingPathComponent(inspection.licenseURL.lastPathComponent)

            if fileManager.fileExists(atPath: destFramework.path) {
                try fileManager.removeItem(at: destFramework)
            }
            if fileManager.fileExists(atPath: destShared.path) {
                try fileManager.removeItem(at: destShared)
            }
            if fileManager.fileExists(atPath: destLicense.path) {
                try fileManager.removeItem(at: destLicense)
            }

            try fileManager.copyItem(at: inspection.frameworkURL, to: destFramework)
            try fileManager.copyItem(at: inspection.d3dsharedURL, to: destShared)
            try fileManager.copyItem(at: inspection.licenseURL, to: destLicense)

            _ = try? await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-dr", "com.apple.quarantine", destination.path]
            )

            var hashString: String?
            if let data = try? Data(contentsOf: destShared) {
                hashString = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }

            if inspection.requiresUnmount {
                try await detach(mountPoint: inspection.mountPoint)
            }

            return GPTKExtractionReceipt(
                destinationURL: destination,
                frameworkURL: destFramework,
                d3dsharedURL: destShared,
                licenseURL: destLicense,
                version: inspection.version,
                date: Date(),
                sha256: hashString
            )
        } catch {
            if inspection.requiresUnmount {
                _ = try? await detach(mountPoint: inspection.mountPoint)
            }
            throw GPTKError.extractionFailed(error.localizedDescription)
        }
    }
}

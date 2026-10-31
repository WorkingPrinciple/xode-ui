// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
@testable import XodusManagement

private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private struct MockGPTKRunner: GPTKProcessRunning {
    let handler: @Sendable (URL, [String]) throws -> (status: Int32, stdout: Data, stderr: Data)

    func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try handler(executable, arguments)
    }
}

extension Checks {
    func gptkPayloadChecks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GPTKPayloadChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let extractor = GPTKPayloadExtractor()

        // 1. Error descriptions check
        let errors: [GPTKError] = [
            .fileNotFound("/tmp/missing.dmg"),
            .notADiskImage("/tmp/file.txt"),
            .mountFailed("device not configured"),
            .unmountFailed("resource busy"),
            .missingRedistributables("D3DMetal.framework missing"),
            .extractionFailed("disk full"),
            .cancelled
        ]
        check(errors.allSatisfy { $0.errorDescription != nil && !$0.errorDescription!.isEmpty },
              "GPTK: All GPTKError cases have non-empty descriptions")

        // 2. Non-existent file check
        do {
            _ = try await extractor.inspect(url: tempRoot.appendingPathComponent("nonexistent.dmg"))
            check(false, "GPTK: Inspecting non-existent file should throw")
        } catch GPTKError.fileNotFound {
            check(true, "GPTK: Correctly throws fileNotFound for missing file")
        } catch {
            check(false, "GPTK: Threw unexpected error for missing file: \(error)")
        }

        // 3. Non-DMG file check
        let textFile = tempRoot.appendingPathComponent("sample.txt")
        try "test".write(to: textFile, atomically: true, encoding: .utf8)
        do {
            _ = try await extractor.inspect(url: textFile)
            check(false, "GPTK: Inspecting non-dmg file should throw")
        } catch GPTKError.notADiskImage {
            check(true, "GPTK: Correctly throws notADiskImage for .txt file")
        } catch {
            check(false, "GPTK: Threw unexpected error for non-dmg: \(error)")
        }

        // 4. Mock valid GPTK volume layout
        let mockVolume = tempRoot.appendingPathComponent("Evaluation environment for Windows games 4.0")
        let redistExt = mockVolume.appendingPathComponent("redist/lib/external")
        try FileManager.default.createDirectory(at: redistExt, withIntermediateDirectories: true)

        let mockFramework = redistExt.appendingPathComponent("D3DMetal.framework")
        try FileManager.default.createDirectory(at: mockFramework, withIntermediateDirectories: true)
        try "framework-stub".write(to: mockFramework.appendingPathComponent("D3DMetal"), atomically: true, encoding: .utf8)

        let mockD3D = redistExt.appendingPathComponent("libd3dshared.dylib")
        let dummyD3DData = Data("d3dshared-bytes".utf8)
        try dummyD3DData.write(to: mockD3D)

        let mockLicense = mockVolume.appendingPathComponent("License.rtf")
        let dummyLicenseData = Data("{\\rtf1 Apple Evaluation Agreement}".utf8)
        try dummyLicenseData.write(to: mockLicense)

        // Inspect directory directly
        let inspection = try await extractor.inspect(url: mockVolume)
        check(inspection.version == "4.0", "GPTK: Extracted version 4.0 from mock volume name")
        check(inspection.frameworkURL.path == mockFramework.path, "GPTK: Found D3DMetal.framework")
        check(inspection.d3dsharedURL.path == mockD3D.path, "GPTK: Found libd3dshared.dylib")
        check(inspection.licenseURL.path == mockLicense.path, "GPTK: Found License.rtf")
        check(!inspection.requiresUnmount, "GPTK: Directory inspection does not require unmount")
        check(inspection.licenseRTFData == dummyLicenseData, "GPTK: License RTF data loaded verbatim")

        // 5. Test extraction from valid inspection
        let destDir = tempRoot.appendingPathComponent("StagedComponents/D3DMetal-4.0")
        let receipt = try await extractor.extract(inspection: inspection, destination: destDir)
        check(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("D3DMetal.framework").path),
              "GPTK: Staged D3DMetal.framework exists at destination")
        check(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("libd3dshared.dylib").path),
              "GPTK: Staged libd3dshared.dylib exists at destination")
        check(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("License.rtf").path),
              "GPTK: Staged License.rtf exists at destination")
        check(receipt.version == "4.0", "GPTK: Receipt has matching version")
        check(receipt.sha256 != nil, "GPTK: Receipt contains sha256 checksum of libd3dshared.dylib")

        // 6. Test missing components in directory
        let brokenVolume = tempRoot.appendingPathComponent("Evaluation environment for Windows games 3.0")
        try FileManager.default.createDirectory(at: brokenVolume, withIntermediateDirectories: true)
        do {
            _ = try await extractor.inspect(url: brokenVolume)
            check(false, "GPTK: Inspecting broken volume should throw missingRedistributables")
        } catch GPTKError.missingRedistributables {
            check(true, "GPTK: Correctly throws missingRedistributables when components are missing")
        } catch {
            check(false, "GPTK: Threw unexpected error for broken volume: \(error)")
        }

        // 7. Mock process runner for DMG attach
        let dummyDMG = tempRoot.appendingPathComponent("Game_Porting_Toolkit_4.dmg")
        try "dummy-dmg-content".write(to: dummyDMG, atomically: true, encoding: .utf8)

        let mockPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>mount-point</key>
                    <string>\(mockVolume.path)</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

        let detachedMountPoint = StateBox()
        let mockRunner = MockGPTKRunner { executable, arguments in
            if arguments.contains("attach") {
                return (0, Data(mockPlist.utf8), Data())
            } else if arguments.contains("detach") {
                detachedMountPoint.value = arguments.last
                return (0, Data(), Data())
            } else if executable.path == "/usr/bin/xattr" {
                return (0, Data(), Data())
            }
            return (0, Data(), Data())
        }

        let mockedExtractor = GPTKPayloadExtractor(processRunner: mockRunner)
        let mockedInspection = try await mockedExtractor.inspect(url: dummyDMG)
        check(mockedInspection.requiresUnmount, "GPTK: DMG inspection flags requiresUnmount=true")
        check(mockedInspection.dmgURL == dummyDMG, "GPTK: Recorded source DMG URL")

        let stagedFromDMG = tempRoot.appendingPathComponent("StagedFromDMG")
        _ = try await mockedExtractor.extract(inspection: mockedInspection, destination: stagedFromDMG)
        check(detachedMountPoint.value == mockVolume.path, "GPTK: Automatically unmounted disk image on extraction completion")

        // 8. Mount failure check
        let failingRunner = MockGPTKRunner { _, arguments in
            if arguments.contains("attach") {
                return (1, Data(), Data("hdiutil: attach failed: no mountable filesystems".utf8))
            }
            return (0, Data(), Data())
        }
        let failingExtractor = GPTKPayloadExtractor(processRunner: failingRunner)
        do {
            _ = try await failingExtractor.inspect(url: dummyDMG)
            check(false, "GPTK: Mount failure should throw mountFailed")
        } catch GPTKError.mountFailed {
            check(true, "GPTK: Correctly throws mountFailed on non-zero exit from hdiutil")
        } catch {
            check(false, "GPTK: Threw unexpected error on mount failure: \(error)")
        }
    }
}

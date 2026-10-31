// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
final class GPTKOnboardingController: ObservableObject {
    enum Step: Equatable {
        case idle
        case waitingForDownload
        case detected(URL)
        case inspecting(URL)
        case licenseReview(GPTKInspection)
        case extracting(progress: Double, message: String)
        case completed(GPTKExtractionReceipt)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var detectedDMG: URL?
    @Published private(set) var activeInspection: GPTKInspection?
    @Published private(set) var receipt: GPTKExtractionReceipt?
    @Published var errorMessage: String?
    @Published var isPresented: Bool = false

    private let extractor: GPTKPayloadExtractor
    private var downloadSource: DispatchSourceFileSystemObject?
    private var downloadFileDescriptor: Int32 = -1
    private let targetDirectory: URL

    static let appleDownloadURL = URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!

    init(
        extractor: GPTKPayloadExtractor = GPTKPayloadExtractor(),
        targetDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/XOde/Components/D3DMetal-4.0")
    ) {
        self.extractor = extractor
        self.targetDirectory = targetDirectory
        checkExistingInstallation()
    }

    deinit {
        downloadSource?.cancel()
        if downloadFileDescriptor >= 0 {
            close(downloadFileDescriptor)
        }
    }

    func checkExistingInstallation() {
        let framework = targetDirectory.appendingPathComponent("D3DMetal.framework")
        let shared = targetDirectory.appendingPathComponent("libd3dshared.dylib")
        if FileManager.default.fileExists(atPath: framework.path),
           FileManager.default.fileExists(atPath: shared.path) {
            let license = targetDirectory.appendingPathComponent("License.rtf")
            let r = GPTKExtractionReceipt(
                destinationURL: targetDirectory,
                frameworkURL: framework,
                d3dsharedURL: shared,
                licenseURL: license,
                version: "4.0"
            )
            self.receipt = r
            self.step = .completed(r)
        }
    }

    var isInstalled: Bool {
        if case .completed = step { return true }
        return false
    }

    func openAppleDeveloperPortal() {
        NSWorkspace.shared.open(Self.appleDownloadURL)
        startWatchingDownloads()
        step = .waitingForDownload
    }

    func startWatchingDownloads() {
        stopWatchingDownloads()
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        guard FileManager.default.fileExists(atPath: downloads.path) else { return }

        downloadFileDescriptor = open(downloads.path, O_EVTONLY)
        guard downloadFileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: downloadFileDescriptor,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.checkForDMGInDownloads()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.downloadFileDescriptor, fd >= 0 {
                close(fd)
                self?.downloadFileDescriptor = -1
            }
        }

        source.resume()
        self.downloadSource = source

        checkForDMGInDownloads()
    }

    func stopWatchingDownloads() {
        if let source = downloadSource {
            source.cancel()
            downloadSource = nil
        } else if downloadFileDescriptor >= 0 {
            close(downloadFileDescriptor)
            downloadFileDescriptor = -1
        }
    }

    func checkForDMGInDownloads() {
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let dmgs = items.filter { url in
            let name = url.lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "dmg" &&
                (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk")) &&
                !name.contains(".crdownload") && !name.contains(".download")
        }.sorted { (u1, u2) -> Bool in
            let date1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let date2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return date1 > date2
        }

        if let latest = dmgs.first {
            self.detectedDMG = latest
            if case .waitingForDownload = step {
                self.step = .detected(latest)
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "dmg")].compactMap { $0 }
        panel.message = "Choose an Apple Game Porting Toolkit disk image (.dmg)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleSelectedURL(url)
    }

    func handleDrop(urls: [URL]) {
        guard let first = urls.first else { return }
        handleSelectedURL(first)
    }

    func handleSelectedURL(_ url: URL) {
        step = .inspecting(url)
        errorMessage = nil
        Task {
            do {
                let inspection = try await extractor.inspect(url: url)
                self.activeInspection = inspection
                self.step = .licenseReview(inspection)
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .failed(error.localizedDescription)
            }
        }
    }

    func confirmLicenseAndInstall() {
        guard let inspection = activeInspection else { return }
        step = .extracting(progress: 0.1, message: "Extracting Apple D3DMetal libraries...")
        errorMessage = nil

        Task {
            do {
                let r = try await extractor.extract(inspection: inspection, destination: targetDirectory)
                self.receipt = r
                self.step = .completed(r)
                self.activeInspection = nil
                self.stopWatchingDownloads()

                linkIntoEngines(receipt: r)
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLicenseReview() {
        guard let inspection = activeInspection else {
            step = .idle
            return
        }
        if inspection.requiresUnmount {
            Task {
                try? await extractor.detach(mountPoint: inspection.mountPoint)
            }
        }
        self.activeInspection = nil
        self.step = .idle
    }

    private func linkIntoEngines(receipt: GPTKExtractionReceipt) {
        let enginesRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/XOde/Engines")
        guard let engineDirs = try? FileManager.default.contentsOfDirectory(at: enginesRoot, includingPropertiesForKeys: nil) else { return }

        for engineDir in engineDirs {
            let extDir = engineDir.appendingPathComponent("lib/external")
            guard FileManager.default.fileExists(atPath: extDir.path) else { continue }

            let targetFramework = extDir.appendingPathComponent("D3DMetal.framework")
            let targetShared = extDir.appendingPathComponent("libd3dshared.dylib")

            if !FileManager.default.fileExists(atPath: targetFramework.path) {
                try? FileManager.default.createSymbolicLink(at: targetFramework, withDestinationURL: receipt.frameworkURL)
            }
            if !FileManager.default.fileExists(atPath: targetShared.path) {
                try? FileManager.default.createSymbolicLink(at: targetShared, withDestinationURL: receipt.d3dsharedURL)
            }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

public struct DownloadProgressInfo: Equatable, Sendable {
    public let filename: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double
    public let etaSeconds: TimeInterval?
    public let browser: String

    public init(
        filename: String,
        bytesDownloaded: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double,
        etaSeconds: TimeInterval?,
        browser: String
    ) {
        self.filename = filename
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
        self.browser = browser
    }

    public var fractionCompleted: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(bytesDownloaded) / Double(total)
    }

    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))/s"
    }

    public var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let total = totalBytes, total > 0 {
            let pct = Int(Double(bytesDownloaded) / Double(total) * 100.0)
            return "\(formatter.string(fromByteCount: bytesDownloaded)) of \(formatter.string(fromByteCount: total)) (\(pct)%)"
        }
        return formatter.string(fromByteCount: bytesDownloaded)
    }

    public var formattedETA: String {
        guard let eta = etaSeconds, eta > 0, !eta.isInfinite else { return "Calculating…" }
        if eta < 60 {
            return "~\(Int(eta))s remaining"
        }
        let mins = Int(eta / 60)
        let secs = Int(eta.truncatingRemainder(dividingBy: 60))
        return "~\(mins)m \(secs)s remaining"
    }
}

@MainActor
final class GPTKOnboardingController: ObservableObject {
    enum Step: Equatable {
        case idle
        case waitingForDownload
        case downloading(DownloadProgressInfo)
        case detected(URL)
        case inspecting(URL)
        case licenseReview(GPTKInspection)
        case extracting(progress: Double, message: String)
        case completed(GPTKExtractionReceipt)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var detectedDMG: URL?
    @Published private(set) var downloadProgress: DownloadProgressInfo?
    @Published private(set) var activeInspection: GPTKInspection?
    @Published private(set) var receipt: GPTKExtractionReceipt?
    @Published var errorMessage: String?
    @Published var isPresented: Bool = false

    private let extractor: GPTKPayloadExtractor
    private var downloadSource: DispatchSourceFileSystemObject?
    private var downloadFileDescriptor: Int32 = -1
    private let targetDirectory: URL

    private var pollTask: Task<Void, Never>?
    private var lastSampleDate: Date?
    private var lastSampleBytes: Int64 = 0

    static let appleDownloadURL = URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!

    init(
        extractor: GPTKPayloadExtractor = GPTKPayloadExtractor(),
        targetDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/XOde/Components/D3DMetal-4.0")
    ) {
        self.extractor = extractor
        self.targetDirectory = targetDirectory
        preflightLocalDetection()
    }

    deinit {
        downloadSource?.cancel()
        if downloadFileDescriptor >= 0 {
            close(downloadFileDescriptor)
        }
        pollTask?.cancel()
    }

    /// Automatically scans for an already staged component, an already mounted volume,
    /// or an already downloaded DMG on disk without opening any browser.
    func preflightLocalDetection() {
        // 1. Check if already staged in XOde Components
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
            return
        }

        // 2. Check if a GPTK volume is already mounted in /Volumes
        if let mountedVol = findMountedGPTKVolume() {
            self.detectedDMG = mountedVol
            self.step = .detected(mountedVol)
            return
        }

        // 3. Check for existing completed DMGs in ~/Downloads and ~/Desktop
        if let existing = findLocalDMG() {
            self.detectedDMG = existing
            self.step = .detected(existing)
            return
        }

        // 4. Fast Spotlight scan in user home directory (async)
        Task {
            if let spotlightDMG = await self.findDMGViaSpotlight() {
                if case .idle = self.step {
                    self.detectedDMG = spotlightDMG
                    self.step = .detected(spotlightDMG)
                }
            }
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
            self?.checkDownloadsState()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.downloadFileDescriptor, fd >= 0 {
                close(fd)
                self?.downloadFileDescriptor = -1
            }
        }

        source.resume()
        self.downloadSource = source

        // Start high-resolution timer for ETA / progress tracking
        startPollingActiveDownload()

        checkDownloadsState()
    }

    func stopWatchingDownloads() {
        if let source = downloadSource {
            source.cancel()
            downloadSource = nil
        } else if downloadFileDescriptor >= 0 {
            close(downloadFileDescriptor)
            downloadFileDescriptor = -1
        }
        stopPollingActiveDownload()
    }

    private func startPollingActiveDownload() {
        stopPollingActiveDownload()
        lastSampleDate = Date()
        lastSampleBytes = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { break }
                self?.pollActiveDownloadProgress()
            }
        }
    }

    private func stopPollingActiveDownload() {
        pollTask?.cancel()
        pollTask = nil
        lastSampleDate = nil
        lastSampleBytes = 0
    }

    /// Evaluates ~/Downloads for both completed DMGs and in-progress downloads
    func checkDownloadsState() {
        // First check if a completed DMG is now ready
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let completedDMGs = items.filter { url in
            let name = url.lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "dmg" &&
                (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk")) &&
                !name.contains(".crdownload") && !name.contains(".download")
        }.sorted { (u1, u2) -> Bool in
            let date1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let date2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return date1 > date2
        }

        if let completed = completedDMGs.first {
            self.detectedDMG = completed
            self.stopPollingActiveDownload()

            // If we were waiting for download or tracking download progress, auto-inspect!
            if case .waitingForDownload = step {
                handleSelectedURL(completed)
                return
            } else if case .downloading = step {
                handleSelectedURL(completed)
                return
            } else if case .idle = step {
                self.step = .detected(completed)
                return
            }
        }

        // Second, check for in-progress download markers (Safari, Chrome, Firefox)
        pollActiveDownloadProgress()
    }

    /// Probes in-progress downloads to compute ETA and byte velocity
    private func pollActiveDownloadProgress() {
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.fileSizeKey]) else { return }

        // 1. Safari download bundle: *.dmg.download (or contains game_porting_toolkit / evaluation_environment)
        let safariDownloads = items.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasSuffix(".download") && (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk"))
        }

        if let safariBundle = safariDownloads.first {
            let infoPlist = safariBundle.appendingPathComponent("Info.plist")
            if let plistData = try? Data(contentsOf: infoPlist),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                let bytesSoFar = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
                let totalBytes = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value

                let (speed, eta) = calculateRateAndETA(currentBytes: bytesSoFar, totalBytes: totalBytes)
                let cleanName = safariBundle.lastPathComponent.replacingOccurrences(of: ".download", with: "")

                let progress = DownloadProgressInfo(
                    filename: cleanName,
                    bytesDownloaded: bytesSoFar,
                    totalBytes: totalBytes,
                    bytesPerSecond: speed,
                    etaSeconds: eta,
                    browser: "Safari"
                )
                self.downloadProgress = progress
                self.step = .downloading(progress)
                return
            }
        }

        // 2. Chromium / Edge download: *.dmg.crdownload
        let chromeDownloads = items.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasSuffix(".crdownload") && (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk"))
        }

        if let chromeFile = chromeDownloads.first {
            let bytesSoFar = (try? chromeFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            // GPTK 4 DMG is ~310 MB; estimate total if not otherwise signaled
            let estimatedTotal: Int64 = 325_000_000
            let (speed, eta) = calculateRateAndETA(currentBytes: bytesSoFar, totalBytes: estimatedTotal)
            let cleanName = chromeFile.lastPathComponent.replacingOccurrences(of: ".crdownload", with: "")

            let progress = DownloadProgressInfo(
                filename: cleanName,
                bytesDownloaded: bytesSoFar,
                totalBytes: estimatedTotal,
                bytesPerSecond: speed,
                etaSeconds: eta,
                browser: "Chrome/Edge"
            )
            self.downloadProgress = progress
            self.step = .downloading(progress)
            return
        }

        // 3. Firefox download: *.dmg.part
        let firefoxDownloads = items.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasSuffix(".part") && (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk"))
        }

        if let ffFile = firefoxDownloads.first {
            let bytesSoFar = (try? ffFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            let estimatedTotal: Int64 = 325_000_000
            let (speed, eta) = calculateRateAndETA(currentBytes: bytesSoFar, totalBytes: estimatedTotal)
            let cleanName = ffFile.lastPathComponent.replacingOccurrences(of: ".part", with: "")

            let progress = DownloadProgressInfo(
                filename: cleanName,
                bytesDownloaded: bytesSoFar,
                totalBytes: estimatedTotal,
                bytesPerSecond: speed,
                etaSeconds: eta,
                browser: "Firefox"
            )
            self.downloadProgress = progress
            self.step = .downloading(progress)
            return
        }
    }

    private func calculateRateAndETA(currentBytes: Int64, totalBytes: Int64?) -> (speed: Double, eta: TimeInterval?) {
        let now = Date()
        var speed: Double = 0
        var eta: TimeInterval?

        if let lastDate = lastSampleDate, lastDate != now {
            let elapsed = now.timeIntervalSince(lastDate)
            if elapsed > 0 {
                let delta = currentBytes - lastSampleBytes
                if delta > 0 {
                    speed = Double(delta) / elapsed
                    if let total = totalBytes, total > currentBytes, speed > 0 {
                        eta = Double(total - currentBytes) / speed
                    }
                }
            }
        }

        lastSampleDate = now
        lastSampleBytes = currentBytes
        return (speed, eta)
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

    private func findMountedGPTKVolume() -> URL? {
        let volumes = URL(fileURLWithPath: "/Volumes")
        guard let items = try? FileManager.default.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil) else { return nil }
        for item in items {
            let name = item.lastPathComponent.lowercased()
            if name.contains("evaluation environment") || name.contains("game porting toolkit") {
                let redist = item.appendingPathComponent("redist/lib/external/D3DMetal.framework")
                if FileManager.default.fileExists(atPath: redist.path) {
                    return item
                }
            }
        }
        return nil
    }

    private func findLocalDMG() -> URL? {
        let candidateDirs = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        ]

        for dir in candidateDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let matches = items.filter { url in
                let name = url.lastPathComponent.lowercased()
                return url.pathExtension.lowercased() == "dmg" &&
                    (name.contains("game_porting_toolkit") || name.contains("evaluation_environment") || name.contains("gptk")) &&
                    !name.contains(".download") && !name.contains(".crdownload")
            }.sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return d1 > d2
            }
            if let best = matches.first {
                return best
            }
        }
        return nil
    }

    private func findDMGViaSpotlight() async -> URL? {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin", NSHomeDirectory(),
            "kMDItemFSName == '*Game_Porting_Toolkit*.dmg'c || kMDItemFSName == '*Evaluation_environment*.dmg'c"
        ]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            do {
                process.terminationHandler = { proc in
                    guard proc.terminationStatus == 0,
                          let data = try? out.fileHandleForReading.readToEnd(),
                          let text = String(data: data, encoding: .utf8) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    let valid = lines.map { URL(fileURLWithPath: $0) }.filter {
                        FileManager.default.fileExists(atPath: $0.path) &&
                        !$0.path.contains("/Trash/") &&
                        !$0.lastPathComponent.contains(".crdownload")
                    }
                    continuation.resume(returning: valid.first)
                }
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
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

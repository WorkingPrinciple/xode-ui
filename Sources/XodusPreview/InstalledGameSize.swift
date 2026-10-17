// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import OSLog
import SwiftUI

enum InstalledSizeFailure: Error, Equatable { case unavailable, incomplete, overflow }

struct InstalledFolderSize: Sendable {
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let measuredAt: Date

    private struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }

    static func measure(folder: URL, maximumEntries: Int = 100_000) throws -> Self {
        guard !Thread.isMainThread, folder.isFileURL,
              try folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw InstalledSizeFailure.unavailable
        }
        var root = stat()
        guard lstat(folder.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            throw InstalledSizeFailure.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var failed = false
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in failed = true; return false }) else {
            throw InstalledSizeFailure.unavailable
        }
        let (rootBlocks, rootOverflow) = Int64(root.st_blocks).multipliedReportingOverflow(by: 512)
        guard root.st_blocks >= 0, !rootOverflow else { throw InstalledSizeFailure.overflow }
        var logical: Int64 = 0, allocated = rootBlocks, count = 0
        var seen = Set<FileIdentity>()
        for case let entry as URL in entries {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries, ContinuousClock.now < deadline else { throw InstalledSizeFailure.incomplete }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw InstalledSizeFailure.incomplete }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { entries.skipDescendants(); continue }
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            guard seen.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
            guard info.st_size >= 0, info.st_blocks >= 0 else { throw InstalledSizeFailure.incomplete }
            let (blocks, blocksOverflow) = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let (diskTotal, diskOverflow) = allocated.addingReportingOverflow(blocks)
            let (contentTotal, contentOverflow) = logical.addingReportingOverflow(kind == S_IFREG ? info.st_size : 0)
            guard !blocksOverflow, !diskOverflow, !contentOverflow else { throw InstalledSizeFailure.overflow }
            allocated = diskTotal
            logical = contentTotal
        }
        var after = stat()
        guard !failed, lstat(folder.path, &after) == 0,
              after.st_dev == root.st_dev, after.st_ino == root.st_ino else { throw InstalledSizeFailure.incomplete }
        return Self(logicalBytes: logical, allocatedBytes: allocated, measuredAt: Date())
    }
}

@MainActor
final class InstalledGameSizeStore: ObservableObject {
    static let shared = InstalledGameSizeStore()
    private struct Key: Hashable {
        let id: UUID
        let folder: String
        let version: String
        let importedAt: Date
        init(_ game: InstalledGame) {
            id = game.id; folder = game.folder; version = game.version; importedAt = game.importedAt
        }
    }
    @Published private var sizes: [Key: InstalledFolderSize] = [:]
    private var attempted: [Key: Date] = [:]
    private var pending: [Key: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "installed-size")
    private(set) var measurementAttempts = 0

    func value(for game: InstalledGame) -> InstalledFolderSize? { sizes[Key(game)] }

    func load(_ game: InstalledGame) async {
        let key = Key(game)
        if let task = pending[key] { await task.value; return }
        guard attempted[key].map({ Date().timeIntervalSince($0) >= 900 }) ?? true else { return }
        attempted[key] = Date()
        measurementAttempts += 1
        let task = Task {
            do {
                let size = try await Task.detached(priority: .utility) {
                    try InstalledFolderSize.measure(folder: URL(fileURLWithPath: game.folder, isDirectory: true))
                }.value
                sizes[key] = size
            } catch {
                sizes[key] = nil
                logger.warning("stage=installedSizeUnavailable; optional size hidden")
            }
        }
        pending[key] = task
        await task.value
        pending[key] = nil
    }
}

struct LibraryGameSizeView: View {
    let installed: InstalledGame?
    let downloadBytes: Int64?
    var packageFormat: String? = nil
    var allowsMeasurement = true
    @ObservedObject private var sizes = InstalledGameSizeStore.shared

    var body: some View {
        HStack(spacing: 8) {
            if let packageFormat {
                LibraryPackageFormatLabel(format: packageFormat)
            }
            sizeLabel
        }
    }

    private var sizeLabel: some View {
        Group {
            if let installed, let size = sizes.value(for: installed) {
                Label("\(GameOperationProgressView.bytes(size.allocatedBytes)) installed", systemImage: "internaldrive")
                    .help("Filesystem-allocated size; \(GameOperationProgressView.bytes(size.logicalBytes)) logical content. Shared or cloned blocks may count more than once. Measured \(size.measuredAt.formatted(.relative(presentation: .named))).")
            } else if installed == nil, let bytes = downloadBytes, bytes > 0 {
                Label("~\(GameOperationProgressView.bytes(bytes)) download", systemImage: "arrow.down.circle")
                    .help("Approximate public PC catalog size. Install review confirms the selected package's checked download size.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .task(id: installed.map { "\($0.id):\($0.version):\($0.importedAt)" }) {
            if allowsMeasurement, let installed { await sizes.load(installed) }
        }
    }
}

struct LibraryPackageFormatLabel: View {
    let format: String

    var body: some View {
        Text(format)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("PC package format from the public Microsoft catalog. MSIXVC is the GDK format Xodus installs today; EAppx/Appx are Store app packages.")
            .accessibilityLabel("Package format \(format)")
    }
}

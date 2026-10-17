// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CryptoKit
import Foundation

/// Bounded disk cache of public trailers the user has already watched.
/// Entries are keyed by a digest so no trailer URL is written to disk.
@MainActor
final class TrailerCache: NSObject {
    static let shared = TrailerCache()
    static let limit = 8

    private struct Entry: Codable { var path: String; var used: Date }
    private var index: [String: Entry] = [:]
    private var active: [String: AVAssetDownloadTask] = [:]
    private var session: AVAssetDownloadURLSession?
    private let indexURL: URL?

    override init() {
        let isolated = ["--library-preview", "--export-preview", "--export-live", "--fixture", "--self-check",
                        "--live-check", "--media-check", "--stats-check"]
        if CommandLine.arguments.contains(where: isolated.contains) || Bundle.main.bundleIdentifier == nil {
            indexURL = nil
        } else {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Xodus", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            indexURL = directory.appendingPathComponent("trailer-index.json")
        }
        super.init()
        if let indexURL, let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = saved.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        }
    }

    static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var count: Int { index.count }

    func localURL(for url: URL) -> URL? {
        let key = Self.key(url)
        guard let entry = index[key] else { return nil }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            index[key] = nil
            save()
            return nil
        }
        index[key]?.used = Date()
        save()
        return URL(fileURLWithPath: entry.path)
    }

    func store(_ url: URL) {
        guard indexURL != nil else { return }
        let key = Self.key(url)
        guard index[key] == nil, active[key] == nil else { return }
        if session == nil {
            let configuration = URLSessionConfiguration.background(withIdentifier: "io.github.dragoshont.xodus.trailers")
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self,
                                                delegateQueue: .main)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: []])
        guard let task = session?.makeAssetDownloadTask(
            asset: asset, assetTitle: "Xodus trailer", assetArtworkData: nil,
            options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 4_500_000]) else { return }
        task.taskDescription = key
        active[key] = task
        task.resume()
    }

    func clear() {
        active.values.forEach { $0.cancel() }
        active.removeAll()
        for entry in index.values { try? FileManager.default.removeItem(atPath: entry.path) }
        index.removeAll()
        save()
    }

    fileprivate func finished(key: String, path: String) {
        index[key] = Entry(path: path, used: Date())
        while index.count > Self.limit, let oldest = index.min(by: { $0.value.used < $1.value.used }) {
            try? FileManager.default.removeItem(atPath: oldest.value.path)
            index[oldest.key] = nil
        }
        save()
    }

    fileprivate func completed(key: String, failed: Bool) {
        active[key] = nil
        if failed, let entry = index[key] {
            try? FileManager.default.removeItem(atPath: entry.path)
            index[key] = nil
            save()
        }
    }

    private func save() {
        guard let indexURL, let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

extension TrailerCache: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let path = location.path
        MainActor.assumeIsolated { finished(key: key, path: path) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let key = task.taskDescription else { return }
        let failed = error != nil
        MainActor.assumeIsolated { completed(key: key, failed: failed) }
    }
}

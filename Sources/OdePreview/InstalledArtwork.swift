// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import ImageIO
import SwiftUI

enum InstalledArtworkPolicy {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumPixels = 16_000_000

    static func components(_ relative: String) -> [String]? {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard normalized.count <= 4096, !normalized.contains(":"),
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let file = components.last,
              ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: file).pathExtension.lowercased()) else { return nil }
        return components
    }

    static func read(folder: URL, relative: String) throws -> Data {
        guard let path = components(relative) else { throw ArtworkLoadError.unavailable }
        var directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ArtworkLoadError.unavailable }
        defer { close(directory) }
        for component in path.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ArtworkLoadError.unavailable }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, path.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArtworkLoadError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw ArtworkLoadError.oversized }
        guard let data = try handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw ArtworkLoadError.oversized
        }
        return data
    }

    static func validatePixels(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixels,
              height <= maximumPixels / width else { throw ArtworkLoadError.oversized }
    }

    static func decode(_ data: Data, maxDimension: Int) throws -> CGImage {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ArtworkLoadError.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ArtworkLoadError.invalidImage
        }
        try validatePixels(width: width, height: height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ArtworkLoadError.invalidImage }
        return image
    }

    static func image(folder: URL, candidates: [String], maxDimension: Int) -> CGImage? {
        for relative in candidates {
            do { return try decode(read(folder: folder, relative: relative), maxDimension: maxDimension) }
            catch { continue } // Optional local art never prevents import or Play.
        }
        return nil
    }
}

@MainActor
final class InstalledArtworkStore {
    static let shared = InstalledArtworkStore()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(game: InstalledGame, splash: Bool) async -> NSImage? {
        let key = "\(game.id):\(game.importedAt.timeIntervalSince1970):\(splash)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = pending[key] { return await task.value }
        let task = Task {
            let image = await Task.detached(priority: .utility) {
                let folder = URL(fileURLWithPath: game.folder)
                guard let config = try? MicrosoftGameConfig.read(folder: folder) else { return nil as CGImage? }
                let candidates = (splash ? config.splashArt.map { [$0] } ?? [] : []) + config.tileArt
                return InstalledArtworkPolicy.image(folder: folder, candidates: candidates,
                                                     maxDimension: splash ? 1920 : 480)
            }.value
            return image.map { NSImage(cgImage: $0, size: .zero) }
        }
        pending[key] = task
        defer { pending[key] = nil }
        let image = await task.value
        if let image {
            cache.setObject(image, forKey: key as NSString,
                            cost: Int(image.size.width * image.size.height) * 4)
        }
        return image
    }
}

@MainActor
private final class InstalledArtworkPresentation: ObservableObject {
    @Published private(set) var image: NSImage?
    private var loadID = UUID()

    func load(game: InstalledGame, splash: Bool, allowed: Bool) async {
        let token = UUID()
        loadID = token
        image = nil
        guard allowed else { return }
        let result = await InstalledArtworkStore.shared.image(game: game, splash: splash)
        if !Task.isCancelled, loadID == token { image = result }
    }
}

struct InstalledArtworkView: View {
    let game: InstalledGame
    var splash = false
    var allowsLoading = true
    @StateObject private var presentation = InstalledArtworkPresentation()

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = presentation.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        Image(systemName: "gamecontroller").font(.title).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: "\(game.id):\(game.importedAt):\(splash)") {
            await presentation.load(game: game, splash: splash, allowed: allowsLoading)
        }
    }
}

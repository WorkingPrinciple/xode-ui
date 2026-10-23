// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusManagement

enum LibraryLogoPolicy {
    static func isTransparent(_ image: CGImage) -> Bool {
        let width = min(256, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard height <= 256 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var transparent = 0, visible = 0
            var luminance = 0.0
            for offset in stride(from: 3, to: bytes.count, by: 4) {
                let alpha = bytes[offset]
                if alpha < 250 { transparent += 1 }
                if alpha > 20 {
                    visible += 1
                    let scale = 255.0 / Double(alpha)
                    luminance += (0.2126 * Double(bytes[offset - 3]) + 0.7152 * Double(bytes[offset - 2])
                        + 0.0722 * Double(bytes[offset - 1])) * scale / 255.0
                }
            }
            // Heroes sit on dark scrims and video; a mostly dark logo would be invisible there.
            return transparent >= max(1, width * height / 20) && visible > 0
                && luminance / Double(visible) >= 0.4
        }
    }
}

@MainActor
private final class LibraryLogoPresentation: ObservableObject {
    @Published var image: NSImage?
    @Published var unavailable = false
    private var key: String?
    func image(for key: String) -> NSImage? { self.key == key ? image : nil }
    func load(_ references: [CatalogArtworkReference], allowed: Bool, key: String) async {
        if self.key != key { image = nil }
        self.key = key
        unavailable = false
        guard allowed else { return }
        for reference in references {
            do {
                let value = try await CatalogArtworkStore.shared.image(for: reference)
                try Task.checkCancellation()
                if let image = value.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   LibraryLogoPolicy.isTransparent(image) {
                    self.image = value
                    return
                }
            } catch is CancellationError { return }
            catch { unavailable = true }
        }
    }
}

struct LibraryLogoTitle: View {
    let title: String
    let references: [CatalogArtworkReference]
    var allowsLoading = true
    @StateObject private var presentation = LibraryLogoPresentation()
    @Environment(\.catalogPresentationActive) private var presentationActive
    private var key: String { references.map(\.url).joined(separator: "|") }

    var body: some View {
        Group {
            if let image = presentation.image(for: key) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 120, alignment: .leading)
                    .accessibilityLabel(title)
            } else {
                Text(title).font(.system(size: 40, weight: .bold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: key + ":\(presentationActive)") {
            guard presentationActive else { return }
            await presentation.load(references, allowed: allowsLoading, key: key)
        }
    }
}

@MainActor
private final class LibraryLandscapePresentation: ObservableObject {
    @Published var image: NSImage?
    @Published var unavailable = false
    private var key: String?

    func image(for key: String) -> NSImage? { self.key == key ? image : nil }

    func load(_ references: [CatalogArtworkReference], installed: InstalledGame?, allowed: Bool, key: String) async {
        if self.key != key { image = nil }
        self.key = key
        unavailable = false
        guard allowed else { return }
        for reference in references {
            do {
                let value = try await CatalogArtworkStore.shared.image(for: reference)
                try Task.checkCancellation()
                image = value
                return
            } catch is CancellationError { return }
            catch { unavailable = true }
        }
        if let installed {
            let local = await InstalledArtworkStore.shared.image(game: installed, splash: true)
            guard !Task.isCancelled else { return }
            image = local
        }
        unavailable = image == nil
    }
}

struct LibraryLandscapeView: View {
    let references: [CatalogArtworkReference]
    let installed: InstalledGame?
    var allowsLoading = true
    @StateObject private var presentation = LibraryLandscapePresentation()
    @Environment(\.catalogPresentationActive) private var presentationActive

    private var key: String { references.map(\.url).joined(separator: "|") + (installed?.id.uuidString ?? "") }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = presentation.image(for: key) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: key + ":\(presentationActive)") {
            guard presentationActive else { return }
            await presentation.load(references, installed: installed, allowed: allowsLoading, key: key)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

@MainActor
enum ArtAssets {
    static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["harbor", "orbit", "ridge", "signal", "moss", "tide"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Artwork"),
                  let image = NSImage(contentsOf: url) else {
                FileHandle.standardError.write(Data("Missing required original fixture artwork: \(name)\n".utf8))
                continue
            }
            images[name] = image
        }
        return images
    }()
}

struct GameArtwork: View {
    let kind: String

    var body: some View {
        GeometryReader { geometry in
            if let image = ArtAssets.images[kind] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay(Text("Fixture artwork unavailable").foregroundStyle(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}

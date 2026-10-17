// SPDX-License-Identifier: GPL-3.0-only
import AVKit
import Combine
import SwiftUI

struct CatalogAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

@MainActor
final class CatalogTrailerPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    /// True once frames from the intended start point are on screen, so callers can keep the poster until then.
    @Published private(set) var rendering = false
    private var observation: AnyCancellable?
    private var endObservation: AnyCancellable?
    private var controlObservation: AnyCancellable?
    private var reveal: Task<Void, Never>?
    private var positioned = false
    private var wantsPlayback = false

    func pause() { wantsPlayback = false; player?.pause() }
    func resume() { wantsPlayback = true; player?.play() }
    func setMuted(_ muted: Bool) { player?.isMuted = muted }

    static func previewStart(duration: Double) -> Double {
        guard duration.isFinite, duration > 10 else { return 0 }
        return min(60, duration * 0.35)
    }

    func play(_ trailer: CatalogTrailer, muted: Bool = false, loops: Bool = false, preview: Bool = false) {
        stop()
        wantsPlayback = true
        let cached = TrailerCache.shared.localURL(for: trailer.url)
        let asset = AVURLAsset(url: cached ?? trailer.url, options: [AVURLAssetHTTPCookiesKey: []])
        if cached == nil { TrailerCache.shared.store(trailer.url) }
        let item = AVPlayerItem(asset: asset)
        if muted {
            item.preferredPeakBitRate = 6_000_000
            item.preferredForwardBufferDuration = 5
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        positioned = !preview
        observation = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            if status == .failed {
                self?.player?.pause()
                self?.error = "The trailer couldn't be played. Try again or view the screenshots."
            } else if status == .readyToPlay, preview, self?.player === player {
                let start = Self.previewStart(duration: item.duration.seconds)
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
                    Task { @MainActor in
                        guard done, let self, self.player === player else { return }
                        self.positioned = true
                        if self.wantsPlayback { player.play() }
                    }
                }
            }
        }
        controlObservation = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.player === player, status == .playing, self.positioned, !self.rendering else { return }
                self.reveal?.cancel()
                self.reveal = Task { @MainActor [weak self] in
                    // Let the first decoded frames settle before replacing the poster.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let self, self.player === player else { return }
                    self.rendering = true
                }
            }
        if loops {
            endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    guard let player = self?.player, player.currentItem === item else { return }
                    let start = preview ? Self.previewStart(duration: item.duration.seconds) : 0
                    player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                    if self?.wantsPlayback == true { player.play() }
                }
        }
        self.player = player
        if !preview { player.play() }
    }

    func stop() {
        wantsPlayback = false
        observation = nil
        endObservation = nil
        controlObservation = nil
        reveal?.cancel()
        reveal = nil
        rendering = false
        positioned = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        error = nil
    }
}

struct CatalogTrailerView: View {
    let trailer: CatalogTrailer
    var allowsLoading = true
    var allowsPlayback = true
    @StateObject private var playback = CatalogTrailerPlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player = playback.player {
                CatalogAVPlayerView(player: player).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(trailer.caption)
                HStack {
                    Text(trailer.caption).font(.headline)
                    Spacer()
                    Button("Close trailer", systemImage: "xmark", action: playback.stop)
                }
                if let error = playback.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("Try Again") { playback.play(trailer) }.disabled(!allowsPlayback)
                }
            } else {
                Button { playback.play(trailer) } label: {
                    ZStack {
                        CatalogArtworkView(reference: allowsLoading ? trailer.preview : nil,
                                           status: trailer.preview == nil ? .absent : .available)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        Label("Play \(trailer.caption)", systemImage: "play.fill")
                            .font(.headline).padding(14).modifier(NativeToolbarMaterial())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(!allowsPlayback)
                .accessibilityLabel("Play \(trailer.caption). Streams video.")
            }
        }
        .onDisappear(perform: playback.stop)
    }
}

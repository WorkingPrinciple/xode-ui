// SPDX-License-Identifier: GPL-3.0-only
import AVKit
import SwiftUI

enum HeroMotionPolicy {
    static func permitsPlayback(allowed: Bool, enabled: Bool, reduceMotion: Bool,
                                lowPower: Bool, active: Bool, visible: Bool,
                                hasTrailer: Bool, supportsViewportVisibility: Bool = true) -> Bool {
        allowed && enabled && !reduceMotion && !lowPower && active && visible && hasTrailer
            && supportsViewportVisibility
    }
}

@MainActor
private final class HeroMediaPresentation: ObservableObject {
    @Published var visible = false
    @Published var paused = false
    /// Latched by the first hover so playback continues after the pointer leaves.
    @Published var started = false
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
}

private struct HeroAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
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

struct LibraryHeroMedia<Poster: View>: View {
    let trailer: CatalogTrailer?
    var allowsPlayback = true
    var playingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let poster: () -> Poster
    @AppStorage("Xodus.heroAnimationsEnabled") private var enabled = true
    @AppStorage("Xodus.heroTrailerMuted") private var muted = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var presentation = HeroMediaPresentation()
    @StateObject private var playback = CatalogTrailerPlayback()

    private var supportsViewportVisibility: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    private var eligible: Bool {
        HeroMotionPolicy.permitsPlayback(allowed: allowsPlayback, enabled: enabled,
            reduceMotion: reduceMotion, lowPower: presentation.lowPower, active: scenePhase == .active,
            visible: presentation.visible, hasTrailer: trailer != nil,
            supportsViewportVisibility: supportsViewportVisibility)
            && presentation.started
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            poster()
            if let player = playback.player, playback.error == nil {
                HeroAVPlayerView(player: player)
                    .opacity(playback.rendering ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: playback.rendering)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if eligible {
                HStack(spacing: 10) {
                    if playback.rendering, playback.error == nil {
                        Button {
                            muted.toggle()
                        } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .modifier(LibraryActionStyle(primary: false)).buttonBorderShape(.circle)
                        .accessibilityLabel(muted ? "Unmute trailer" : "Mute trailer")
                        .help(muted ? "Unmute" : "Mute")
                    }
                    Button {
                        if playback.error != nil, let trailer {
                            playback.play(trailer, muted: muted, loops: true, preview: true)
                        } else { presentation.paused.toggle() }
                    } label: {
                        Image(systemName: playback.error != nil ? "arrow.clockwise"
                              : presentation.paused ? "play.fill" : "pause.fill")
                    }
                    .modifier(LibraryActionStyle(primary: false)).buttonBorderShape(.circle)
                    .accessibilityLabel(playback.error != nil ? "Retry animated artwork"
                                        : presentation.paused ? "Resume animated artwork" : "Pause animated artwork")
                    .help(playback.error ?? (presentation.paused ? "Resume" : "Pause"))
                }
                .padding(.trailing, 24).padding(.top, 68)
            }
        }
        .onAppear { presentation.visible = true }
        .onHover { if $0 { presentation.started = true } }
        .modifier(HeroScrollVisibility { presentation.visible = $0 })
        .task(id: "\(eligible):\(presentation.paused):\(trailer?.id ?? "")") {
            if eligible, let trailer {
                if presentation.paused { playback.pause() }
                else if playback.player != nil { playback.resume() }
                else { playback.play(trailer, muted: muted, loops: true, preview: true) }
            } else { playback.stop() }
        }
        .onChange(of: muted) { _, value in playback.setMuted(value) }
        .onChange(of: allowsPlayback) { _, allowed in if !allowed { presentation.started = false } }
        .onChange(of: playback.rendering && !presentation.paused) { _, playing in playingChanged(playing) }
        .onChange(of: trailer?.id) { _, _ in
            playback.stop(); presentation.paused = false; presentation.started = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            presentation.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear { presentation.visible = false; playback.stop() }
    }
}

struct HeroScrollVisibility: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.1, changed)
        } else {
            content.onDisappear { changed(false) }
        }
    }
}

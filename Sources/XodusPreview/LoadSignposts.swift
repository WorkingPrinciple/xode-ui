// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import OSLog

/// REQ-121 load-latency intervals. Watch them with
/// `log stream --signpost --predicate 'subsystem == "io.github.dragoshont.xodus" AND category == "load-latency"'`.
enum LoadSignposts {
    static let signposter = OSSignposter(subsystem: "io.github.dragoshont.xodus", category: "load-latency")
    static let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "load-latency")

    /// Milliseconds since this process started, so intervals can be compared with launch time.
    static func sinceLaunch() -> Int {
        Int((Date().timeIntervalSince1970 - processStart) * 1000)
    }

    private static let processStart: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }()
}

/// Tracks when catalogue tiles receive real artwork: the first `firstTileCount` tiles, and each burst
/// of visible artwork loads until every requested tile has drawn, failed or gone off screen.
@MainActor
final class ArtworkDrawTracker {
    static let shared = ArtworkDrawTracker()
    let firstTileCount: Int
    private(set) var drawn = 0
    private(set) var failed = 0
    private(set) var active = 0
    private(set) var completedBursts = 0
    private(set) var firstTilesDrawn = false
    private var firstTiles: OSSignpostIntervalState?
    private var burst: OSSignpostIntervalState?
    private var burstDrawn = 0
    private var burstFailed = 0

    init(firstTileCount: Int = 12) { self.firstTileCount = firstTileCount }

    func began() {
        if firstTiles == nil, !firstTilesDrawn {
            firstTiles = LoadSignposts.signposter.beginInterval("FirstTilesDrawn",
                id: LoadSignposts.signposter.makeSignpostID(), "target=\(self.firstTileCount)")
        }
        if active == 0 {
            burstDrawn = 0
            burstFailed = 0
            burst = LoadSignposts.signposter.beginInterval("VisibleArtworkDrawn",
                id: LoadSignposts.signposter.makeSignpostID(), "burst=\(self.completedBursts + 1)")
        }
        active += 1
    }

    func finished(drawn didDraw: Bool, failed didFail: Bool) {
        guard active > 0 else { return }
        active -= 1
        if didDraw {
            drawn += 1
            burstDrawn += 1
        }
        if didFail {
            failed += 1
            burstFailed += 1
        }
        if didDraw, !firstTilesDrawn, drawn >= firstTileCount, let state = firstTiles {
            firstTilesDrawn = true
            firstTiles = nil
            let elapsed = LoadSignposts.sinceLaunch()
            LoadSignposts.signposter.endInterval("FirstTilesDrawn", state, "tiles=\(self.drawn) sinceLaunchMs=\(elapsed)")
            LoadSignposts.logger.notice("stage=firstTilesDrawn tiles=\(self.drawn) sinceLaunchMs=\(elapsed)")
        }
        if active == 0, let state = burst {
            burst = nil
            completedBursts += 1
            let elapsed = LoadSignposts.sinceLaunch()
            LoadSignposts.signposter.endInterval("VisibleArtworkDrawn", state,
                "burst=\(self.completedBursts) drawn=\(self.burstDrawn) failed=\(self.burstFailed) sinceLaunchMs=\(elapsed)")
            if completedBursts == 1 {
                LoadSignposts.logger.notice("stage=visibleArtworkDrawn drawn=\(self.burstDrawn) failed=\(self.burstFailed) sinceLaunchMs=\(elapsed)")
            }
        }
    }
}

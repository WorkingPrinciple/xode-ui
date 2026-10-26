// SPDX-License-Identifier: GPL-3.0-only
import OSLog
import SwiftUI
import XodusManagement

/// REQ-119: copy for the first library load after a cold sign-in.
enum FirstLoadCopy {
    static let title = "Setting up your library"
    static let signedIn = "Signed in"
    static let findingGames = "Finding your games"
    static let fetchingArtwork = "Fetching artwork"
    static let slow = "This is taking longer than usual. You can open your library now, and games will keep appearing."
    static let showNow = "Show library now"
    static let failedTitle = "Library setup stopped"
    static let tryAgain = "Try Again"
    static let ready = "Library ready"
    /// Light lines under the steps. Never announced; the steps carry the real progress.
    static let lines = [
        "Unboxing your games…",
        "Stacking game discs…",
        "Dusting off the box art…",
        "Lining up your shelf…",
        "Reading the manuals…",
        "Counting save points…",
        "Warming up the controllers…",
        "Blowing on the cartridges…",
    ]

    static func found(_ count: Int) -> String {
        switch count {
        case 0: "Checking your Microsoft account"
        case 1: "Found 1 game"
        default: "Found \(count.formatted()) games"
        }
    }

    static func artwork(ready: Int, of total: Int) -> String {
        total == 0 ? "Getting the first games ready" : "\(min(ready, total).formatted()) of \(total.formatted())"
    }
}

/// What the library has reached; the root view derives it from the library and artwork state.
struct LibraryFirstLoadInputs: Equatable {
    var signedIn = true
    var loading = false
    var gamesFound = 0
    var libraryComplete = false
    var error: String?
    /// Country, sign-in or Keychain approval the library itself asks for.
    var needsAccountAction = false
    var artworkTotal = 0
    var artworkReady = 0
    var artworkSettled = false
}

enum LibraryFirstLoadStep: Int, CaseIterable, Comparable {
    case signedIn, findingGames, fetchingArtwork

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .signedIn: FirstLoadCopy.signedIn
        case .findingGames: FirstLoadCopy.findingGames
        case .fetchingArtwork: FirstLoadCopy.fetchingArtwork
        }
    }
}

/// The cold first-load state machine. It covers the window only after an interactive sign-in with no
/// library yet, hands over once the first screen is ready, and never blocks: Show library now appears
/// after `slowAfter`, and a failure offers Try Again.
struct LibraryFirstLoad: Equatable {
    enum Handover: Equatable { case ready, showNow, accountAction }
    enum Phase: Equatable {
        /// Waiting out the grace delay; nothing covers the window yet.
        case pending
        case inactive, loading, slow, failed(String), finished(Handover)
    }

    /// The first viewport: the hero plus the top rows of tiles.
    static let firstScreenSize = 8
    /// COR-213: fast loads never flash the setup view.
    static let graceDelay: Duration = .milliseconds(400)
    static let slowAfter: Duration = .seconds(20)

    private(set) var phase: Phase = .inactive
    private(set) var step: LibraryFirstLoadStep = .signedIn
    private(set) var startedAt: ContinuousClock.Instant?
    private var awaitingRetry = false

    var covers: Bool {
        switch phase {
        case .loading, .slow, .failed: true
        case .pending, .inactive, .finished: false
        }
    }
    /// Covering, or still inside the grace delay.
    var active: Bool { covers || phase == .pending }
    var failure: String? { if case let .failed(message) = phase { message } else { nil } }
    var offersShowNow: Bool { phase == .slow || failure != nil }

    /// COR-213: every confirmed sign-in, cold or restored, starts in the grace delay; nothing is
    /// cached between launches, so whether it ever covers depends only on how fast the library arrives.
    static func shouldBegin(signedIn: Bool) -> Bool { signedIn }

    static func gamesReady(_ inputs: LibraryFirstLoadInputs) -> Bool {
        inputs.gamesFound >= firstScreenSize || (inputs.libraryComplete && !inputs.loading)
    }

    static func firstScreenReady(_ inputs: LibraryFirstLoadInputs) -> Bool {
        gamesReady(inputs) && (inputs.gamesFound == 0 || inputs.artworkSettled
            || (inputs.artworkTotal > 0 && inputs.artworkReady >= inputs.artworkTotal))
    }

    /// `immediate` right after this run's own sign-in: the setup view covers at once, without the
    /// grace delay that only restored launches use.
    mutating func begin(at now: ContinuousClock.Instant, immediate: Bool = false) {
        phase = immediate ? .loading : .pending
        step = .findingGames
        startedAt = now
        awaitingRetry = false
    }

    mutating func update(_ inputs: LibraryFirstLoadInputs, now: ContinuousClock.Instant) {
        guard active else { return }
        guard inputs.signedIn else {
            self = Self()
            return
        }
        if awaitingRetry {
            guard inputs.loading || inputs.error == nil else {
                applyTimers(now)
                return
            }
            awaitingRetry = false
        }
        if inputs.needsAccountAction {
            phase = .finished(.accountAction)
            return
        }
        if let error = inputs.error, !inputs.loading, inputs.gamesFound == 0 {
            phase = .failed(error)
            return
        }
        step = Self.gamesReady(inputs) ? .fetchingArtwork : .findingGames
        if Self.firstScreenReady(inputs) {
            phase = .finished(.ready)
            return
        }
        if failure != nil { phase = .loading }
        applyTimers(now)
    }

    private mutating func applyTimers(_ now: ContinuousClock.Instant) {
        guard let startedAt else { return }
        let elapsed = startedAt.duration(to: now)
        if phase == .pending, elapsed >= Self.graceDelay { phase = .loading }
        if phase == .loading, elapsed >= Self.slowAfter { phase = .slow }
    }

    mutating func showLibraryNow() {
        guard active else { return }
        phase = .finished(.showNow)
    }

    /// Try Again restarts the wait; the old error is ignored until the new load starts.
    mutating func retry(at now: ContinuousClock.Instant) {
        guard failure != nil else { return }
        phase = .loading
        step = .findingGames
        startedAt = now
        awaitingRetry = true
    }

    /// VoiceOver hears step and state changes only, never the rotating lines or each count.
    static func announcement(from old: Self, to new: Self) -> String? {
        if old.phase == new.phase && old.step == new.step { return nil }
        switch new.phase {
        case .inactive, .pending: return nil
        case .failed(let message): return old.failure == message ? nil : "\(FirstLoadCopy.failedTitle). \(message)"
        case .finished(.ready): return old.covers ? FirstLoadCopy.ready : nil
        case .finished: return nil
        case .slow: return old.phase == .slow ? (old.step == new.step ? nil : new.step.title) : FirstLoadCopy.slow
        case .loading:
            let continuing = old.phase == .loading || old.phase == .slow
            return continuing && old.step == new.step ? nil : new.step.title
        }
    }
}

/// Reduce Motion keeps the overlay still: no spinner and at most a crossfade between lines.
struct LibraryFirstLoadMotion: Equatable {
    enum LineChange: Equatable { case slide, crossfade }
    let reduceMotion: Bool

    var lineChange: LineChange { reduceMotion ? .crossfade : .slide }
    var showsSpinner: Bool { !reduceMotion }
    var lineTransition: AnyTransition {
        reduceMotion ? .opacity : .push(from: .bottom)
    }
    static let lineInterval: Duration = .milliseconds(2800)
}

/// Timestamps for the cold path, logged as `first-load <event> elapsedMs=<n>` from sign-in.
@MainActor
enum FirstLoadTimeline {
    private static var start: ContinuousClock.Instant?
    private static var marked = Set<String>()
    private static let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "first-load")

    /// Milliseconds since this process started, for launch-path events before sign-in is confirmed.
    static func launchMark(_ event: String) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return }
        let started = info.kp_proc.p_starttime
        let launch = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let milliseconds = Int((Date().timeIntervalSince1970 - launch) * 1000)
        logger.notice("first-load \(event, privacy: .public) sinceLaunchMs=\(milliseconds)")
    }

    static func begin(_ kind: String) {
        start = .now
        marked = []
        logger.notice("first-load signInConfirmed kind=\(kind, privacy: .public) elapsedMs=0")
    }

    static func mark(_ event: String, _ detail: String = "") {
        guard let start, marked.insert(event).inserted else { return }
        let elapsed = start.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        logger.notice("first-load \(event, privacy: .public) elapsedMs=\(milliseconds) \(detail, privacy: .public)")
    }
}

/// Progress for the first viewport's artwork: the hero image (also the backdrop) and the top tiles'
/// covers, in the grid's display order. Settled images are kept per image, so a changing first
/// screen only fetches what's new, and a superseded run can't count toward the current one.
struct FirstScreenArtwork: Equatable {
    struct Item: Hashable {
        enum Kind: String { case hero, cover }
        let kind: Kind
        let id: String
        let reference: CatalogArtworkReference?
        /// Whether the descriptor read for this game has finished, so a missing reference is final.
        var resolved = true
        var key: String { "\(kind.rawValue):\(reference?.url ?? id)" }
    }

    /// A game's descriptor is final once loaded, failed, or requested and no longer pending — a
    /// dropped (e.g. PACKAGE_UNAVAILABLE) descriptor counts as resolved and uses fallback art.
    static func resolved(loaded: Bool, failed: Bool, requested: Bool, pending: Bool) -> Bool {
        loaded || failed || (requested && !pending)
    }

    private(set) var items: [Item] = []
    private(set) var settledKeys = Set<String>()
    private(set) var generation = 0
    private(set) var targeted = false

    var total: Int { items.count }
    var ready: Int { items.filter { settledKeys.contains($0.key) }.count }
    var settled: Bool { targeted && ready == total && items.allSatisfy { $0.reference != nil || $0.resolved } }
    /// Items still to fetch for the current first screen.
    var pending: [Item] { items.filter { $0.reference != nil && !settledKeys.contains($0.key) } }

    /// Sets the current first screen and returns the generation that may settle it.
    mutating func target(_ next: [Item]) -> Int {
        var seen = Set<String>()
        items = next.filter { seen.insert($0.key).inserted }
        for item in items where item.reference == nil && item.resolved { settledKeys.insert(item.key) }
        targeted = true
        generation &+= 1
        return generation
    }

    /// Records a finished image; a result from a superseded run is ignored.
    @discardableResult
    mutating func settle(_ item: Item, generation token: Int) -> Bool {
        guard token == generation, items.contains(item) else { return false }
        return settledKeys.insert(item.key).inserted
    }
}

struct LibraryFirstLoadView: View {
    let state: LibraryFirstLoad
    let inputs: LibraryFirstLoadInputs
    let showNow: () -> Void
    let tryAgain: () -> Void
    var lineIndex: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0
    @AccessibilityFocusState private var titleFocused: Bool

    private var motion: LibraryFirstLoadMotion { LibraryFirstLoadMotion(reduceMotion: reduceMotion) }
    private var line: String { FirstLoadCopy.lines[(lineIndex ?? rotation) % FirstLoadCopy.lines.count] }

    var body: some View {
        VStack(spacing: 26) {
            XOdeLockup(markSize: 56, wordmarkFont: .title.weight(.medium))
            if let failure = state.failure {
                failed(failure)
            } else {
                progress
            }
        }
        .padding(48)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xodus.firstLoad")
        // VoiceOver lands on the setup view, not the library it covers.
        .onAppear { titleFocused = true }
        .task(id: reduceMotion) {
            guard lineIndex == nil else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: LibraryFirstLoadMotion.lineInterval) } catch { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth) { rotation &+= 1 }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(FirstLoadCopy.title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("xodus.firstLoad.title")
                .accessibilityFocused($titleFocused)
            VStack(alignment: .leading, spacing: 12) {
                stepRow(.signedIn, detail: nil)
                stepRow(.findingGames, detail: FirstLoadCopy.found(inputs.gamesFound))
                stepRow(.fetchingArtwork, detail: state.step == .fetchingArtwork
                        ? FirstLoadCopy.artwork(ready: inputs.artworkReady, of: inputs.artworkTotal) : nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Text(line)
                    .id(line)
                    .transition(motion.lineTransition)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .clipped()
            .accessibilityHidden(true)
            .accessibilityIdentifier("xodus.firstLoad.line")
            if state.offersShowNow {
                VStack(spacing: 10) {
                    Text(FirstLoadCopy.slow)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button(FirstLoadCopy.showNow, action: showNow)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("xodus.firstLoad.showNow")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(FirstLoadCopy.failedTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("xodus.firstLoad.failedTitle")
            Text(message)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("xodus.firstLoad.error")
            HStack(spacing: 12) {
                Button(FirstLoadCopy.showNow, action: showNow)
                    .accessibilityIdentifier("xodus.firstLoad.showNow")
                Button(FirstLoadCopy.tryAgain, action: tryAgain)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("xodus.firstLoad.tryAgain")
            }
        }
    }

    private func stepRow(_ step: LibraryFirstLoadStep, detail: String?) -> some View {
        let done = step < state.step
        let active = step == state.step
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active && motion.showsSpinner {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: active ? "circle.dotted" : "circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(done || active ? .primary : .secondary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : active ? "In progress" : "Not started")
        .accessibilityIdentifier("xodus.firstLoad.step.\(step.rawValue)")
    }
}

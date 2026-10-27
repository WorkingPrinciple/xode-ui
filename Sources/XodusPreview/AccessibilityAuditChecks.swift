// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import AppKit
import SwiftUI
import Vision

/// REQ-18/19/20/41 source-side accessibility audit: names of icon-only controls, rendered text contrast over
/// the actual composites in light and dark appearance, and reviewed motion, transparency, focus and
/// remove/uninstall inventories. Detached views in a never-shown offscreen window; no global preference is
/// read or changed and no game, account or network action starts. These checks do not replace live VoiceOver, Full Keyboard Access or physical-input verification (docs/A11Y-VERIFICATION.md).
@MainActor
enum AccessibilityAuditChecks {
    static func run(check: (Bool, String) -> Void) {
        accessibilityNames(check: check)
        ownedColours(check: check)
        renderedContrast(check: check)
        toolbarOverArtwork(check: check)
        motionAndTransparency(check: check)
        keyboardFocus(check: check)
        lifecycleConsent(check: check)
        LibraryContentStatus.checkAll(check)
    }

    // MARK: Hosting

    /// Hosts the view in an unordered, never-shown offscreen window so system colours composite as in the app
    /// (window-less hosting under-reports secondary text). The caller keeps the window alive while sampling.
    private static func host<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name)
        -> (NSHostingView<AnyView>, NSWindow) {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let host = NSHostingView(rootView: AnyView(view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        host.display()
        return (host, window)
    }

    private static func audited() -> [(String, AnyView, CGSize)] {
        [
            ("Sign-in", AnyView(LiveWelcomeView(session: LiveSession(), runtime: RuntimeProviderSettings(),
                operations: GameOperationsController(installed: InstalledGamesController()))
                .environmentObject(AppState())), CGSize(width: 560, height: 620)),
            ("Acknowledgments", AnyView(AppAcknowledgmentsView(inventory: AcknowledgmentsInventory())),
             CGSize(width: 860, height: 1100)),
            ("Permissions", AnyView(Form { PrivacyPermissionsSection() }.formStyle(.grouped)),
             CGSize(width: 600, height: 1100))
        ]
    }

    // MARK: REQ-19 accessibility names

    /// Offscreen SwiftUI builds no accessibility tree without an assistive client (see toolbarAccessibility),
    /// so names are audited in source: a button whose whole label is an image must name itself, and the
    /// featured credit links announce whose site they open. Live VoiceOver remains the acceptance step.
    static func iconOnlyButtons(_ lines: [(file: String, line: Int, text: String)]) -> [(site: String, named: Bool)] {
        var result: [(String, Bool)] = []
        for (index, entry) in lines.enumerated() {
            let text = entry.text.trimmingCharacters(in: .whitespaces)
            func line(_ offset: Int) -> String {
                let i = index + offset
                guard i < lines.count, lines[i].file == entry.file else { return "" }
                return lines[i].text.trimmingCharacters(in: .whitespaces)
            }
            let inline = text.range(of: #"Button(\([^)]*\))?\s*\{\s*Image\("#, options: .regularExpression) != nil
                || text.range(of: #"label:\s*\{\s*Image\([^{]*\}\s*$"#, options: .regularExpression) != nil
            let block = text.range(of: #"^\}?\s*label:\s*\{$"#, options: .regularExpression) != nil
                && line(1).hasPrefix("Image(") && line(2).hasPrefix("}")
            guard inline || block else { continue }
            let following = (0..<16).map(line).joined(separator: "\n")
            result.append(("\(entry.file):\(entry.line)", following.contains(".accessibilityLabel(")))
        }
        return result
    }

    static func accessibilityNames(check: (Bool, String) -> Void) {
        let lines = sourceLines()
        let icons = iconOnlyButtons(lines)
        let unnamed = icons.filter { !$0.named }.map(\.site)
        let probe: [(file: String, line: Int, text: String)] = [
            ("Probe.swift", 1, "Button {"), ("Probe.swift", 2, "    go()"), ("Probe.swift", 3, "} label: {"),
            ("Probe.swift", 4, "    Image(systemName: \"play\")"), ("Probe.swift", 5, "}")
        ]
        check(!icons.isEmpty && unnamed.isEmpty && iconOnlyButtons(probe).map(\.named) == [false],
              "REQ-19: Every icon-only button names itself for VoiceOver (\(icons.count) sites; unnamed: \(unnamed)); the audit detects an unnamed probe")
        let acknowledgments = (try? String(contentsOfFile: "Sources/XodusPreview/Acknowledgments.swift", encoding: .utf8)) ?? ""
        let welcome = (try? String(contentsOfFile: "Sources/XodusPreview/LiveWelcomeView.swift", encoding: .utf8)) ?? ""
        check(acknowledgments.contains(".accessibilityLabel(\"\\(credit.name) website, \\(credit.linkText)\")")
              && FeaturedCredits.all.map(\.name) == ["Wine", "Xodus"]
              && welcome.contains(".accessibilityLabel(WelcomeCopy.acknowledgmentsAccessibility)"),
              "REQ-19/122: VoiceOver names the featured Wine and Xodus links by project, and the sign-in Acknowledgments link by purpose")
    }

    // MARK: REQ-19/20 rendered contrast

    struct Measurement {
        let text: String
        let ratio: Double
        let required: Double
    }

    private static func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double? {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    /// Measures each recognized line against its own backing: the backing is the most common luminance in the
    /// line's box and the text is the 98th-percentile luminance distance from it, so anti-aliasing and
    /// surrounding fills do not count as text. Lines at least 18 points tall need 3:1, others 4.5:1 (WCAG 1.4.3).
    static func measure(_ bitmap: NSBitmapImageRep, scale: Double) throws -> [Measurement] {
        guard let image = bitmap.cgImage else { return [] }
        return try NativeCheckOCR.observations(image).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  text.count >= 3, observation.confidence >= 0.5 else { return nil }
            let box = observation.boundingBox
            let x0 = max(0, Int(box.minX * Double(bitmap.pixelsWide)))
            let x1 = min(bitmap.pixelsWide, Int(ceil(box.maxX * Double(bitmap.pixelsWide))))
            let y0 = max(0, Int((1 - box.maxY) * Double(bitmap.pixelsHigh)))
            let y1 = min(bitmap.pixelsHigh, Int(ceil((1 - box.minY) * Double(bitmap.pixelsHigh))))
            guard x1 > x0, y1 > y0 else { return nil }
            var values: [Double] = []
            values.reserveCapacity((x1 - x0) * (y1 - y0))
            for y in y0..<y1 { for x in x0..<x1 { if let value = luminance(bitmap, x: x, y: y) { values.append(value) } } }
            guard values.count > 16 else { return nil }
            var histogram = [Int](repeating: 0, count: 64)
            for value in values { histogram[min(63, Int(value * 64))] += 1 }
            let mode = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
            let backing = values.filter { min(63, Int($0 * 64)) == mode }.reduce(0, +)
                / Double(max(1, histogram[mode]))
            let distances = values.map { abs($0 - backing) }.sorted()
            let distance = distances[Int(Double(distances.count - 1) * 0.98)]
            let candidates = values.filter { abs(abs($0 - backing) - distance) < 0.000_001 }
            let foreground = candidates.first ?? backing
            let ratio = (max(backing, foreground) + 0.05) / (min(backing, foreground) + 0.05)
            let points = Double(y1 - y0) / scale
            return Measurement(text: text, ratio: ratio, required: points >= 24 ? 3 : 4.5)
        }
    }

    /// Hard floor 3:1 for every rendered line (WCAG 1.4.3 large text and 1.4.11 non-text). Lines between 3:1 and
    /// 4.5:1 are REQ-19 gaps: they are listed in the result and written to the render directory, never passed
    /// silently. Increase Contrast is not simulated here: an injected high-contrast appearance does not reproduce
    /// the system setting, so it stays a live REQ-20 step.
    /// Native search-field placeholders still in the system placeholder colour, reported as gaps rather than
    /// failed. None: the Acknowledgments search field draws its own prompt in AccessiblePalette.placeholder.
    static let systemPlaceholders: [String] = []

    /// No file is exempt: Library/Discover links adopted the palette at integration.
    static let routedLinkFiles: Set<String> = []

    static func ownedColours(check: (Bool, String) -> Void) {
        func ratio(_ a: AccessiblePalette.RGB, _ b: AccessiblePalette.RGB) -> Double {
            BrandUXChecks.contrast(a.color, against: b.color)
        }
        let light = [AccessiblePalette.RGB(red: 255, green: 255, blue: 255), .init(red: 0xEC, green: 0xEC, blue: 0xEC),
                     .init(red: 0xE5, green: 0xE5, blue: 0xE5)]
        let dark = [AccessiblePalette.RGB(red: 0x1E, green: 0x1E, blue: 0x1E), .init(red: 0x2A, green: 0x2A, blue: 0x2A),
                    .init(red: 0x32, green: 0x32, blue: 0x32)]
        let worst = [light.map { ratio(AccessiblePalette.linkLight, $0) }, light.map { ratio(AccessiblePalette.placeholderLight, $0) },
                     dark.map { ratio(AccessiblePalette.linkDark, $0) }, dark.map { ratio(AccessiblePalette.placeholderDark, $0) }]
            .map { $0.min() ?? 0 }
        check(worst.allSatisfy { $0 >= 4.5 }
              && AccessiblePalette.link.resolved(.darkAqua) == AccessiblePalette.linkDark.color.usingColorSpace(.sRGB)
              && AccessiblePalette.link.resolved(.aqua) == AccessiblePalette.linkLight.color.usingColorSpace(.sRGB),
              "REQ-19: X Ode's own link and placeholder colours reach 4.5:1 on window, form and field backings in both appearances (worst \(worst.map { String(format: "%.2f", $0) }))")
        let lines = sourceLines()
        let bare = lines.filter { entry in
            !routedLinkFiles.contains(entry.file)
                && (entry.text.range(of: #"(^|[^A-Za-z_])Link\("#, options: .regularExpression) != nil
                    || entry.text.contains(".buttonStyle(.link)"))
                && !lines.filter({ $0.file == entry.file && $0.line >= entry.line && $0.line <= entry.line + 2 })
                    .contains { $0.text.contains(".accessibleLink()") }
        }
        check(bare.isEmpty,
              "REQ-19: Every link uses the accessible link colour (bare: \(bare.map { "\($0.file):\($0.line)" }))")
    }

    static func renderedContrast(check: (Bool, String) -> Void) {
        var gaps: [String] = []
        for (name, view, size) in audited() {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (host, window) = host(view, size: size, appearance: appearance)
                defer { window.contentView = nil }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    check(false, "REQ-19: \(name) renders in \(suffix)")
                    continue
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                BrandUXChecks.save(bitmap, name: "a11y-contrast-\(name.lowercased())-\(suffix)")
                do {
                    let measured = try measure(bitmap, scale: Double(bitmap.pixelsWide) / Double(size.width))
                    let placeholder = { (m: Measurement) in systemPlaceholders.contains { m.text.contains($0) } }
                    let floor = measured.filter { $0.ratio < 3 && !placeholder($0) }
                    gaps += measured.filter { ($0.ratio >= 3 || placeholder($0)) && $0.ratio < $0.required }
                        .map { "\(name) \(suffix): \($0.text.prefix(48)) \(String(format: "%.2f", $0.ratio)):1" }
                    check(measured.count >= 3 && floor.isEmpty && !window.isVisible,
                          "REQ-19/20: Rendered \(name) text stays at or above 3:1 in \(suffix) (\(measured.count) lines; below: \(floor.map { "\($0.text) \(String(format: "%.2f", $0.ratio))" }))")
                } catch {
                    check(false, "REQ-19/20: \(name) contrast OCR in \(suffix): \(error.localizedDescription)")
                }
            }
        }
        if let directory = BrandUXChecks.renderDirectory {
            try? gaps.joined(separator: "\n").write(to: directory.appendingPathComponent("req19-contrast-gaps.txt"),
                                                    atomically: true, encoding: .utf8)
        }
        print("REQ-19 contrast gaps (3:1 to 4.5:1, reported, not passed): \(gaps.count)\n  " + gaps.joined(separator: "\n  "))
    }

    // MARK: REQ-19 toolbar over scrolled artwork

    /// Build 624 showed the section labels at 1.19-1.27:1 over scrolled Library artwork. This renders the real
    /// section picker inside NativeToolbarMaterial over white, black and busy artwork, in light and dark, and
    /// requires every section label to reach 4.5:1 against its own backing.
    static func toolbarOverArtwork(check: (Bool, String) -> Void) {
        let artwork = ArtAssets.images.sorted { $0.key < $1.key }.prefix(2).map { AnyView(Image(nsImage: $0.value).resizable().scaledToFill()) }
        let backdrops: [(String, AnyView)] = [("white", AnyView(Color.white)), ("black", AnyView(Color.black))]
            + artwork.enumerated().map { ("artwork\($0.offset)", $0.element) }
        check(backdrops.count == 4, "REQ-19: toolbar contrast uses white, black and two real artworks as backdrops")
        let labels = Destination.allCases.map(\.rawValue)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, backdrop) in backdrops {
                let view = ZStack {
                    backdrop.frame(width: 520, height: 120).clipped()
                    XodusToolbar.navigationPicker(selection: .constant(.library)).fixedSize()
                        .modifier(NativeToolbarMaterial())
                }
                .frame(width: 520, height: 120)
                let (host, window) = host(view, size: CGSize(width: 520, height: 120), appearance: appearance)
                defer { window.contentView = nil }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    check(false, "REQ-19: toolbar renders over \(name) (\(suffix))"); continue
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                BrandUXChecks.save(bitmap, name: "req19-toolbar-\(name)-\(suffix)")
                let measured = (try? measure(bitmap, scale: Double(bitmap.pixelsWide) / 520)) ?? []
                let sections = measured.filter { m in labels.contains { m.text.localizedCaseInsensitiveContains($0) } }
                let lowest = sections.map(\.ratio).min() ?? 0
                check(sections.count >= 2 && lowest >= 4.5 && !window.isVisible,
                      "REQ-19: Toolbar section labels over \(name) in \(suffix) reach 4.5:1 (\(sections.map { "\($0.text) \(String(format: "%.2f", $0.ratio))" }))")
            }
        }
    }

    // MARK: REQ-20 motion and transparency

    /// Reviewed motion and material sites that do not test Reduce Motion / Reduce Transparency inline, with why
    /// each is acceptable. A new ungated site fails until it is gated or reviewed here.
    static let reviewedMotion: [String: String] = [
        "LiveLibraryView.swift|withAnimation(.smooth(duration: 0.6)) { selection.heroID = next }":
            "Hero auto-advance task returns early when Reduce Motion, VoiceOver or Low Power is on",
        "LiveRootView.swift|.transition(.opacity)": "Opacity dissolve; Apple's Reduce Motion guidance keeps fades",
        "LiveRootView.swift|.animation(.easeInOut(duration: 0.3), value: firstLoadCovers)":
            "Drives only the opacity dissolve of the first-load cover",
        "LibraryFirstLoad.swift|.transition(motion.lineTransition)": "LibraryFirstLoadMotion swaps to opacity under Reduce Motion"
    ]

    static let reviewedMaterials: [String: String] = [
        "InstalledGamesView.swift|.background(.regularMaterial)": "System material; macOS makes it opaque under Reduce Transparency",
        "LiveCatalogView.swift|.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))":
            "System material; macOS makes it opaque under Reduce Transparency"
    ]

    static func sourceLines() -> [(file: String, line: Int, text: String)] {
        let directory = "Sources/XodusPreview/"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".swift") && !$0.contains("Checks") }.sorted()
        return files.flatMap { file -> [(String, Int, String)] in
            let text = (try? String(contentsOfFile: directory + file, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").enumerated().map { (file, $0.offset + 1, $0.element) }
        }
    }

    static func motionAndTransparency(check: (Bool, String) -> Void) {
        let lines = sourceLines()
        check(lines.count > 1_000, "REQ-20: Motion audit reads the app sources (\(lines.count) lines)")
        let motion = lines.filter { entry in
            ["withAnimation(", ".animation(", "repeatForever", ".symbolEffect(", ".transition("]
                .contains { entry.text.contains($0) }
                && !entry.text.contains("reduceMotion ?") && !entry.text.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let unreviewed = motion.filter { entry in
            !reviewedMotion.keys.contains("\(entry.file)|\(entry.text.trimmingCharacters(in: .whitespaces))")
        }
        check(unreviewed.isEmpty,
              "REQ-20: Every animation honours Reduce Motion inline or is a reviewed exception (unreviewed: \(unreviewed.map { "\($0.file):\($0.line)" }))")
        let materials = lines.filter { entry in
            [".regularMaterial", ".thinMaterial", ".ultraThinMaterial", ".thickMaterial", ".glassEffect("]
                .contains { entry.text.contains($0) }
        }
        let materialFiles = Set(materials.map(\.file))
        let ungated = materials.filter { entry in
            let file = lines.filter { $0.file == entry.file }.map(\.text).joined(separator: "\n")
            return !file.contains("accessibilityReduceTransparency")
                && !reviewedMaterials.keys.contains("\(entry.file)|\(entry.text.trimmingCharacters(in: .whitespaces))")
        }
        check(!materialFiles.isEmpty && ungated.isEmpty,
              "REQ-20: Translucent materials and glass are gated on Reduce Transparency or are reviewed system materials (ungated: \(ungated.map { "\($0.file):\($0.line)" }))")
        let glass = (try? String(contentsOfFile: "Sources/XodusPreview/NativeGlass.swift", encoding: .utf8)) ?? ""
        check(glass.components(separatedBy: "if reduceTransparency").count >= 2
              && glass.contains("reduceTransparency || reviewReduceTransparency"),
              "REQ-20: NativeGlass and the toolbar fall back to opaque backgrounds under Reduce Transparency")
    }

    // MARK: REQ-41 remove versus uninstall

    static func lifecycleConsent(check: (Bool, String) -> Void) {
        let view = (try? String(contentsOfFile: "Sources/XodusPreview/GameOperationsView.swift", encoding: .utf8)) ?? ""
        let attention = (try? String(contentsOfFile: "Sources/XodusPreview/InstalledGameAttentionView.swift", encoding: .utf8)) ?? ""
        let management = view.range(of: "struct InstalledGameManagement").map { start -> String in
            let rest = view[start.lowerBound...]
            let end = rest.dropFirst().range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        } ?? ""
        let host = view.range(of: "struct GameOperationPresentation").map { String(view[$0.lowerBound...].prefix(2_400)) } ?? ""
        let controller = (try? String(contentsOfFile: "Sources/XodusPreview/GameOperationsController.swift", encoding: .utf8)) ?? ""
        let message = InstalledGameActionCopy.removeKeepingFilesMessage(folder: "/Volumes/Games/Halls")
        // Menu and context-menu content cannot present dialogs, so the item only asks the controller and the
        // always-mounted GameOperationPresentation shows the confirmation (as for Uninstall).
        check(management.contains("Button(InstalledGameActionCopy.removeKeepingFiles) { operations.prepareRemoval(game) }")
              && !management.contains("library.remove(") && !management.contains(".confirmationDialog(")
              && host.contains("presenting: operations.removalConsent") && host.contains("operations.confirmRemoval(game)")
              && controller.contains("@Published var removalConsent: InstalledGame?")
              && !view.contains("\"Remove from list\"")
              && attention.contains("InstalledGameActionCopy.removeKeepingFilesConfirm")
              && message.contains("No files are deleted") && message.contains("/Volumes/Games/Halls")
              && message.contains("use Uninstall") && InstalledGameActionCopy.removeKeepingFiles.contains("Keep Files"),
              "REQ-41: Remove from Library keeps files, says so and confirms from a mounted host (menus cannot present dialogs); it never deletes")
        let consent = view.range(of: "Text(\"Uninstall \\(game.title)?\")").map { String(view[$0.lowerBound...].prefix(1_200)) } ?? ""
        check(consent.contains("Deletes this game's installation folder") && consent.contains("Deletes the game files")
              && consent.contains("Button(\"Cancel\")") && consent.contains(".keyboardShortcut(.cancelAction)")
              && !consent.contains(".keyboardShortcut(.defaultAction)") && consent.contains("role: .destructive"),
              "REQ-41: Uninstall consent names the deletion, Escape cancels and Return never confirms the destructive action")
    }

    // MARK: REQ-18 keyboard focus

    /// Reviewed `.focusable()` sites. Each must carry an accessibility name; Return must activate the ones that
    /// make a plain-style button a keyboard stop without Full Keyboard Access.
    static let reviewedFocusGaps: [String: String] = [
        "LiveLibraryView.swift|focused($focusedGameID, equals: \"installed-\\(game.id)\")":
            "Installed shelf artwork: no Return handler (Space activates under Full Keyboard Access only); routed to the Library views owner"
    ]

    static func keyboardFocus(check: (Bool, String) -> Void) {
        let lines = sourceLines()
        var unlabeled: [String] = []
        var noReturn: [String] = []
        for (index, entry) in lines.enumerated() where entry.text.trimmingCharacters(in: .whitespaces) == ".focusable()" {
            let window = lines[max(0, index - 12)...min(lines.count - 1, index + 10)].filter { $0.file == entry.file }
            let chain = window.map(\.text).joined(separator: "\n")
            if !chain.contains(".accessibilityLabel(") { unlabeled.append("\(entry.file):\(entry.line)") }
            let isButton = chain.contains(".buttonStyle(.plain)")
            let focused = lines[min(lines.count - 1, index + 1)].text.trimmingCharacters(in: .whitespaces)
            let reviewed = reviewedFocusGaps.keys.contains { $0 == "\(entry.file)|\(focused.dropFirst())" }
            if isButton, !chain.contains(".onKeyPress(.return"), !reviewed { noReturn.append("\(entry.file):\(entry.line)") }
        }
        check(unlabeled.isEmpty,
              "REQ-18/19: Every extra keyboard stop (.focusable) carries its own accessibility name (unlabeled: \(unlabeled))")
        check(noReturn.isEmpty,
              "REQ-18: Focusable plain buttons open with Return, or are reviewed routed gaps (\(reviewedFocusGaps.values.joined(separator: "; "))); missing: \(noReturn)")
    }
}
private extension NSColor {
    func resolved(_ name: NSAppearance.Name) -> NSColor? {
        var color: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) }
        return color
    }
}
#endif

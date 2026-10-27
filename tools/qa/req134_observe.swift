// SPDX-License-Identifier: GPL-3.0-only
// REQ-134 on-screen observer for an installed X Ode build. Reads accessibility trees, captures windows,
// measures rendered contrast and collects load signposts. It never synthesizes key or mouse events: the only
// state changes are allow-listed AX actions (AXPress, AXValue on the search field, AXScrollByPage, AXSize on
// the main window, AXRaise plus activation when the owner is idle), each refused unless the owner has been idle (COR-272). It never presses Play, Install,
// Download, Uninstall, Remove, Repair, Update, Sign in/out, Approve, Delete, Stop or Cancel.
//
//   swift tools/qa/req134_observe.swift preflight OUT
//   swift tools/qa/req134_observe.swift snapshot OUT LABEL
//   swift tools/qa/req134_observe.swift press OUT IDENTIFIER|label:TEXT|menu:Item
//   swift tools/qa/req134_observe.swift set-search OUT TEXT
//   swift tools/qa/req134_observe.swift scroll OUT up|down PAGES     (AXScrollUp/DownByPage on the main scroll area)
//   swift tools/qa/req134_observe.swift resize OUT WIDTH HEIGHT
//   swift tools/qa/req134_observe.swift quit OUT                    (normal Quit, never forced)
//   swift tools/qa/req134_observe.swift close-window OUT Engines|Acknowledgments|…   (auxiliary windows only)
//   swift tools/qa/req134_observe.swift contrast OUT PNG
//   swift tools/qa/req134_observe.swift signposts OUT MINUTES
//
// Environment: XODE_APP (default ~/Applications/Ode to X Local Candidate.app), XODE_EXPECTED_SHA256 (refuse a
// different executable), XODE_IDLE_SECONDS (default 20). Exit 3 = refused by a guard, 2 = failure.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Vision

// MARK: Plumbing

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("req134: " + message + "\n").utf8))
    exit(code)
}

func refuse(_ message: String) -> Never { fail("REFUSED: " + message, code: 3) }

let environment = ProcessInfo.processInfo.environment
let appURL = URL(fileURLWithPath: environment["XODE_APP"]
    ?? (NSHomeDirectory() + "/Applications/Ode to X Local Candidate.app"))
let bundleIdentifier = "io.github.dragoshont.xodus.development"
let idleSeconds = Double(environment["XODE_IDLE_SECONDS"] ?? "20") ?? 20
let stamp: String = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}()

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage: see header of tools/qa/req134_observe.swift") }
let command = arguments.removeFirst()
let outDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

/// AX can report NaN or infinite geometry for offscreen or collapsed elements; JSON has no such numbers.
func sanitized(_ value: Any) -> Any {
    switch value {
    case let number as Double: return number.isFinite ? number : NSNull()
    case let number as CGFloat: return Double(number).isFinite ? Double(number) : NSNull()
    case let dictionary as [String: Any]: return dictionary.mapValues(sanitized)
    case let array as [Any]: return array.map(sanitized)
    case is String, is Bool, is Int, is NSNull: return value
    case let number as NSNumber: return number.doubleValue.isFinite ? number : NSNull()
    default: return String(describing: value)
    }
}

func write(_ raw: Any, _ name: String) {
    let object = sanitized(raw)
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { fail("could not encode \(name)") }
    do { try data.write(to: outDirectory.appendingPathComponent(name)) } catch { fail("could not write \(name): \(error)") }
}

func appendLog(_ line: String) {
    let url = outDirectory.appendingPathComponent("actions.log")
    let entry = Data("\(stamp) \(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
    } else {
        try? entry.write(to: url)
    }
}

func sha256(_ url: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: " ").first.map(String.init)
}

// MARK: Identity and guards

func executableURL() -> URL {
    guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
          let name = info["CFBundleExecutable"] as? String else { fail("no Info.plist at \(appURL.path)") }
    return appURL.appendingPathComponent("Contents/MacOS/" + name)
}

func identity() -> [String: Any] {
    let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
    let receiptURL = appURL.appendingPathComponent("Contents/Resources/local-candidate-receipt.json")
    let receipt = (try? JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))) as? [String: Any]
    let source = receipt?["appSource"] as? [String: Any]
    return [
        "app": appURL.path,
        "build": info["CFBundleVersion"] as? String ?? "",
        "version": info["CFBundleShortVersionString"] as? String ?? "",
        "bundleIdentifier": info["CFBundleIdentifier"] as? String ?? "",
        "executableSHA256": sha256(executableURL()) ?? "",
        "sourceCommit": source?["commit"] as? String ?? "",
        "sourceTree": source?["tree"] as? String ?? ""
    ]
}

func runningApp() -> NSRunningApplication {
    let executable = executableURL().resolvingSymlinksInPath().path
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { $0.executableURL?.resolvingSymlinksInPath().path == executable }
    guard matches.count == 1, let app = matches.first else {
        fail("expected exactly one running \(appURL.lastPathComponent); found \(matches.count). Open it from Finder first.")
    }
    if let expected = environment["XODE_EXPECTED_SHA256"], sha256(executableURL()) != expected {
        refuse("executable SHA-256 differs from XODE_EXPECTED_SHA256")
    }
    return app
}

func screenLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session["CGSSessionScreenIsLocked"] as? Int) == 1
}

func idle() -> (keyboard: Double, pointer: Double) {
    let state = CGEventSourceStateID.combinedSessionState
    let keyboard = min(CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown),
                       CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged))
    let pointer = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        .map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }.min() ?? 0
    return (keyboard, pointer)
}

/// COR-272: no app action while the owner is typing or using the pointer.
func requireIdle() {
    guard !screenLocked() else { refuse("screen is locked") }
    let now = idle()
    guard now.keyboard >= idleSeconds, now.pointer >= idleSeconds else {
        refuse(String(format: "owner active (keyboard %.0fs, pointer %.0fs ago; need %.0fs)", now.keyboard, now.pointer, idleSeconds))
    }
}

// MARK: Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func axElement(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    if let text = attribute(element, name) as? String { return text }
    if let number = attribute(element, name) as? NSNumber { return number.stringValue }
    return nil
}

func frame(_ element: AXUIElement) -> [String: Double]? {
    guard let positionValue = attribute(element, kAXPositionAttribute), let sizeValue = attribute(element, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return ["x": Double(point.x), "y": Double(point.y), "width": Double(size.width), "height": Double(size.height)]
}

func label(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { string(element, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
}

struct Node {
    let element: AXUIElement
    let path: String
    let record: [String: Any]
}

func walk(_ root: AXUIElement, limit: Int = 8_000) -> [Node] {
    var nodes: [Node] = []
    func visit(_ element: AXUIElement, _ path: String, _ depth: Int) {
        guard depth < 60, nodes.count < limit else { return }
        var record: [String: Any] = ["path": path]
        for (key, name) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("identifier", kAXIdentifierAttribute),
                            ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
                            ("value", kAXValueAttribute), ("help", kAXHelpAttribute), ("roleDescription", kAXRoleDescriptionAttribute)] {
            if let text = string(element, name), !text.isEmpty { record[key] = String(text.prefix(400)) }
        }
        if let enabled = attribute(element, kAXEnabledAttribute) as? Bool { record["enabled"] = enabled }
        if let focused = attribute(element, kAXFocusedAttribute) as? Bool, focused { record["focused"] = true }
        if let frame = frame(element) { record["frame"] = frame }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String], !names.isEmpty {
            record["actions"] = names
        }
        nodes.append(Node(element: element, path: path, record: record))
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for (index, child) in children.enumerated() { visit(child, "\(path)/\(index)", depth + 1) }
    }
    visit(root, "0", 0)
    return nodes
}

func application(_ app: NSRunningApplication) -> AXUIElement {
    guard AXIsProcessTrusted() else {
        refuse("this terminal is not trusted for Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility)")
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 2)
    return element
}

func windows(_ app: AXUIElement) -> [AXUIElement] { attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

func mainWindow(_ app: AXUIElement) -> AXUIElement {
    let all = windows(app)
    if let main = all.first(where: { string($0, kAXTitleAttribute) == "X Ode" }) { return main }
    guard let first = all.first else { fail("X Ode has no AX window") }
    return first
}

// MARK: Capture

func windowIDs(pid: pid_t) -> [(id: CGWindowID, title: String, bounds: [String: Double])] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let id = window[kCGWindowNumber as String] as? CGWindowID else { return nil }
        let bounds = (window[kCGWindowBounds as String] as? [String: Double]) ?? [:]
        return (id, window[kCGWindowName as String] as? String ?? "", bounds)
    }
}

func capture(pid: pid_t, label: String) -> [[String: Any]] {
    guard CGPreflightScreenCaptureAccess() else {
        refuse("this terminal lacks Screen Recording access (System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording)")
    }
    return windowIDs(pid: pid).enumerated().map { index, window in
        let file = outDirectory.appendingPathComponent("\(label)-window\(index).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.id), file.path]
        try? process.run()
        process.waitUntilExit()
        return ["windowID": Int(window.id), "title": window.title, "bounds": window.bounds, "png": file.lastPathComponent,
                "captured": FileManager.default.fileExists(atPath: file.path)]
    }
}

// MARK: Content scan (REQ-23/60/61/62)

let forbidden: [(String, String)] = [
    (#"[$€£]\s?\d"#, "price"), (#"\b(Buy|Pre-order|Purchase)\b"#, "commerce action"),
    (#"\bMSIXVC\b"#, "package jargon (allowed only in the detail Details group)"),
    (#"\b\d+(\.\d+)?\s?(GB|MB)\b"#, "size (allowed only in detail and real progress)"),
    (#"/Users/|/private/|\.json\b|\.log\b"#, "filesystem path"),
    (#"\b(WORKING|CLI-only|session [0-9a-f]{6,}|run[0-9a-f]{6,})\b"#, "QA journal text"),
    (#"(?<![0-9.,])\b(?=[0-9a-f]*[a-f])[0-9a-f]{12,}\b"#, "raw identifier or hash")
]

func scan(_ nodes: [Node]) -> [[String: Any]] {
    nodes.filter { !["AXScrollBar", "AXValueIndicator"].contains($0.record["role"] as? String ?? "") }
        .flatMap { node -> [[String: Any]] in
        let text = ["title", "description", "value", "help"].compactMap { node.record[$0] as? String }.joined(separator: " | ")
        return forbidden.compactMap { pattern, kind in
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            return ["kind": kind, "match": String(text[range]), "path": node.path, "role": node.record["role"] ?? "",
                    "identifier": node.record["identifier"] ?? "", "text": String(text.prefix(200))]
        }
    }
}

// MARK: Commands

func preferences() -> [String: Any] {
    let workspace = NSWorkspace.shared
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    return [
        "reduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
        "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
        "differentiateWithoutColor": workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
        "voiceOver": workspace.isVoiceOverEnabled,
        "switchControl": workspace.isSwitchControlEnabled,
        "appleInterfaceStyle": global["AppleInterfaceStyle"] as? String ?? "Light",
        "appleKeyboardUIMode": global["AppleKeyboardUIMode"] as? Int ?? 0
    ]
}

@discardableResult
func snapshot(_ rawLabel: String) -> [Node] {
    // The runner sets XODE_STEP so repeated actions (Library, Discover, scroll) never overwrite earlier evidence.
    let label = environment["XODE_STEP"].map { $0 + "-" + rawLabel } ?? rawLabel
    let app = runningApp()
    let ax = application(app)
    var windowsRecord: [[String: Any]] = []
    var allNodes: [Node] = []
    for (index, window) in windows(ax).enumerated() {
        let nodes = walk(window)
        allNodes += nodes
        windowsRecord.append(["index": index, "title": string(window, kAXTitleAttribute) ?? "",
                              "subrole": string(window, kAXSubroleAttribute) ?? "", "frame": frame(window) ?? [:],
                              "elements": nodes.count, "truncated": nodes.count >= 8_000])
        write(nodes.map(\.record), "\(label)-ax-window\(index).json")
    }
    let focused = axElement(attribute(ax, kAXFocusedUIElementAttribute)).flatMap { walk($0, limit: 1).first?.record } ?? [:]
    let captures = capture(pid: app.processIdentifier, label: label)
    let findings = scan(allNodes)
    write(["label": label, "at": stamp, "pid": Int(app.processIdentifier), "appActive": app.isActive, "identity": identity(),
           "preferences": preferences(), "windows": windowsRecord, "captures": captures,
           "focused": focused, "contentFindings": findings], "\(label)-snapshot.json")
    print("\(label): \(windowsRecord.count) windows, \(allNodes.count) AX elements, \(captures.count) captures, \(findings.count) content findings")
    return allNodes
}

let deniedWords = ["Play", "Install", "Download", "Uninstall", "Remove", "Repair", "Update", "Sign in", "Sign out",
                   "Sign In", "Sign Out", "Approve", "Delete", "Stop", "Cancel", "Buy", "Quit", "Discard", "Pause", "Resume",
                   "Ask Now", "Find consoles", "Choose", "Import", "Reset", "Clear"]
let allowedIdentifiers: Set<String> = [
    "xodus.navigation.library", "xodus.navigation.discover", "xodus.navigation.downloads", "xodus.navigation.home",
    "xodus.account", "xodus.catalog.openSearch", "xodus.library.continuePlaying.showAll", "xodus.library.back",
    "xodus.discover.hero.details", "xodus.welcome.acknowledgments", "xodus.library.openRecentActivity",
    "xodus.game.description.expand", "xodus.catalog.loadMore", "xodus.settings.general", "xodus.settings.engines",
    "xodus.settings.account", "xodus.support", "xodus.account.close"
]
let allowedMenuItems: Set<String> = ["Acknowledgments…", "Open-Source Licences…", "Settings…", "About X Ode",
                                     "Acknowledgments and Licences"]
let allowedLabels: Set<String> = ["Close", "Done", "OK", "Back"]

func isDenied(_ text: String) -> Bool { deniedWords.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil } }

func validate(_ target: String) {
    if target.hasPrefix("menu:") {
        guard allowedMenuItems.contains(String(target.dropFirst(5))) else { refuse("menu item \(target) is not allow-listed") }
    } else if target.hasPrefix("label:") {
        let text = String(target.dropFirst(6))
        guard allowedLabels.contains(text) || (text.hasPrefix("View ") && !isDenied(String(text.dropFirst(5)))) else {
            refuse("label \(text) is not allow-listed")
        }
    } else {
        guard allowedIdentifiers.contains(target) else { refuse("identifier \(target) is not allow-listed") }
    }
}

func press(_ target: String) {
    validate(target)
    requireIdle()
    let ax = application(runningApp())
    var candidates: [Node] = []
    if target.hasPrefix("menu:") {
        let item = String(target.dropFirst(5))
        guard allowedMenuItems.contains(item) else { refuse("menu item \(item) is not allow-listed") }
        guard let bar = axElement(attribute(ax, kAXMenuBarAttribute)) else { fail("no menu bar") }
        candidates = walk(bar).filter { ($0.record["title"] as? String) == item }
    } else {
        let nodes = windows(ax).flatMap { walk($0) }
        if target.hasPrefix("label:") {
            let text = String(target.dropFirst(6))
            let viewCard = text.hasPrefix("View ") && !isDenied(String(text.dropFirst(5)))
            guard allowedLabels.contains(text) || viewCard else { refuse("label \(text) is not allow-listed") }
            candidates = nodes.filter { node in
                ["title", "description"].contains { (node.record[$0] as? String) == text }
                    && (node.record["actions"] as? [String])?.contains(kAXPressAction) == true
            }
        } else {
            guard allowedIdentifiers.contains(target) else { refuse("identifier \(target) is not allow-listed") }
            candidates = nodes.filter { ($0.record["identifier"] as? String) == target }
        }
    }
    // A card can appear on a shelf and in the grid; identical labels open the same detail, so take the first.
    let duplicateLabels = target.hasPrefix("label:") && candidates.count > 1
    guard candidates.count == 1 || duplicateLabels, let node = candidates.first else {
        fail("expected exactly one AX match for \(target), found \(candidates.count)")
    }
    if duplicateLabels { appendLog("press target=\(target) matched \(candidates.count) identical labels; using \(node.path)") }
    let text = label(node.element)
    // AXPress on a disabled control reports success but does nothing; record that instead of a false step.
    if (node.record["enabled"] as? Bool) == false {
        appendLog("press target=\(target) label=\(text) path=\(node.path) skipped=disabled")
        snapshot("disabled-" + target.replacingOccurrences(of: "[^A-Za-z0-9.]+", with: "-", options: .regularExpression))
        fail("matched control '\(text)' is disabled")
    }
    if !target.hasPrefix("menu:"), !text.hasPrefix("View "), isDenied(text) { refuse("matched control '\(text)' is on the deny list") }
    let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    appendLog("press target=\(target) label=\(text) path=\(node.path) result=\(result.rawValue)")
    guard result == .success else { fail("AXPress failed (\(result.rawValue))") }
    Thread.sleep(forTimeInterval: 1.5)
    snapshot("after-press-" + target.replacingOccurrences(of: "[^A-Za-z0-9.]+", with: "-", options: .regularExpression))
}

func setSearch(_ text: String) {
    requireIdle()
    let ax = application(runningApp())
    let fields = windows(ax).flatMap { walk($0) }.filter { ($0.record["identifier"] as? String) == "xodus.catalog.search" }
    guard fields.count == 1, let field = fields.first else { fail("expected one search field, found \(fields.count)") }
    let result = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, text as CFString)
    appendLog("set-search value=\(text) result=\(result.rawValue)")
    guard result == .success else { fail("AXValue on the search field failed (\(result.rawValue)); use the owner sheet step") }
    Thread.sleep(forTimeInterval: 2.5)
    snapshot("after-search-" + text.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression))
}

/// Scrolls the tallest scroll area of the main window by pages with AXScrollDownByPage/AXScrollUpByPage.
/// SwiftUI scroll views with hidden indicators (REQ-91) expose no scroll bar, so AXValue cannot be used.
func scroll(_ direction: String, pages: Int) {
    requireIdle()
    let ax = application(runningApp())
    func height(_ node: Node) -> Double { (node.record["frame"] as? [String: Double])?["height"] ?? 0 }
    let action = direction == "up" ? "AXScrollUpByPage" : "AXScrollDownByPage"
    let areas = walk(mainWindow(ax)).filter {
        ($0.record["role"] as? String) == kAXScrollAreaRole && (($0.record["actions"] as? [String])?.contains(action) ?? false)
    }.sorted { height($0) > height($1) }
    guard let area = areas.first else { fail("no scroll area with \(action) in the main window") }
    for _ in 0..<max(1, pages) {
        let result = AXUIElementPerformAction(area.element, action as CFString)
        appendLog("scroll \(action) area=\(area.path) result=\(result.rawValue)")
        guard result == .success else { fail("\(action) failed (\(result.rawValue))") }
        Thread.sleep(forTimeInterval: 0.6)
    }
    snapshot("after-scroll-\(direction)-\(pages)")
}

func resize(_ width: Double, _ height: Double) {
    requireIdle()
    let ax = application(runningApp())
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size) else { fail("could not build AXSize") }
    let window = mainWindow(ax)
    let before = frame(window) ?? [:]
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    appendLog("resize to=\(Int(width))x\(Int(height)) before=\(before) result=\(result.rawValue)")
    guard result == .success else { fail("AXSize failed (\(result.rawValue))") }
    Thread.sleep(forTimeInterval: 1.0)
    snapshot("size-\(Int(width))x\(Int(height))")
}

// MARK: Contrast (REQ-19/20), same method as AccessibilityAuditChecks.measure

func contrast(_ png: URL) {
    guard let image = NSImage(contentsOf: png), let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff), let cgImage = bitmap.cgImage else { fail("cannot read \(png.path)") }
    func luminance(_ x: Int, _ y: Int) -> Double? {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { fail("OCR: \(error)") }
    let scale = Double(bitmap.pixelsWide) / Double(image.size.width)
    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
        guard let text = observation.topCandidates(1).first?.string, text.count >= 3, observation.confidence >= 0.5 else { continue }
        let box = observation.boundingBox
        let x0 = max(0, Int(box.minX * Double(bitmap.pixelsWide)))
        let x1 = min(bitmap.pixelsWide, Int(ceil(box.maxX * Double(bitmap.pixelsWide))))
        let y0 = max(0, Int((1 - box.maxY) * Double(bitmap.pixelsHigh)))
        let y1 = min(bitmap.pixelsHigh, Int(ceil((1 - box.minY) * Double(bitmap.pixelsHigh))))
        guard x1 > x0, y1 > y0 else { continue }
        var values: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 { if let v = luminance(x, y) { values.append(v) } } }
        guard values.count > 16 else { continue }
        var histogram = [Int](repeating: 0, count: 64)
        for v in values { histogram[min(63, Int(v * 64))] += 1 }
        let mode = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        let backing = values.filter { min(63, Int($0 * 64)) == mode }.reduce(0, +) / Double(max(1, histogram[mode]))
        let distance = values.map { abs($0 - backing) }.sorted()[Int(Double(values.count - 1) * 0.98)]
        let foreground = values.first { abs(abs($0 - backing) - distance) < 0.000_001 } ?? backing
        let ratio = (max(backing, foreground) + 0.05) / (min(backing, foreground) + 0.05)
        let points = Double(y1 - y0) / scale
        let required = points >= 24 ? 3.0 : 4.5
        lines.append(["text": text, "ratio": (ratio * 100).rounded() / 100, "required": required,
                      "pass": ratio >= required, "heightPoints": (points * 10).rounded() / 10])
    }
    let failing = lines.filter { ($0["pass"] as? Bool) == false }
    write(["png": png.lastPathComponent, "lines": lines, "below": failing.count],
          png.deletingPathExtension().lastPathComponent + "-contrast.json")
    print("\(png.lastPathComponent): \(lines.count) text lines, \(failing.count) below WCAG")
}

// MARK: Signposts (REQ-21/75/119)

func signposts(minutes: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--last", "\(minutes)m", "--style", "ndjson", "--signpost", "--info",
                         "--predicate", "subsystem == \"io.github.dragoshont.xodus\""]
    let file = outDirectory.appendingPathComponent("signposts-\(minutes)m.ndjson")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: file) else { fail("cannot write \(file.path)") }
    process.standardOutput = handle
    do { try process.run() } catch { fail("log show: \(error)") }
    process.waitUntilExit()
    try? handle.close()
    let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
    var categories: [String: Int] = [:]
    for line in lines {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        categories[entry["category"] as? String ?? "?", default: 0] += 1
    }
    write(["minutes": minutes, "entries": lines.count, "byCategory": categories], "signposts-\(minutes)m-summary.json")
    print("signposts: \(lines.count) entries \(categories)")
}

// MARK: Dispatch

switch command {
case "preflight":
    let running: [[String: Any]] = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .map { ["pid": Int($0.processIdentifier), "executable": $0.executableURL?.path ?? "", "active": $0.isActive] }
    let now = idle()
    let report: [String: Any] = [
        "at": stamp, "identity": identity(), "running": running, "screenLocked": screenLocked(),
        "accessibilityTrusted": AXIsProcessTrusted(), "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
        "ownerIdleSeconds": ["keyboard": now.keyboard, "pointer": now.pointer], "idleRequired": idleSeconds,
        "preferences": preferences()
    ]
    var clean = false
    var windowSummary: [[String: Any]] = []
    if running.count == 1, AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        let ax = application(app)
        let all = windows(ax)
        windowSummary = all.map { window in
            let sheets = (attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .filter { string($0, kAXRoleAttribute) == kAXSheetRole }.count
            return ["title": string(window, kAXTitleAttribute) ?? "", "sheets": sheets]
        }
        // A clean start is one main window with no sheet; leftovers from an earlier pass dim and cover captures.
        clean = all.count == 1 && (windowSummary.first?["sheets"] as? Int) == 0
    }
    var updated = report
    updated["windows"] = windowSummary
    updated["cleanStart"] = clean
    write(updated, "preflight.json")
    let ready = !screenLocked() && AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() && running.count == 1 && clean
    print(ready ? "READY" : "NOT READY: see preflight.json (locked, AX trust, screen recording, one running app, one window without sheets)")
    exit(ready ? 0 : 3)
case "close-window":
    // Closes an auxiliary window (never the main X Ode window) with its standard close button.
    guard let title = arguments.first, ["Engines", "General", "Account", "Advanced", "Settings", "Acknowledgments", "Licenses"].contains(title)
    else { refuse("close-window accepts only Settings-pane and Acknowledgments/Licenses windows") }
    requireIdle()
    let ax = application(runningApp())
    let matches = windows(ax).filter { string($0, kAXTitleAttribute) == title }
    guard matches.count == 1, let button = axElement(attribute(matches[0], kAXCloseButtonAttribute)) else {
        fail("expected one '\(title)' window with a close button, found \(matches.count)")
    }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    appendLog("close-window title=\(title) result=\(result.rawValue)")
    guard result == .success else { fail("close failed (\(result.rawValue))") }
case "quit":
    // Normal Quit (the same request as Command-Q); never forced. X Ode may still ask to confirm.
    requireIdle()
    let app = runningApp()
    let requested = app.terminate()
    appendLog("quit requested=\(requested)")
    for _ in 0..<30 where !app.isTerminated { Thread.sleep(forTimeInterval: 1) }
    print(app.isTerminated ? "X Ode quit" : "X Ode is still running (it may be asking to confirm); not forced")
case "activate":
    requireIdle()
    let app = runningApp()
    let window = mainWindow(application(app))
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let activated = app.activate()
    appendLog("activate result=\(activated)")
    Thread.sleep(forTimeInterval: 1.0)
    guard activated else { fail("could not activate X Ode") }
case "snapshot":
    guard let label = arguments.first else { fail("snapshot needs LABEL") }
    snapshot(label)
case "press":
    guard let target = arguments.first else { fail("press needs a target") }
    press(target)
case "set-search":
    guard let text = arguments.first else { fail("set-search needs TEXT") }
    setSearch(text)
case "scroll":
    guard arguments.count == 2, ["up", "down"].contains(arguments[0]), let pages = Int(arguments[1]), (1...20).contains(pages)
    else { fail("scroll needs up|down PAGES (1...20)") }
    scroll(arguments[0], pages: pages)
case "resize":
    guard arguments.count == 2, let w = Double(arguments[0]), let h = Double(arguments[1]) else { fail("resize needs W H") }
    resize(w, h)
case "contrast":
    guard let path = arguments.first else { fail("contrast needs PNG") }
    contrast(URL(fileURLWithPath: path))
case "signposts":
    signposts(minutes: arguments.first.flatMap(Int.init) ?? 15)
default:
    fail("unknown command \(command)")
}

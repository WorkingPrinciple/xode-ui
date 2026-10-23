import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "--restore" {
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hidden = record["hiddenApplications"] as? [[String: Any]] else {
        fail("Desktop restoration metadata is invalid")
    }
    var failed = false
    for entry in hidden {
        guard let pid = entry["pid"] as? Int32,
              let identifier = entry["bundleIdentifier"] as? String,
              let start = entry["launchDate"] as? Double,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == identifier,
              app.launchDate?.timeIntervalSince1970 == start else { continue }
        if !app.unhide() { failed = true }
    }
    if failed { fail("Some previously visible applications could not be restored") }
    print("Previously visible applications restored where the original process still exists.")
    exit(0)
}
let clearDesktop = arguments.last == "--clear-desktop"
if clearDesktop { arguments.removeLast() }
guard arguments.count == 2 || arguments.count == 3,
      !arguments[1].isEmpty,
      !arguments[1].contains("/"),
      arguments[1] != ".", arguments[1] != ".." else {
    fail("Usage: swift capture_test_desktop.swift OUTPUT_DIRECTORY LABEL [OWNED_GAME_PID] [--clear-desktop]")
}
let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
let label = arguments[1]
let metadataURL = directory.appendingPathComponent("\(label)-desktop.json")
guard directory.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: metadataURL.path) else {
    fail("An absolute output directory and an unused label are required")
}
let owner: pid_t?
if arguments.count == 3 {
    guard let value = Int32(arguments[2]), value > 0 else { fail("Invalid owned game PID") }
    owner = value
} else {
    owner = nil
}

var count: UInt32 = 0
guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
    fail("Active display inventory is unavailable")
}
var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
    fail("Active display inventory failed")
}
displays = Array(displays.prefix(Int(count)))
let main = CGMainDisplayID()
displays.sort { first, second in first == main && second != main }
let paths = displays.indices.map {
    directory.appendingPathComponent("\(label)-display-\($0 + 1).png")
}
guard paths.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
    fail("Refusing to overwrite existing desktop captures")
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var hiddenApplications: [[String: Any]] = []
if clearDesktop {
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && !app.isHidden
        && app.processIdentifier != owner && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        guard let identifier = app.bundleIdentifier, let date = app.launchDate else { continue }
        if app.hide() {
            hiddenApplications.append([
                "pid": app.processIdentifier, "bundleIdentifier": identifier,
                "launchDate": date.timeIntervalSince1970,
            ])
        }
    }
    Thread.sleep(forTimeInterval: 1)
}
let recovery: [String: Any] = [
    "captureState": "started", "hiddenApplications": hiddenApplications,
]
try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted, .sortedKeys])
    .write(to: metadataURL, options: [.atomic])
var activationRequested = false
if let owner, let application = NSRunningApplication(processIdentifier: owner) {
    activationRequested = application.activate(options: [])
    Thread.sleep(forTimeInterval: 1)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let allWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let runtimeDialogCandidates = allWindows.filter { window in
    let title = window[kCGWindowName as String] as? String ?? ""
    let application = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    return ["Wine Mono Installer", "Wine Gecko Installer", "Wine Debugger"].contains(title)
        || (!title.isEmpty && ["control.exe", "conhost.exe", "winedbg.exe", "wineboot.exe"].contains(application))
}
func bounds(_ window: [String: Any]) -> CGRect? {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary)
}
let targetIndex = owner.flatMap { pid in
    windows.firstIndex { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let title = window[kCGWindowName as String] as? String, !title.isEmpty,
              let frame = bounds(window) else { return false }
        return frame.width > 200 && frame.height > 100
    }
}
var occluders: [[String: Any]] = []
if let targetIndex, let frame = bounds(windows[targetIndex]) {
    occluders = windows.prefix(targetIndex).filter { window in
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != owner,
              let other = bounds(window) else { return false }
        let overlap = frame.intersection(other)
        return !overlap.isNull && overlap.width * overlap.height > frame.width * frame.height * 0.1
    }
}
var captures: [[String: Any]] = []
for (index, display) in displays.enumerated() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-D", String(index + 1), paths[index].path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let attributes = try? FileManager.default.attributesOfItem(atPath: paths[index].path),
          let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0 else {
        fail("Full-display capture failed for display index \(index + 1)")
    }
    captures.append([
        "displayIndex": index + 1, "displayID": display,
        "bounds": CGRectCreateDictionaryRepresentation(CGDisplayBounds(display)),
        "pixelWidth": CGDisplayPixelsWide(display), "pixelHeight": CGDisplayPixelsHigh(display),
        "path": paths[index].path, "bytes": bytes,
    ])
}
let eligible = owner != nil && targetIndex != nil && occluders.isEmpty
let record: [String: Any] = [
    "capturedAt": ISO8601DateFormatter().string(from: Date()),
    "ownedGamePID": owner.map { NSNumber(value: $0) } ?? NSNull(),
    "activationRequested": activationRequested,
    "hiddenApplications": hiddenApplications,
    "displays": captures,
    "ownedWindows": windows.filter {
        ( $0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner && owner != nil
    },
    "occludingWindows": occluders,
    "runtimeDialogCandidates": runtimeDialogCandidates,
    "visualInspectionEligible": eligible,
    "meaning": "Full displays, not game crops. Eligible means inspectable, never menu/gameplay success.",
]
let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try data.write(to: metadataURL, options: [.atomic])
print(metadataURL.path)
if owner != nil && !eligible {
    FileHandle.standardError.write(Data("Game window absent or occluded; captures retained without a visual verdict.\n".utf8))
    exit(3)
}

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureIdentityDiagnostic: Encodable {
    struct Window: Encodable {
        let window: CGWindowID
        let pid: pid_t?
        let title: String?
        let onScreen: Bool?
        let layer: Int?

        enum CodingKeys: String, CodingKey {
            case window, pid, title, onScreen, layer
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(window, forKey: .window)
            try values.encode(pid, forKey: .pid)
            try values.encode(title, forKey: .title)
            try values.encode(onScreen, forKey: .onScreen)
            try values.encode(layer, forKey: .layer)
        }
    }

    let expectedPID: pid_t
    let expectedWindow: CGWindowID
    let expectedTitle: String
    let matchCount: Int
    let frontmostPID: pid_t?
    let sckCandidates: [Window]
    let cgCandidates: [Window]?
    let error = "identityMismatch"

    init(expectedPID: pid_t, expectedWindow: CGWindowID, expectedTitle: String,
         matchCount: Int, frontmostPID: pid_t?, sckWindows: [Window], cgWindows: [Window]?) {
        self.expectedPID = expectedPID
        self.expectedWindow = expectedWindow
        self.expectedTitle = expectedTitle
        self.matchCount = matchCount
        self.frontmostPID = frontmostPID
        self.sckCandidates = sckWindows.filter {
            $0.window == expectedWindow || $0.pid == expectedPID
        }
        self.cgCandidates = cgWindows?.filter {
            $0.window == expectedWindow || $0.pid == expectedPID
        }
    }

    enum CodingKeys: String, CodingKey {
        case error, expectedPID, expectedWindow, expectedTitle, matchCount
        case frontmostPID, sckCandidates, cgCandidates
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(error, forKey: .error)
        try values.encode(expectedPID, forKey: .expectedPID)
        try values.encode(expectedWindow, forKey: .expectedWindow)
        try values.encode(expectedTitle, forKey: .expectedTitle)
        try values.encode(matchCount, forKey: .matchCount)
        try values.encode(frontmostPID, forKey: .frontmostPID)
        try values.encode(sckCandidates, forKey: .sckCandidates)
        try values.encode(cgCandidates, forKey: .cgCandidates)
    }
}

#if !CAPTURE_DIAGNOSTIC_TEST
@main
struct CaptureWindow {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let pid = pid_t(args[1]), pid > 0,
                  let windowID = CGWindowID(args[2]), !args[3].isEmpty else {
                throw CaptureError.invalidArguments
            }
            _ = NSApplication.shared
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureError.permissionRequired
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let matches = content.windows.filter {
                $0.windowID == windowID && $0.owningApplication?.processID == pid
                    && $0.title == args[3] && $0.isOnScreen
            }
            guard matches.count == 1, let window = matches.first else {
                let sckWindows = content.windows.filter {
                    $0.windowID == windowID || $0.owningApplication?.processID == pid
                }.map {
                    CaptureIdentityDiagnostic.Window(
                        window: $0.windowID, pid: $0.owningApplication?.processID,
                        title: $0.title, onScreen: $0.isOnScreen, layer: $0.windowLayer
                    )
                }
                let cgWindows = (CGWindowListCopyWindowInfo(
                    .optionAll, kCGNullWindowID
                ) as? [[String: Any]])?.filter {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                        || ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                }.compactMap { info -> CaptureIdentityDiagnostic.Window? in
                    guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                        return nil
                    }
                    return CaptureIdentityDiagnostic.Window(
                        window: number.uint32Value,
                        pid: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                        title: info[kCGWindowName as String] as? String,
                        onScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
                        layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                    )
                }
                let diagnostic = CaptureIdentityDiagnostic(
                    expectedPID: pid, expectedWindow: windowID, expectedTitle: args[3],
                    matchCount: matches.count,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    sckWindows: sckWindows, cgWindows: cgWindows
                )
                do {
                    var data = try JSONEncoder().encode(diagnostic)
                    data.append(0x0a)
                    FileHandle.standardError.write(data)
                } catch {
                    FileHandle.standardError.write(
                        Data("capture identity diagnostic encoding failed: \(error)\n".utf8)
                    )
                }
                throw CaptureError.identityMismatch
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width)
            configuration.height = Int(window.frame.height)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            let url = URL(fileURLWithPath: args[4])
            guard !FileManager.default.fileExists(atPath: url.path),
                  let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil
                  ) else {
                throw CaptureError.outputRefused
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CaptureError.encodingFailed
            }
            print("{\"pid\":\(pid),\"window\":\(windowID),\"width\":\(image.width),\"height\":\(image.height),\"completed\":true}")
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(1)
        }
    }
    enum CaptureError: Error {
        case invalidArguments, permissionRequired, identityMismatch, outputRefused, encodingFailed
    }
}
#endif
